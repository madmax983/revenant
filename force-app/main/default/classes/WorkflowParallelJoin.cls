/**
 * @description Parallel fan-in for the Revenant step outcome. When a parallel
 * branch completes, loads the latest execution per active branch, decides
 * whether all branches are done, and either applies the incomplete verdict
 * (suspend or fail) or proceeds to the join step -- resolving the next step,
 * assembling the join input from each branch's output, and advancing the
 * instance. Extracted from `WorkflowEngine`;
 * {@link WorkflowParallelJoin#completeParallelBranch} is invoked by the COMPLETE
 * handler for a parallel branch. All SOQL and DML run in system mode.
 */
public inherited sharing class WorkflowParallelJoin {
  /**
   * @description Parallel COMPLETE fan-in: when a branch finishes, loads the
   * latest execution per active branch and either applies the incomplete verdict
   * (suspend when only pending work remains, fail when the non-done branches
   * failed) or proceeds to the join step. Public so the COMPLETE handler can
   * invoke it for a parallel branch.
   * @param outcome the step outcome bundle carrying instance, step exec and context
   */
  public static void completeParallelBranch(
    WorkflowEngine.StepOutcomeContext outcome
  ) {
    Workflow_Instance__c instance = outcome.instance;
    List<String> activeParallelSteps = instance.Current_Step__c.split(',');
    Map<String, Workflow_Step_Execution__c> latestExecByStep = loadLatestParallelExecs(
      instance.Id,
      activeParallelSteps
    );

    if (!isAllParallelDone(activeParallelSteps, latestExecByStep)) {
      applyIncompleteParallelStatus(
        instance,
        activeParallelSteps,
        latestExecByStep
      );
      return;
    }

    proceedToJoin(outcome, activeParallelSteps, latestExecByStep);
  }

  // Load the latest step execution per active parallel step.
  private static Map<String, Workflow_Step_Execution__c> loadLatestParallelExecs(
    Id instanceId,
    List<String> activeParallelSteps
  ) {
    List<Workflow_Step_Execution__c> parallelExecs = [
      SELECT Step_Name__c, Status__c, Output__c, CPU_Time_Ms__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :instanceId
        AND Step_Name__c IN :activeParallelSteps
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC, Id DESC
    ];

    Map<String, Workflow_Step_Execution__c> latestExecByStep = new Map<String, Workflow_Step_Execution__c>();
    for (Workflow_Step_Execution__c pe : parallelExecs) {
      if (!latestExecByStep.containsKey(pe.Step_Name__c)) {
        latestExecByStep.put(pe.Step_Name__c, pe);
      }
    }
    return latestExecByStep;
  }

  // True when every active parallel branch is Completed or OperatorSkipped.
  private static Boolean isAllParallelDone(
    List<String> activeParallelSteps,
    Map<String, Workflow_Step_Execution__c> latestExecByStep
  ) {
    for (String ps : activeParallelSteps) {
      Workflow_Step_Execution__c pe = latestExecByStep.get(ps);
      if (
        pe == null ||
        (pe.Status__c != 'Completed' &&
        pe.Status__c != 'OperatorSkipped')
      ) {
        return false;
      }
    }
    return true;
  }

  // Not-all-done parallel branches: suspend when only pending work remains, or
  // fail when the only non-done branches failed.
  private static void applyIncompleteParallelStatus(
    Workflow_Instance__c instance,
    List<String> activeParallelSteps,
    Map<String, Workflow_Step_Execution__c> latestExecByStep
  ) {
    String verdict = WorkflowParallelVerdict.classifyIncompleteParallel(
      activeParallelSteps,
      latestExecByStep
    );
    if (verdict == 'SUSPEND') {
      instance.Status__c = 'Suspended';
      Database.update(instance, true, AccessLevel.SYSTEM_MODE);
    } else if (verdict == 'FAIL') {
      instance.Status__c = 'Failed';
      Database.update(instance, true, AccessLevel.SYSTEM_MODE);
    }
  }

  // All parallel branches done: resolve the join step and either finish the
  // workflow or create the join step execution.
  private static void proceedToJoin(
    WorkflowEngine.StepOutcomeContext outcome,
    List<String> activeParallelSteps,
    Map<String, Workflow_Step_Execution__c> latestExecByStep
  ) {
    Workflow_Instance__c instance = outcome.instance;

    // All parallel steps completed. Proceed to Join step.
    List<Workflow_Step_Execution__c> spawningSteps = [
      SELECT Step_Name__c, Output__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :instance.Id
        AND Status__c IN ('Completed', 'OperatorSkipped')
        AND Step_Name__c NOT IN :activeParallelSteps
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC, Id DESC
      LIMIT 1
    ];

    String spawningStepName = !spawningSteps.isEmpty()
      ? spawningSteps[0].Step_Name__c
      : '';
    StepResult mockResult = StepResult.complete(
      null,
      !spawningSteps.isEmpty() ? spawningSteps[0].Output__c : null
    );

    String nextStepName = WorkflowStepAdvance.resolveNextStepName(
      instance,
      spawningStepName,
      mockResult
    );

    String joinInputJson = JSON.serialize(
      buildJoinInput(activeParallelSteps, latestExecByStep)
    );

    if (String.isBlank(nextStepName)) {
      WorkflowStepAdvance.completeWorkflowInstance(
        instance,
        joinInputJson,
        'Output_Join'
      );
      return;
    }

    createJoinStep(instance, nextStepName, joinInputJson);
  }

  // Assemble the join step's input map from each branch's resolved output.
  private static Map<String, Object> buildJoinInput(
    List<String> activeParallelSteps,
    Map<String, Workflow_Step_Execution__c> latestExecByStep
  ) {
    Map<String, Object> joinInput = new Map<String, Object>();
    for (String ps : activeParallelSteps) {
      Workflow_Step_Execution__c pe = latestExecByStep.get(ps);
      if (pe == null) {
        continue;
      }
      Object outputVal = null;
      String resolvedOutput = WorkflowPayloadOffload.resolvePayload(
        pe.Output__c
      );
      if (String.isNotBlank(resolvedOutput)) {
        try {
          outputVal = JSON.deserializeUntyped(resolvedOutput);
        } catch (Exception ignored) {
          // Output was not JSON; fall back to the raw string value.
          outputVal = resolvedOutput;
        }
      }
      joinInput.put(ps, outputVal);
    }
    return joinInput;
  }

  // Create the join step execution and advance the instance to it.
  private static void createJoinStep(
    Workflow_Instance__c instance,
    String nextStepName,
    String joinInputJson
  ) {
    Workflow_Step_Execution__c joinStepExec = new Workflow_Step_Execution__c();
    joinStepExec.Workflow_Instance__c = instance.Id;
    joinStepExec.Step_Name__c = nextStepName;
    joinStepExec.Status__c = 'Pending';
    joinStepExec.Input__c = WorkflowPayloadOffload.savePayloadIfNeeded(
      instance.Id,
      joinInputJson,
      'Input_' + nextStepName.replaceAll('[^a-zA-Z0-9]', '_')
    );
    joinStepExec.Retry_Count__c = 0;
    Database.insert(joinStepExec, true, AccessLevel.SYSTEM_MODE);

    instance.Current_Step__c = nextStepName;
    Database.update(instance, true, AccessLevel.SYSTEM_MODE);

    WorkflowTimeoutArming.scheduleTimeoutJobForInstance(instance.Id);
    WorkflowOrchestratorEnqueue.enqueueOrchestrator(instance.Id, null);
  }
}
