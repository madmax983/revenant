/**
 * @description Parallel-branch join phase for the operator "resume past step"
 * intervention. When the skipped step is one of several active parallel
 * branches, this class loads the latest execution per branch, decides whether
 * every branch is done, resolves the spawning step's join/next step, and either
 * completes the workflow or spawns the join step. When branches remain
 * incomplete it delegates to {@link WorkflowOperatorSkipParallelResume}. Shared
 * terminal/enqueue helpers live on {@link WorkflowOperatorSkipAdvance}. All DML
 * and SOQL run in system mode. Split out of {@link WorkflowOperatorSkip} so each
 * cohesive phase stays within its own complexity budget.
 */
public inherited sharing class WorkflowOperatorSkipParallel {
  /**
   * @description Advance parallel branches after an operator skip: join when all
   * done, otherwise re-drive the incomplete siblings.
   * @param run the resume-past-step accumulator
   */
  public static void advanceParallelSkip(
    WorkflowOperatorSkip.ResumeSkipRun run
  ) {
    // Parallel branches: load all parallel step executions to see if we can join
    run.activeParallelSteps = run.instance.Current_Step__c.split(',');
    run.latestParallelMap = loadResumeParallelExecs(run);

    Boolean allDone = isAllParallelDone(
      run.activeParallelSteps,
      run.latestParallelMap
    );

    String nextStepName = resolveParallelSkipNextStep(run);

    if (allDone) {
      completeOrJoinParallel(run, nextStepName);
    } else {
      WorkflowOperatorSkipParallelResume.resumeIncompleteParallel(run);
    }
  }

  /**
   * @description True when every active parallel branch is `Completed` or
   * `OperatorSkipped`.
   * @param activeParallelSteps the active parallel branch step names
   * @param latestExecByStep the latest execution per parallel step
   * @return true when all parallel branches are done
   */
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

  /**
   * @description Load the latest execution per active parallel step (including
   * `Timeout_At__c`).
   * @param run the resume-past-step accumulator
   * @return the latest execution per active parallel step name
   */
  private static Map<String, Workflow_Step_Execution__c> loadResumeParallelExecs(
    WorkflowOperatorSkip.ResumeSkipRun run
  ) {
    Id instanceId = run.instanceId;
    List<String> activeParallelSteps = run.activeParallelSteps;
    Map<String, Workflow_Step_Execution__c> latestParallelMap = new Map<String, Workflow_Step_Execution__c>();
    for (Workflow_Step_Execution__c pe : [
      SELECT Step_Name__c, Status__c, Output__c, CPU_Time_Ms__c, Timeout_At__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :instanceId
        AND Step_Name__c IN :activeParallelSteps
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC, Id DESC
    ]) {
      if (!latestParallelMap.containsKey(pe.Step_Name__c)) {
        latestParallelMap.put(pe.Step_Name__c, pe);
      }
    }
    return latestParallelMap;
  }

  /**
   * @description Resolve the join/next step for the parallel skip via the
   * spawning step.
   * @param run the resume-past-step accumulator
   * @return the resolved next/join step name
   */
  private static String resolveParallelSkipNextStep(
    WorkflowOperatorSkip.ResumeSkipRun run
  ) {
    Workflow_Instance__c instance = run.instance;
    Id instanceId = run.instanceId;
    List<String> activeParallelSteps = run.activeParallelSteps;
    // Spawning step
    List<Workflow_Step_Execution__c> spawningSteps = [
      SELECT Step_Name__c, Output__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :instanceId
        AND Status__c IN ('Completed', 'OperatorSkipped')
        AND Step_Name__c NOT IN :activeParallelSteps
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC, Id DESC
      LIMIT 1
    ];
    String spawningStepName = !spawningSteps.isEmpty()
      ? spawningSteps[0].Step_Name__c
      : '';
    StepResult mockSpawningResult = StepResult.complete(
      'SENTINEL_NEXT_STEP',
      !spawningSteps.isEmpty() ? spawningSteps[0].Output__c : null
    );

    String nextStepName;
    if (run.def instanceof VersionedWorkflow) {
      nextStepName = ((VersionedWorkflow) run.def)
        .getNextStep(
          spawningStepName,
          mockSpawningResult,
          instance.Definition_Version__c != null
            ? (Integer) instance.Definition_Version__c
            : 1
        );
    } else {
      nextStepName = run.def.getNextStep(spawningStepName, mockSpawningResult);
    }

    if (nextStepName == 'SENTINEL_NEXT_STEP') {
      throw new WorkflowEngine.WorkflowException(
        'Skip is not supported for dynamic-next step definitions.'
      );
    }
    return nextStepName;
  }

  /**
   * @description All parallel branches are done: build the join input and either
   * complete the workflow or spawn the join step.
   * @param run the resume-past-step accumulator
   * @param nextStepName the resolved join/next step name (blank to complete)
   */
  private static void completeOrJoinParallel(
    WorkflowOperatorSkip.ResumeSkipRun run,
    String nextStepName
  ) {
    Workflow_Instance__c instance = run.instance;
    String joinInputJson = buildParallelJoinInput(run);

    if (String.isBlank(nextStepName)) {
      WorkflowOperatorSkipAdvance.markSkipInstanceCompleted(
        run,
        joinInputJson,
        'Output_Join'
      );
      return;
    }

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
    instance.Status__c = 'Running';
    instance.Error_Message__c = null;
    instance.Failure_Category__c = null;
    Boolean deferTimeoutForConcurrency = ConcurrencyGate.isConfigured(
      instance.Workflow_Name__c
    );
    if (deferTimeoutForConcurrency) {
      instance.Concurrency_Parked__c = true;
    }
    Database.update(instance, true, AccessLevel.SYSTEM_MODE);

    if (!deferTimeoutForConcurrency) {
      WorkflowTimeoutArming.scheduleTimeoutJobForInstance(instance.Id);
    }
    WorkflowOperatorSkipAdvance.enqueueSkipOrchestrator(instance.Id);
  }

  /**
   * @description Assemble the merged join input JSON from every parallel
   * branch's output.
   * @param run the resume-past-step accumulator
   * @return the serialized merged join input
   */
  private static String buildParallelJoinInput(
    WorkflowOperatorSkip.ResumeSkipRun run
  ) {
    Map<String, Object> joinInput = new Map<String, Object>();
    for (String ps : run.latestParallelMap.keySet()) {
      Workflow_Step_Execution__c pe = run.latestParallelMap.get(ps);
      Object outputVal = null;
      String resolvedOutput = WorkflowPayloadOffload.resolvePayload(
        pe.Output__c
      );
      if (String.isNotBlank(resolvedOutput)) {
        try {
          outputVal = JSON.deserializeUntyped(resolvedOutput);
        } catch (Exception ex) {
          outputVal = resolvedOutput;
        }
      }
      joinInput.put(pe.Step_Name__c, outputVal);
    }
    return JSON.serialize(joinInput);
  }
}
