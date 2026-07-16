/**
 * @description Retry, continue-as-new and explicit-fail half of the Revenant
 * step outcome. Applies retry backoff (or fails the instance when retries are
 * exhausted), spawns a continue-as-new successor (predecessor terminated before
 * the successor is inserted, search attributes copied, first step pre-created and
 * enqueued), and routes an explicit terminal failure through the shared fail
 * path. Extracted from `WorkflowEngine`; each handler is invoked by the outcome
 * dispatch. All SOQL and DML run in system mode.
 */
public inherited sharing class WorkflowContinueAsNew {
  /**
   * @description RETRY outcome: increments the attempt count and either
   * reschedules the step with exponential backoff or, when the sanitized policy's
   * maximum attempts are exhausted, fails the workflow instance.
   * @param outcome the step outcome bundle carrying instance, step exec, result
   * and context
   */
  public static void handleRetryOutcome(
    WorkflowEngine.StepOutcomeContext outcome
  ) {
    Workflow_Instance__c instance = outcome.instance;
    Workflow_Step_Execution__c stepExec = outcome.stepExec;
    StepResult result = outcome.result;
    StepContext context = outcome.context;
    Boolean isParallel = outcome.isParallel;
    // Step requested retry
    if (isParallel) {
      WorkflowSignalConsume.rollbackClaimedSignals(context);
    }
    stepExec.Retry_Count__c += 1;

    // Get and sanitize retry policy
    RetryPolicy policy = WorkflowEngine.sanitizePolicy(
      result.directive().retry.policy
    );

    WorkflowEngine.persistRetryMaxAttempts(instance, stepExec, policy);

    if (stepExec.Retry_Count__c >= policy.maximumAttempts) {
      stepExec.Status__c = 'Failed';
      stepExec.Error_Details__c =
        'Max retries (' +
        policy.maximumAttempts +
        ') exceeded.';
      WorkflowEngine.saveStepExec(stepExec);

      WorkflowEngine.FailInstanceRequest maxRetriesReq = new WorkflowEngine.FailInstanceRequest();
      maxRetriesReq.instanceId = instance.Id;
      maxRetriesReq.stepName = instance.Current_Step__c;
      maxRetriesReq.errorMessage = 'Max retries exceeded.';
      maxRetriesReq.failureCategory = WorkflowEngine.CAT_RETRIES_EXHAUSTED;
      WorkflowEngine.failWorkflowInstance(maxRetriesReq);
    } else {
      WorkflowEngine.scheduleExponentialRetry(instance, stepExec, policy);
    }
  }

  /**
   * @description CONTINUE_AS_NEW outcome: records the step's continuation input,
   * marks the current instance ContinuedAsNew, and spawns the successor instance
   * carrying the chain's root correlation key forward.
   * @param outcome the step outcome bundle carrying instance, step exec, result
   * and context
   */
  public static void handleContinueAsNewOutcome(
    WorkflowEngine.StepOutcomeContext outcome
  ) {
    Workflow_Instance__c instance = outcome.instance;
    Workflow_Step_Execution__c stepExec = outcome.stepExec;
    StepResult result = outcome.result;
    StepContext context = outcome.context;
    Boolean isParallel = outcome.isParallel;
    if (isParallel) {
      WorkflowSignalConsume.rollbackClaimedSignals(context);
    }
    stepExec.Status__c = 'ContinuedAsNew';
    stepExec.Output__c = WorkflowPayloadOffload.savePayloadIfNeeded(
      instance.Id,
      result.directive().continuation.nextInputJson,
      'ContinueInput_' + stepExec.Step_Name__c.replaceAll('[^a-zA-Z0-9]', '_')
    );
    WorkflowEngine.saveStepExec(stepExec);

    // Resolve the new correlation key
    String newKey = resolveContinueAsNewKey(
      instance.Correlation_Key__c,
      result.directive().continuation.newCorrelationKey
    );

    // Mark current instance as ContinuedAsNew
    instance.Status__c = 'ContinuedAsNew';
    instance.Current_Step__c = null;
    Database.update(instance, true, AccessLevel.SYSTEM_MODE);

    spawnContinueAsNewSuccessor(instance, result, newKey);
  }

  /**
   * Resolves the successor's execution deadline from an execution-timeout-
   * configurable workflow definition.
   * @param defObj the instantiated workflow definition object
   * @return the deadline DateTime, or null when no positive execution timeout is
   *   configured
   */
  private static Datetime resolveExecutionDeadline(Object defObj) {
    if (!(defObj instanceof ExecutionTimeoutConfigurable)) {
      return null;
    }
    Integer timeoutSecs = ((ExecutionTimeoutConfigurable) defObj)
      .getExecutionTimeoutSeconds();
    return timeoutSecs != null ? DateTime.now().addSeconds(timeoutSecs) : null;
  }

  // Create and enqueue the successor instance for a CONTINUE_AS_NEW transition.
  private static void spawnContinueAsNewSuccessor(
    Workflow_Instance__c instance,
    StepResult result,
    String newKey
  ) {
    // Resolve initial step for successor instance
    String initialStep = null;
    Datetime nextDeadline = null;
    Type wflowType = WorkflowTypeResolver.resolve(
      instance.Workflow_Name__c,
      WorkflowTypeResolver.extractNamespace(instance.Workflow_Name__c)
    );
    if (wflowType != null) {
      Object defObj = wflowType.newInstance();
      if (defObj instanceof WorkflowDefinition) {
        initialStep = ((WorkflowDefinition) defObj).getInitialStep();
      }
      nextDeadline = resolveExecutionDeadline(defObj);
    }

    // Spawn successor instance. Carry the chain's root correlation key forward
    // unchanged so the whole continue-as-new chain shares one stable key that
    // external callers can correlate the terminal lifecycle event against.
    // Fall back to the predecessor's own key if the root was never populated
    // (pre-existing data created before the Root_Correlation_Key__c field).
    String rootKey = String.isNotBlank(instance.Root_Correlation_Key__c)
      ? instance.Root_Correlation_Key__c
      : instance.Correlation_Key__c;
    Workflow_Instance__c nextInstance = new Workflow_Instance__c(
      Workflow_Name__c = instance.Workflow_Name__c,
      Correlation_Key__c = newKey,
      Root_Correlation_Key__c = rootKey,
      Previous_Instance__c = instance.Id,
      Definition_Version__c = instance.Definition_Version__c,
      Current_Step__c = initialStep,
      Deadline_At__c = nextDeadline,
      Progress__c = instance.Progress__c,
      Causation_Id__c = String.isNotBlank(instance.Causation_Id__c)
        ? instance.Causation_Id__c
        : instance.Parent_Instance__c,
      // Use the predecessor's CreatedDate (when it started) rather than
      // System.now() (when it finished). This prevents a gap: records
      // modified during the predecessor's execution window are covered by
      // the successor's query (>= predecessor start). The tradeoff is
      // bounded overlap near the boundary, which is correct at-least-once
      // behavior — the same contract Temporal/DBOS use for polling cursors.
      Previous_Run_At__c = instance.CreatedDate
    );
    insertSuccessorRecord(nextInstance, newKey);
    copyPredecessorSearchAttributes(instance.Id, nextInstance.Id);
    finalizeSuccessorInstance(nextInstance, result, initialStep);
  }

  // Insert the successor instance, translating a duplicate-key collision into a
  // WorkflowException.
  private static void insertSuccessorRecord(
    Workflow_Instance__c nextInstance,
    String newKey
  ) {
    try {
      Database.insert(nextInstance, true, AccessLevel.SYSTEM_MODE);
    } catch (DmlException ex) {
      if (ex.getDmlStatusCode(0) == 'DUPLICATE_VALUE') {
        throw new WorkflowEngine.WorkflowException(
          'An active workflow already exists with correlation key: ' + newKey
        );
      }
      throw ex;
    }
  }

  // Copy the predecessor's search attributes onto the successor instance.
  private static void copyPredecessorSearchAttributes(
    Id predecessorId,
    Id successorId
  ) {
    List<Workflow_Search_Attribute__c> predecessorAttrs = [
      SELECT Key__c, Value__c
      FROM Workflow_Search_Attribute__c
      WHERE Workflow_Instance__c = :predecessorId
      WITH SYSTEM_MODE
    ];
    if (predecessorAttrs.isEmpty()) {
      return;
    }
    List<Workflow_Search_Attribute__c> successorAttrs = new List<Workflow_Search_Attribute__c>();
    for (Workflow_Search_Attribute__c attr : predecessorAttrs) {
      successorAttrs.add(
        new Workflow_Search_Attribute__c(
          Workflow_Instance__c = successorId,
          Key__c = attr.Key__c,
          Value__c = attr.Value__c,
          Key_Value__c = attr.Key__c +
            '=' +
            (attr.Value__c == null ? '' : attr.Value__c)
        )
      );
    }
    Database.insert(successorAttrs, true, AccessLevel.SYSTEM_MODE);
  }

  // Set the successor's input, pre-create its first step, and enqueue its run.
  private static void finalizeSuccessorInstance(
    Workflow_Instance__c nextInstance,
    StepResult result,
    String initialStep
  ) {
    // Set input and save payload
    nextInstance.Input__c = WorkflowPayloadOffload.savePayloadIfNeeded(
      nextInstance.Id,
      result.directive().continuation.nextInputJson,
      'Input_' + nextInstance.Id
    );

    // A concurrency-bounded successor must pass the admission gate on its first
    // RUN_STEP before it owns a slot, so defer the initial step's timeout until
    // admission re-arms it (mirrors doStart). Otherwise the still-Pending successor
    // could be failed by the timeout sweep while waiting in the backlog for a slot.
    Boolean deferTimeoutForConcurrency = ConcurrencyGate.isConfigured(
      nextInstance.Workflow_Name__c
    );
    // Durable awaiting-admission marker (see doStart): keeps the pre-start watchdog
    // keyed off persisted state rather than the live CMDT. Cleared on admission.
    if (deferTimeoutForConcurrency) {
      nextInstance.Concurrency_Parked__c = true;
    }
    Database.update(nextInstance, true, AccessLevel.SYSTEM_MODE);

    // Pre-create the successor's first step execution log
    if (String.isNotBlank(initialStep)) {
      Workflow_Step_Execution__c nextStepExec = new Workflow_Step_Execution__c();
      nextStepExec.Workflow_Instance__c = nextInstance.Id;
      nextStepExec.Step_Name__c = initialStep;
      nextStepExec.Status__c = 'Pending';
      nextStepExec.Input__c = nextInstance.Input__c;
      nextStepExec.Retry_Count__c = 0;
      Integer timeout = WorkflowStepTimeoutConfig.getStepTimeoutSeconds(
        initialStep,
        WorkflowTypeResolver.extractNamespace(nextInstance.Workflow_Name__c)
      );
      if (timeout != null && timeout > 0 && !deferTimeoutForConcurrency) {
        nextStepExec.Timeout_At__c = DateTime.now().addSeconds(timeout);
      }
      Database.insert(nextStepExec, true, AccessLevel.SYSTEM_MODE);
    }

    // Enqueue the successor run
    if (!deferTimeoutForConcurrency) {
      WorkflowTimeoutArming.scheduleTimeoutJobForInstance(nextInstance.Id);
    }
    if (Test.isRunningTest()) {
      if (!WorkflowEngine.disableQueueableInTest) {
        System.enqueueJob(new WorkflowOrchestrator(nextInstance.Id));
      }
    } else {
      WorkflowOrchestratorEnqueue.enqueueOrchestrator(nextInstance.Id, null);
    }
  }

  /**
   * @description FAIL outcome: records a deliberate terminal step failure
   * (append-only, with reason and any structured failure data), consumes the
   * step's observed signals, publishes its buffered outbound events, then routes
   * through the shared fail path to compensate or fail the instance.
   * @param outcome the step outcome bundle carrying instance, step exec, result
   * and context
   */
  public static void handleFailOutcome(
    WorkflowEngine.StepOutcomeContext outcome
  ) {
    Workflow_Instance__c instance = outcome.instance;
    Workflow_Step_Execution__c stepExec = outcome.stepExec;
    StepResult result = outcome.result;
    StepContext context = outcome.context;
    // Explicit terminal failure (issue #37): the author returned a deliberate
    // business failure — not a crash, not a retry. Record the step terminal
    // exactly once (append-only) with the operator-readable reason (and any
    // structured failureData) in Error_Details__c, then route through the
    // existing failWorkflowInstance path. That performs ZERO retry hops and
    // transitions to Compensating (LIFO rollback) when a Compensation_Stack__c
    // exists, or to Failed otherwise; Terminal_At__c is stamped by
    // WorkflowInstanceTrigger on the terminal transition, exactly as a thrown
    // failure does today.
    //
    // Signal consumption mirrors the COMPLETE path: the step ran to its terminal
    // conclusion so any signals it observed are marked consumed (not rolled back),
    // preventing re-delivery to later compensation steps.
    WorkflowSignalConsume.markSignalsConsumedForOutcome(instance.Id, outcome);
    stepExec.Status__c = 'Failed';
    // Plain-text schema matches RETRY/crash paths. When failureData is present
    // the raw JSON is appended on a second line for downstream inspection without
    // needing to detect a JSON envelope.
    stepExec.Error_Details__c = (result.directive().failureDataJson != null)
      ? result.directive().failureReason +
        '\nfailureData: ' +
        result.directive().failureDataJson
      : result.directive().failureReason;
    WorkflowEngine.saveStepExec(stepExec);

    // Publish any domain events the step buffered via StepContext.emit() before
    // returning fail() — same commit-coupling contract as COMPLETE/SPLIT so
    // callers never silently lose events on deliberate terminal failures.
    WorkflowStepOutcome.publishOutboundEvents(result, context);

    WorkflowEngine.FailInstanceRequest explicitFailReq = new WorkflowEngine.FailInstanceRequest();
    explicitFailReq.instanceId = instance.Id;
    explicitFailReq.stepName = stepExec.Step_Name__c;
    explicitFailReq.errorMessage = result.directive().failureReason;
    explicitFailReq.failureCategory = WorkflowEngine.CAT_EXPLICIT_FAIL;
    WorkflowEngine.failWorkflowInstance(explicitFailReq);
  }

  private static String resolveContinueAsNewKey(
    String currentKey,
    String customKey
  ) {
    if (String.isNotBlank(customKey)) {
      return customKey;
    }
    if (String.isBlank(currentKey)) {
      return 'Run_' + System.currentTimeMillis();
    }

    Pattern p = Pattern.compile('^(.*)_run(\\d+)$');
    Matcher m = p.matcher(currentKey);
    if (m.matches()) {
      String base = m.group(1);
      Integer nextNum = Integer.valueOf(m.group(2)) + 1;
      return base + '_run' + nextNum;
    }
    return currentKey + '_run2';
  }
}
