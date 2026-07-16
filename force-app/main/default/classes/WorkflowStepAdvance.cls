/**
 * @description Forward-advance and parallel-join half of the Revenant step
 * outcome. Durably completes a step, then either resolves and advances the
 * serial next step, finalizes the workflow instance, or (for a parallel branch)
 * evaluates the fan-in: loading the latest execution per active branch, deciding
 * all-done versus incomplete (suspend or fail), and proceeding to the join step.
 * Extracted from `WorkflowEngine`; {@link WorkflowStepAdvance#handleCompleteOutcome}
 * is invoked by the outcome dispatch. All SOQL and DML run in system mode.
 */
public inherited sharing class WorkflowStepAdvance {
  /**
   * @description COMPLETE outcome: durably completes the step (storing its
   * output), consumes the signals it observed, publishes its buffered outbound
   * events, updates the compensation stack when compensatable, then advances the
   * serial next step or (for a parallel branch) evaluates the fan-in join.
   * @param outcome the step outcome bundle carrying instance, step exec, result
   * and context
   */
  public static void handleCompleteOutcome(
    WorkflowEngine.StepOutcomeContext outcome
  ) {
    Workflow_Instance__c instance = outcome.instance;
    Workflow_Step_Execution__c stepExec = outcome.stepExec;
    StepResult result = outcome.result;
    StepContext context = outcome.context;
    Boolean isParallel = outcome.isParallel;
    // Step is complete. Store output.
    stepExec.Status__c = 'Completed';
    stepExec.Output__c = WorkflowPayloadOffload.savePayloadIfNeeded(
      instance.Id,
      result.directive().outputJson,
      'Output_' + stepExec.Step_Name__c.replaceAll('[^a-zA-Z0-9]', '_')
    );
    WorkflowEngine.saveStepExec(stepExec);

    // Tie signal consumption to the step's durable COMPLETE transition: only
    // now (not on yield/retry/suspend) are the signals this step observed
    // marked consumed, so an at-least-once redelivered duplicate cannot be
    // reprocessed by a later step. A parallel branch consumes only its own
    // claimed ids so it cannot strip a sibling branch's signal.
    WorkflowSignalConsume.markSignalsConsumedForOutcome(instance.Id, outcome);

    // Effectively-once outbound emit (issue #64): the step's buffered domain
    // events publish here, in the same transaction that just wrote the
    // Completed record and before the next step's RUN_STEP event is enqueued.
    // Anything buffered on a yield/retry/suspend re-execution was discarded
    // with that context, so a re-run before this commit publishes nothing.
    WorkflowStepOutcome.publishOutboundEvents(result, context);

    updateCompensationStackIfNeeded(instance, stepExec);

    if (!isParallel) {
      advanceSerialStep(outcome);
      return;
    }

    WorkflowParallelJoin.completeParallelBranch(outcome);
  }

  // Push the just-completed step onto the compensation stack when it is a
  // CompensatableStep, persisting the updated stack immediately.
  private static void updateCompensationStackIfNeeded(
    Workflow_Instance__c instance,
    Workflow_Step_Execution__c stepExec
  ) {
    Type stepType = WorkflowTypeResolver.resolve(
      stepExec.Step_Name__c,
      WorkflowTypeResolver.extractNamespace(instance.Workflow_Name__c)
    );
    if (stepType == null) {
      return;
    }
    Object stepInstanceObj = stepType.newInstance();
    if (!(stepInstanceObj instanceof CompensatableStep)) {
      return;
    }
    List<String> stack = new List<String>();
    if (String.isNotBlank(instance.Compensation_Stack__c)) {
      stack = (List<String>) JSON.deserialize(
        instance.Compensation_Stack__c,
        List<String>.class
      );
    }
    stack.add(stepExec.Step_Name__c);
    instance.Compensation_Stack__c = JSON.serialize(stack);
    // If not parallel or if parallel and not all done, update here so stack is saved.
    // (Parallel allDone paths will update instance later, but doing a single update here is safe).
    Database.update(instance, true, AccessLevel.SYSTEM_MODE);
  }

  // Serial COMPLETE: resolve the next step and either finish the workflow or
  // advance to the next step.
  private static void advanceSerialStep(
    WorkflowEngine.StepOutcomeContext outcome
  ) {
    Workflow_Instance__c instance = outcome.instance;
    Workflow_Step_Execution__c stepExec = outcome.stepExec;
    StepResult result = outcome.result;

    String nextStepName = resolveNextStepName(
      instance,
      instance.Current_Step__c,
      result
    );

    if (String.isBlank(nextStepName)) {
      // Workflow is finished
      completeWorkflowInstance(
        instance,
        result.directive().outputJson,
        'Output_Final'
      );
      return;
    }

    // Advance to next step
    instance.Current_Step__c = nextStepName;
    Database.update(instance, true, AccessLevel.SYSTEM_MODE);

    Workflow_Step_Execution__c nextStepExec = new Workflow_Step_Execution__c();
    nextStepExec.Workflow_Instance__c = instance.Id;
    nextStepExec.Step_Name__c = nextStepName;
    nextStepExec.Status__c = 'Pending';
    nextStepExec.Input__c = stepExec.Output__c;
    nextStepExec.Retry_Count__c = 0;
    Database.insert(nextStepExec, true, AccessLevel.SYSTEM_MODE);

    // Pass the in-memory instance (Current_Step__c just advanced to nextStepName,
    // committed above) so the per-advance watchdog scheduling does not re-query the
    // instance on every step — that re-read is what exhausts the SOQL limit on a
    // long synchronous drive.
    WorkflowTimeoutArming.scheduleTimeoutJobForInstance(instance);
    WorkflowOrchestratorEnqueue.enqueueOrchestrator(instance.Id, null);
  }

  // Resolve the workflow definition class for an instance, throwing when it
  // cannot be resolved.
  private static WorkflowDefinition resolveWorkflowDefinition(
    Workflow_Instance__c instance
  ) {
    Type wflowType = WorkflowTypeResolver.resolve(
      instance.Workflow_Name__c,
      WorkflowTypeResolver.extractNamespace(instance.Workflow_Name__c)
    );
    if (wflowType == null) {
      throw new WorkflowEngine.WorkflowException(
        'Could not resolve workflow definition class: ' +
        instance.Workflow_Name__c
      );
    }
    return (WorkflowDefinition) wflowType.newInstance();
  }

  /**
   * @description Resolves the next step name for the instance, honoring a
   * VersionedWorkflow definition (with the instance's definition version) when
   * applicable. Public so the parallel-join path can resolve the post-join step.
   * @param instance the workflow instance being advanced
   * @param currentStepArg the current step name to resolve the successor of
   * @param result the step result driving conditional next-step resolution
   * @return the next step name, or blank when the workflow is finished
   */
  public static String resolveNextStepName(
    Workflow_Instance__c instance,
    String currentStepArg,
    StepResult result
  ) {
    WorkflowDefinition def = resolveWorkflowDefinition(instance);
    if (def instanceof VersionedWorkflow) {
      return ((VersionedWorkflow) def)
        .getNextStep(
          currentStepArg,
          result,
          instance.Definition_Version__c != null
            ? (Integer) instance.Definition_Version__c
            : 1
        );
    }
    return def.getNextStep(currentStepArg, result);
  }

  /**
   * @description Terminally completes a workflow instance: stores the final
   * output, clears the current step, notifies the parent and publishes the
   * lifecycle event. Public so the parallel-join path can finalize the workflow
   * when the join resolves no next step.
   * @param instance the workflow instance to complete
   * @param outputJson the final output JSON to persist
   * @param payloadLabel the payload label used when offloading the output
   */
  public static void completeWorkflowInstance(
    Workflow_Instance__c instance,
    String outputJson,
    String payloadLabel
  ) {
    instance.Status__c = 'Completed';
    instance.Output__c = WorkflowPayloadOffload.savePayloadIfNeeded(
      instance.Id,
      outputJson,
      payloadLabel
    );
    instance.Current_Step__c = null;
    Database.update(instance, true, AccessLevel.SYSTEM_MODE);

    // Parent notification publishes the load-bearing Workflow_Event__e, so it
    // runs BEFORE the best-effort lifecycle publish (first claim on DML budget).
    WorkflowParentNotifier.notifyParentCompletion(instance);

    // Fire-and-forget outbound lifecycle event on terminal transition.
    WorkflowLifecyclePublisher.publish(instance);
  }
}
