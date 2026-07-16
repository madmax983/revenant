/**
 * @description Step-establishment and step-execution lock phase of the durable
 * step-execution sequence. First resolves and initializes the step to run in
 * memory, then acquires the SECOND of the two ordered locks (after the
 * concurrency-admission instance `FOR UPDATE`): it locks the latest
 * step-execution row `FOR UPDATE`, re-reads the instance under that lock,
 * re-checks terminality, and builds or reuses the step-execution record the step
 * will run against — returning an early-exit signal when the instance is already
 * finished or the step was completed/terminated by a concurrent thread. All DML
 * and SOQL run in system mode.
 */
public inherited sharing class WorkflowStepExecLock {
  /**
   * @description §2. Initialize the initial step in memory if this is the start
   * (DML deferred to the outcome handler). Runs just before the step-execution
   * row is locked, establishing the step name the lock will target.
   * @param instance the instance whose in-memory step state is initialized
   */
  public static void initializeStepInMemory(Workflow_Instance__c instance) {
    if (String.isBlank(instance.Current_Step__c)) {
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
      WorkflowDefinition def = (WorkflowDefinition) wflowType.newInstance();
      instance.Current_Step__c = def.getInitialStep();
      instance.Status__c = 'Running';
    } else if (
      instance.Status__c == 'Suspended' ||
      instance.Status__c == 'Pending'
    ) {
      instance.Status__c = 'Running';
      instance.Async_Job_Id__c = null;
    }
  }

  /**
   * @description §3. Retrieve or create the step execution log with a FOR UPDATE
   * lock, and re-query the instance under the lock. Populates the run context's
   * visit count, reloaded instance and step-execution row. Returns true on an
   * early exit (already finished, or the step was completed/terminated by a
   * concurrent thread).
   * @param ctx the run context to populate (instance, stepExec, stepVisit)
   * @return true when the caller must early-exit
   */
  public static Boolean acquireStepExecutionLog(
    WorkflowStepRunner.RunStepContext ctx
  ) {
    Id instanceId = ctx.instanceId;
    String activeStepName = ctx.activeStepName;
    List<Workflow_Step_Execution__c> stepExecs = [
      SELECT Id, Step_Name__c, Status__c, Input__c, Output__c, Retry_Count__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :instanceId
        AND Step_Name__c = :activeStepName
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC, Id DESC
    ];

    ctx.stepVisit = computeCompletedVisitCount(stepExecs);
    stepExecs = lockLatestStepExecIfPresent(stepExecs);

    // Re-query the instance after acquiring the lock on the step execution to get
    // the most up-to-date committed state.
    Workflow_Instance__c instance = reloadInstanceLocked(instanceId);
    ctx.instance = instance;

    // Check early exit conditions for instance status
    if (WorkflowStepRunner.isFinishedStatus(instance.Status__c)) {
      return true; // Already finished
    }

    Workflow_Step_Execution__c stepExec = buildOrReuseStepExec(ctx, stepExecs);
    if (stepExec == null) {
      return true; // Already completed or terminated by concurrent thread
    }
    ctx.stepExec = stepExec;
    return false;
  }

  // Count the already-completed (or operator-skipped) runs of this step.
  private static Integer computeCompletedVisitCount(
    List<Workflow_Step_Execution__c> stepExecs
  ) {
    Integer stepVisit = 0;
    for (Workflow_Step_Execution__c exec : stepExecs) {
      if (
        exec.Status__c == 'Completed' ||
        exec.Status__c == 'OperatorSkipped'
      ) {
        stepVisit++;
      }
    }
    return stepVisit;
  }

  // Re-read the latest step execution FOR UPDATE (with the columns the drive
  // needs) when one exists; otherwise return the empty list unchanged.
  private static List<Workflow_Step_Execution__c> lockLatestStepExecIfPresent(
    List<Workflow_Step_Execution__c> stepExecs
  ) {
    if (stepExecs.isEmpty()) {
      return stepExecs;
    }
    return [
      SELECT
        Id,
        Step_Name__c,
        Status__c,
        Input__c,
        Output__c,
        Retry_Count__c,
        Transient_Retry_Count__c,
        Captured_Values__c
      FROM Workflow_Step_Execution__c
      WHERE Id = :stepExecs[0].Id
      WITH SYSTEM_MODE
      FOR UPDATE
    ];
  }

  // Re-query the instance under the step lock; throw if it vanished.
  private static Workflow_Instance__c reloadInstanceLocked(Id instanceId) {
    List<Workflow_Instance__c> instances = [
      SELECT
        Id,
        Name,
        Workflow_Name__c,
        Status__c,
        Current_Step__c,
        Input__c,
        Correlation_Key__c,
        Root_Correlation_Key__c,
        Parent_Instance__c,
        Compensation_Stack__c,
        Definition_Version__c,
        Error_Message__c,
        Previous_Run_At__c,
        Concurrency_Slot_Held__c,
        Concurrency_Parked__c,
        CreatedDate,
        Causation_Id__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
      WITH SYSTEM_MODE
      LIMIT 1
    ];
    if (instances.isEmpty()) {
      throw new WorkflowEngine.WorkflowException(
        'Workflow instance not found: ' + instanceId
      );
    }
    return instances[0];
  }

  // Build a fresh step execution (seeded with the previous step's output) or
  // reuse the locked one; returns null when the reused step is already terminal.
  private static Workflow_Step_Execution__c buildOrReuseStepExec(
    WorkflowStepRunner.RunStepContext ctx,
    List<Workflow_Step_Execution__c> stepExecs
  ) {
    if (stepExecs.isEmpty()) {
      Workflow_Step_Execution__c stepExec = new Workflow_Step_Execution__c();
      stepExec.Workflow_Instance__c = ctx.instanceId;
      stepExec.Step_Name__c = ctx.activeStepName;
      stepExec.Status__c = 'Running';
      stepExec.Retry_Count__c = 0;
      stepExec.Transient_Retry_Count__c = 0;

      // Get previous step's output to feed as input
      List<Workflow_Step_Execution__c> completedSteps = [
        SELECT Output__c
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :ctx.instanceId
          AND Status__c IN ('Completed', 'OperatorSkipped')
        WITH SYSTEM_MODE
        ORDER BY CreatedDate DESC, Id DESC
        LIMIT 1
      ];
      stepExec.Input__c = !completedSteps.isEmpty()
        ? completedSteps[0].Output__c
        : ctx.instance.Input__c;
      return stepExec;
    }

    Workflow_Step_Execution__c stepExec = stepExecs[0];
    if (isStepExecTerminal(stepExec.Status__c)) {
      return null;
    }
    stepExec.Status__c = 'Running';
    return stepExec;
  }

  // A step execution status that is already terminal for this drive.
  private static Boolean isStepExecTerminal(String status) {
    return status == 'Completed' ||
      status == 'OperatorSkipped' ||
      status == 'Failed' ||
      status == 'Cancelled' ||
      status == 'Compensated';
  }
}
