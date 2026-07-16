/**
 * @description Suspending and fan-out half of the Revenant step outcome. Handles
 * the directives that pause a step awaiting an external event -- yield, suspend,
 * sleep, start-child, start-children and wait-for-approval -- plus the SPLIT
 * directive that completes a spawning step and fans out its parallel branches.
 * Extracted from `WorkflowEngine`; each handler is invoked by the outcome
 * dispatch. All SOQL and DML run in system mode.
 */
public inherited sharing class WorkflowStepSuspension {
  /**
   * @description YIELD outcome: saves the step's checkpoint state to its output
   * and re-runs the same step in a new transaction (e.g. an Apex Cursor chunk).
   * @param outcome the step outcome bundle carrying instance, step exec, result
   * and context
   */
  public static void handleYieldOutcome(
    WorkflowEngine.StepOutcomeContext outcome
  ) {
    Workflow_Instance__c instance = outcome.instance;
    Workflow_Step_Execution__c stepExec = outcome.stepExec;
    StepResult result = outcome.result;
    StepContext context = outcome.context;
    Boolean isParallel = outcome.isParallel;
    // Step yielded (e.g. Apex Cursor chunk). Save state to Output and run again in a new transaction.
    if (isParallel) {
      WorkflowEngine.rollbackClaimedSignals(context);
    }
    stepExec.Status__c = 'Running';
    stepExec.Output__c = WorkflowPayloadOffload.savePayloadIfNeeded(
      instance.Id,
      result.directive().stepStateJson,
      'State_' + stepExec.Step_Name__c.replaceAll('[^a-zA-Z0-9]', '_')
    );
    WorkflowEngine.saveStepExec(stepExec);

    Database.update(instance, true, AccessLevel.SYSTEM_MODE);

    WorkflowTimeoutArming.scheduleTimeoutJobForInstance(instance.Id);
    WorkflowOrchestratorEnqueue.enqueueOrchestrator(instance.Id, null);
  }

  /**
   * @description SUSPEND outcome: saves the step's state and suspends the
   * instance awaiting an external signal, arming or clearing the timed-suspend
   * deadline before redelivering any matching buffered signals.
   * @param outcome the step outcome bundle carrying instance, step exec, result
   * and context
   */
  public static void handleSuspendOutcome(
    WorkflowEngine.StepOutcomeContext outcome
  ) {
    Workflow_Instance__c instance = outcome.instance;
    Workflow_Step_Execution__c stepExec = outcome.stepExec;
    StepResult result = outcome.result;
    StepContext context = outcome.context;
    Boolean isParallel = outcome.isParallel;
    // Step suspended (waiting for external signal). Save state and mark instance.
    if (isParallel) {
      WorkflowEngine.rollbackClaimedSignals(context);
    }
    stepExec.Status__c = 'Pending';
    String suspendStateJson;
    if (String.isNotBlank(result.directive().timeout.step)) {
      // Timed suspend (issue #35): persist the fallback step in a reserved key
      // so the watchdog can route to it when the deadline elapses.
      suspendStateJson = JSON.serialize(
        new Map<String, Object>{
          '$timeoutStep' => result.directive().timeout.step
        }
      );
      instance.Sleep_Until__c = DateTime.now()
        .addSeconds(result.directive().timeout.seconds);
    } else {
      // Explicit stepStateJson is preserved; no-arg suspend() nulls Output__c so
      // stale yield checkpoints from a prior YIELD in the same execution don't
      // survive into a retry and cause duplicate-spawn collisions.
      suspendStateJson = result.directive().stepStateJson;
      // A plain (deadline-less) suspend must not inherit a stale timer left by
      // an earlier timed wait or a manual resume, or the watchdog would wake it
      // early. Reset the deadline defensively (issue #35).
      instance.Sleep_Until__c = null;
    }
    stepExec.Output__c = String.isNotBlank(suspendStateJson)
      ? WorkflowPayloadOffload.savePayloadIfNeeded(
          instance.Id,
          suspendStateJson,
          'State_Suspend_' +
          stepExec.Step_Name__c.replaceAll('[^a-zA-Z0-9]', '_')
        )
      : null;
    WorkflowEngine.saveStepExec(stepExec);

    instance.Status__c = 'Suspended';
    Database.update(instance, true, AccessLevel.SYSTEM_MODE);
    WorkflowEngine.redeliverMatchingSignalsForInstance(
      instance.Id,
      instance.Correlation_Key__c
    );
  }

  /**
   * @description SLEEP outcome: saves the step's state and suspends the instance
   * until the requested sleep deadline, scheduling the resume job.
   * @param outcome the step outcome bundle carrying instance, step exec, result
   * and context
   */
  public static void handleSleepOutcome(
    WorkflowEngine.StepOutcomeContext outcome
  ) {
    Workflow_Instance__c instance = outcome.instance;
    Workflow_Step_Execution__c stepExec = outcome.stepExec;
    StepResult result = outcome.result;
    StepContext context = outcome.context;
    Boolean isParallel = outcome.isParallel;
    // Step requested sleep
    if (isParallel) {
      WorkflowEngine.rollbackClaimedSignals(context);
    }
    stepExec.Status__c = 'Pending';
    stepExec.Output__c = WorkflowPayloadOffload.savePayloadIfNeeded(
      instance.Id,
      result.directive().stepStateJson,
      'State_' + stepExec.Step_Name__c.replaceAll('[^a-zA-Z0-9]', '_')
    );
    WorkflowEngine.saveStepExec(stepExec);

    instance.Status__c = 'Suspended';
    instance.Sleep_Until__c = DateTime.now()
      .addSeconds(result.directive().sleepDurationSeconds);
    instance.Async_Job_Id__c = WorkflowRetrySleepScheduler.scheduleSleepResume(
      instance.Id,
      stepExec.Step_Name__c,
      result.directive().sleepDurationSeconds
    );
    Database.update(instance, true, AccessLevel.SYSTEM_MODE);
  }

  /**
   * @description START_CHILD outcome: suspends the step (without consuming its
   * observed signals) and starts a single child workflow, redelivering matching
   * buffered signals before dispatching the child start request.
   * @param outcome the step outcome bundle carrying instance, step exec, result
   * and context
   */
  public static void handleStartChildOutcome(
    WorkflowEngine.StepOutcomeContext outcome
  ) {
    Workflow_Instance__c instance = outcome.instance;
    Workflow_Step_Execution__c stepExec = outcome.stepExec;
    StepResult result = outcome.result;
    StepContext context = outcome.context;
    Boolean isParallel = outcome.isParallel;
    // Step requested child workflow.
    //
    // Observed signals are intentionally NOT consumed here. START_CHILD
    // suspends and re-runs the SAME step when the child completes (like
    // SUSPEND/WAIT_FOR_APPROVAL), rather than transitioning forward like
    // COMPLETE/SPLIT. Consuming on this path would break a step that re-reads
    // its kickoff signal on resume to confirm it is still in the active flow.
    // A START_CHILD step should therefore check the child-completion signal
    // before re-acting on a kickoff signal (or stash needed data in step state).
    if (isParallel) {
      WorkflowEngine.rollbackClaimedSignals(context);
    }
    stepExec.Status__c = 'Pending';
    Map<String, Object> childInfo = new Map<String, Object>{
      'childWorkflowName' => result.directive().childWorkflowName,
      'childCorrelationKey' => result.directive().childCorrelationKey
    };
    stepExec.Output__c = WorkflowPayloadOffload.savePayloadIfNeeded(
      instance.Id,
      JSON.serialize(childInfo),
      'State_ChildInfo_' + stepExec.Step_Name__c.replaceAll('[^a-zA-Z0-9]', '_')
    );
    WorkflowEngine.saveStepExec(stepExec);

    instance.Status__c = 'Suspended';
    Database.update(instance, true, AccessLevel.SYSTEM_MODE);
    WorkflowEngine.redeliverMatchingSignalsForInstance(
      instance.Id,
      instance.Correlation_Key__c
    );

    WorkflowChildService.ChildWorkflowStartRequest childReq = new WorkflowChildService.ChildWorkflowStartRequest();
    childReq.parentId = instance.Id;
    childReq.workflowName = result.directive().childWorkflowName;
    childReq.correlationKey = result.directive().childCorrelationKey;
    childReq.inputJson = result.directive().childInputJson;
    WorkflowChildService.startChildWorkflow(childReq);
  }

  /**
   * @description START_CHILDREN outcome: suspends the step and starts multiple
   * child workflows in bulk, stashing the child correlation keys in step state
   * and redelivering matching buffered signals before the bulk start.
   * @param outcome the step outcome bundle carrying instance, step exec, result
   * and context
   */
  public static void handleStartChildrenOutcome(
    WorkflowEngine.StepOutcomeContext outcome
  ) {
    Workflow_Instance__c instance = outcome.instance;
    Workflow_Step_Execution__c stepExec = outcome.stepExec;
    StepResult result = outcome.result;
    StepContext context = outcome.context;
    Boolean isParallel = outcome.isParallel;
    if (
      result.directive().childRequests == null ||
      result.directive().childRequests.isEmpty()
    ) {
      throw new WorkflowEngine.WorkflowException(
        'START_CHILDREN action requires at least one child request.'
      );
    }
    if (isParallel) {
      WorkflowEngine.rollbackClaimedSignals(context);
    }
    stepExec.Status__c = 'Pending';
    List<String> childKeys = new List<String>();
    for (StepResult.ChildRequest req : result.directive().childRequests) {
      childKeys.add(req.correlationKey);
    }
    Map<String, Object> state = new Map<String, Object>{
      'childCorrelationKeys' => childKeys
    };
    stepExec.Output__c = WorkflowPayloadOffload.savePayloadIfNeeded(
      instance.Id,
      JSON.serialize(state),
      'State_ChildKeys_' + stepExec.Step_Name__c.replaceAll('[^a-zA-Z0-9]', '_')
    );
    WorkflowEngine.saveStepExec(stepExec);

    instance.Status__c = 'Suspended';
    Database.update(instance, true, AccessLevel.SYSTEM_MODE);
    WorkflowEngine.redeliverMatchingSignalsForInstance(
      instance.Id,
      instance.Correlation_Key__c
    );

    WorkflowChildBulkService.startChildWorkflows(
      instance.Id,
      result.directive().childRequests
    );
  }

  /**
   * @description WAIT_FOR_APPROVAL outcome: suspends the step awaiting an
   * approval signal, arming or clearing the timed-approval deadline before
   * redelivering any matching buffered signals.
   * @param outcome the step outcome bundle carrying instance, step exec, result
   * and context
   */
  public static void handleWaitForApprovalOutcome(
    WorkflowEngine.StepOutcomeContext outcome
  ) {
    Workflow_Instance__c instance = outcome.instance;
    Workflow_Step_Execution__c stepExec = outcome.stepExec;
    StepResult result = outcome.result;
    StepContext context = outcome.context;
    Boolean isParallel = outcome.isParallel;
    if (isParallel) {
      WorkflowEngine.rollbackClaimedSignals(context);
    }
    stepExec.Status__c = 'Pending';
    Map<String, Object> state = new Map<String, Object>{
      'waitingForApproval' => true,
      'approvalKey' => result.directive().approvalKey,
      'approvalRole' => result.directive().approvalRole
    };
    if (String.isNotBlank(result.directive().timeout.step)) {
      // Timed approval (issue #35): add fallback step so watchdog can route.
      state.put('$timeoutStep', result.directive().timeout.step);
      instance.Sleep_Until__c = DateTime.now()
        .addSeconds(result.directive().timeout.seconds);
    } else {
      // A deadline-less approval wait must not inherit a stale timer left by an
      // earlier timed wait or a manual resume (issue #35).
      instance.Sleep_Until__c = null;
    }
    stepExec.Output__c = WorkflowPayloadOffload.savePayloadIfNeeded(
      instance.Id,
      JSON.serialize(state),
      'State_Approval_' + stepExec.Step_Name__c.replaceAll('[^a-zA-Z0-9]', '_')
    );
    WorkflowEngine.saveStepExec(stepExec);

    instance.Status__c = 'Suspended';
    Database.update(instance, true, AccessLevel.SYSTEM_MODE);
    WorkflowEngine.redeliverMatchingSignalsForInstance(
      instance.Id,
      instance.Correlation_Key__c
    );
  }

  /**
   * @description SPLIT outcome: durably completes the spawning step, consumes
   * the signals it observed, fans out the parallel branch executions and enqueues
   * each branch, then publishes the step's buffered outbound events after the
   * required durable DML.
   * @param outcome the step outcome bundle carrying instance, step exec, result
   * and context
   */
  public static void handleSplitOutcome(
    WorkflowEngine.StepOutcomeContext outcome
  ) {
    Workflow_Instance__c instance = outcome.instance;
    Workflow_Step_Execution__c stepExec = outcome.stepExec;
    StepResult result = outcome.result;
    StepContext context = outcome.context;
    stepExec.Status__c = 'Completed';
    stepExec.Output__c = WorkflowPayloadOffload.savePayloadIfNeeded(
      instance.Id,
      result.directive().parallelInputJson != null
        ? result.directive().parallelInputJson
        : result.directive().outputJson,
      'Output_Split_' + stepExec.Step_Name__c.replaceAll('[^a-zA-Z0-9]', '_')
    );
    WorkflowEngine.saveStepExec(stepExec);

    // The spawning step durably completed; consume the signals it observed so
    // they are not re-loaded into the parallel branches it fans out to. The
    // spawning step runs serially (it is the fan-out point, not a branch) and
    // does not claim, so it consumes still-Received rows plus same-name
    // duplicate cleanup.
    WorkflowEngine.markSignalsConsumedSerial(instance.Id, context);

    String parallelStepsStr = String.join(
      result.directive().parallelStepNames,
      ','
    );
    instance.Current_Step__c = parallelStepsStr;
    instance.Status__c = 'Running';
    Database.update(instance, true, AccessLevel.SYSTEM_MODE);

    List<Workflow_Step_Execution__c> parallelExecs = new List<Workflow_Step_Execution__c>();
    for (String ps : result.directive().parallelStepNames) {
      Workflow_Step_Execution__c pe = new Workflow_Step_Execution__c();
      pe.Workflow_Instance__c = instance.Id;
      pe.Step_Name__c = ps;
      pe.Status__c = 'Pending';
      pe.Input__c = WorkflowPayloadOffload.savePayloadIfNeeded(
        instance.Id,
        result.directive().parallelInputJson != null
          ? result.directive().parallelInputJson
          : stepExec.Output__c,
        'Input_Parallel_' + ps.replaceAll('[^a-zA-Z0-9]', '_')
      );
      pe.Retry_Count__c = 0;
      Integer timeout = WorkflowStepTimeoutConfig.getStepTimeoutSeconds(
        ps,
        WorkflowTypeResolver.extractNamespace(instance.Workflow_Name__c)
      );
      if (timeout != null && timeout > 0) {
        pe.Timeout_At__c = DateTime.now().addSeconds(timeout);
      }
      parallelExecs.add(pe);
    }
    Database.insert(parallelExecs, true, AccessLevel.SYSTEM_MODE);

    WorkflowTimeoutArming.scheduleTimeoutJobForInstance(instance.Id);
    for (String ps : result.directive().parallelStepNames) {
      WorkflowOrchestratorEnqueue.enqueueOrchestrator(instance.Id, ps);
    }

    // Effectively-once outbound emit (issue #64): publish AFTER the SPLIT's
    // required durable DML — the instance update, the branch-execution inserts,
    // and the per-branch enqueueOrchestrator hand-offs (which scale with the
    // fan-out). Publishing here means the best-effort emit can never consume the
    // DML budget those writes need and roll back the SPLIT commit. The events
    // still ride this same transaction, so a rollback anywhere above publishes
    // nothing, and they remain part of the SPLIT commit that gates the branches.
    WorkflowStepOutcome.publishOutboundEvents(result, context);
  }
}
