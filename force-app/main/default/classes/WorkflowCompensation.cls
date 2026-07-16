/**
 * @description Compensation entry & lifecycle: the manual `compensate` trigger for
 * a Completed saga, the operator `resumeCompensation` of a stalled
 * (CompensationFailed) rollback, and `preCreateFirstCompensationStep` which seeds
 * the first pending `_Compensate` step so the orchestrator has a concrete step to
 * drive. Spawns the successor compensating instance and carries the root
 * correlation and causation lineage forward. All DML and SOQL run in system mode.
 */
public inherited sharing class WorkflowCompensation {
  /**
   * Resumes a saga whose rollback stalled (status CompensationFailed) from exactly
   * the failed compensation point. The remaining LIFO stack — preserved intact when
   * the compensation failed — is replayed in strict order through the existing
   * compensation/orchestrator path; no forward step is re-executed and no
   * already-successful compensation is re-run.
   *
   * Idempotent by construction: the status guard + FOR UPDATE lock means a second
   * (e.g. double-clicked) resume sees the instance already out of CompensationFailed
   * and is a no-op, so two concurrent orchestrator chains can never roll back the
   * same instance and no compensation is double-run.
   * @param instanceId Id of the CompensationFailed instance to resume rolling back
   */
  public static void resumeCompensation(Id instanceId) {
    List<Workflow_Instance__c> instances = [
      SELECT
        Id,
        Status__c,
        Compensation_Stack__c,
        Error_Message__c,
        Failure_Category__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId AND Status__c = 'CompensationFailed'
      WITH SYSTEM_MODE
      LIMIT 1
      FOR UPDATE
    ];
    if (instances.isEmpty()) {
      // Not stalled (already resumed, fully compensated, or never stalled). The
      // operator action is idempotent, so treat this as a safe no-op.
      return;
    }
    Workflow_Instance__c instance = instances[0];

    List<String> stack = new List<String>();
    if (String.isNotBlank(instance.Compensation_Stack__c)) {
      stack = (List<String>) JSON.deserialize(
        instance.Compensation_Stack__c,
        List<String>.class
      );
    }

    if (stack.isEmpty()) {
      // Defensive: a stalled state with no remaining work means the rollback is in
      // fact complete. Promote it to the fully-compensated terminal state.
      instance.Status__c = 'Compensated';
      instance.Current_Step__c = null;
      instance.Error_Message__c = null;
      instance.Failure_Category__c = null;
      Database.update(instance, true, AccessLevel.SYSTEM_MODE);
      return;
    }

    // Resume into the same phase the rollback was running in. A cancel-driven rollback
    // continues as 'Cancelling'; a failure-driven one as 'Compensating'. The phase is
    // identified by the engine-owned 'Cancelled by user' marker (set by cancel() and the
    // stalled-message builder) rather than an arbitrary 'Cancelled' substring, so a
    // failure-driven rollback whose compensation error text merely contains the word
    // "Cancelled" is not mistaken for a cancellation.
    Boolean isCancelling =
      instance.Error_Message__c != null &&
      instance.Error_Message__c.contains('Cancelled by user');
    instance.Status__c = isCancelling ? 'Cancelling' : 'Compensating';
    // Clear the stalled "rollback incomplete" banner, but for a cancel-driven rollback
    // keep the 'Cancelled by user' marker: runStep and the watchdog sleep-resume path read
    // it to restore the phase as 'Cancelling' if a remaining compensation suspends (RETRY/
    // SLEEP) before the stack drains. Without it the rollback would finish 'Compensated'
    // instead of 'Cancelled'. Also clear any stale sleep deadline so a later SUSPEND/
    // approval gate is not prematurely woken by the watchdog.
    instance.Error_Message__c = isCancelling
      ? 'Cancelled by user. Compensating.'
      : null;
    instance.Sleep_Until__c = null;
    instance.Async_Job_Id__c = null;
    instance.Failure_Category__c = null;
    Database.update(instance, true, AccessLevel.SYSTEM_MODE);

    // Append-only: create a FRESH pending compensation attempt for the stalled
    // top-of-stack step, leaving the failed attempt's record intact for the audit
    // trail. This is what makes runCompensationStep re-run the stalled compensation
    // rather than treating the prior Failed record as a terminal "already done".
    WorkflowCompensationStepLog.appendCompensationRetryStep(instance, stack);

    WorkflowTimeoutArming.scheduleTimeoutJobForInstance(instance.Id);
    if (Test.isRunningTest()) {
      if (!WorkflowEngine.disableQueueableInTest) {
        System.enqueueJob(new WorkflowOrchestrator(instance.Id));
      }
    } else {
      WorkflowOrchestratorEnqueue.enqueueOrchestrator(instance.Id, null);
    }
  }

  /**
   * @description Pre-creates the first pending compensation step for an instance
   * entering compensation, so the orchestrator has a concrete step to drive. Public
   * so the extracted `WorkflowFailureService` can open compensation through the same
   * resident helper. No-op when the compensation stack is empty.
   * @param instance the instance beginning compensation
   */
  public static void preCreateFirstCompensationStep(
    Workflow_Instance__c instance
  ) {
    if (String.isBlank(instance.Compensation_Stack__c)) {
      return;
    }
    List<String> stack = (List<String>) JSON.deserialize(
      instance.Compensation_Stack__c,
      List<String>.class
    );
    if (stack.isEmpty()) {
      return;
    }
    String activeStepName = stack[stack.size() - 1];
    String compensationStepLogName = activeStepName + '_Compensate';

    // Check if it already exists to avoid duplicates
    List<Workflow_Step_Execution__c> existing = [
      SELECT Id
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :instance.Id
        AND Step_Name__c = :compensationStepLogName
      WITH SYSTEM_MODE
      LIMIT 1
    ];
    if (!existing.isEmpty()) {
      return;
    }

    // Determine the source of the forward executions (original completed run or this run)
    Id forwardSourceInstanceId = WorkflowCompensationRunner.resolveForwardSourceInstanceId(
      instance
    );

    List<Workflow_Step_Execution__c> originalExecs = [
      SELECT Input__c, Output__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :forwardSourceInstanceId
        AND Step_Name__c = :activeStepName
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC, Id DESC
      LIMIT 1
    ];

    Workflow_Step_Execution__c compStepExec = new Workflow_Step_Execution__c();
    compStepExec.Workflow_Instance__c = instance.Id;
    compStepExec.Step_Name__c = compensationStepLogName;
    compStepExec.Status__c = 'Pending';
    compStepExec.Input__c = !originalExecs.isEmpty()
      ? originalExecs[0].Input__c
      : null;
    compStepExec.Output__c = !originalExecs.isEmpty()
      ? originalExecs[0].Output__c
      : null;
    compStepExec.Retry_Count__c = 0;
    Database.insert(compStepExec, true, AccessLevel.SYSTEM_MODE);
  }

  /**
   * Manually triggers compensation for a completed workflow instance.
   * Validates status, copies the compensation stack, spawns a new compensating instance,
   * links it to the original instance, and runs the rollback.
   * @param instanceId Id of the completed instance to compensate
   * @return Id of the new compensating instance
   */
  public static Id compensate(Id instanceId) {
    if (instanceId == null) {
      throw new WorkflowEngine.WorkflowException('Instance ID cannot be null.');
    }

    Workflow_Instance__c target = loadCompensationTarget(instanceId);

    // Spawn successor compensating instance. Carry the root correlation key forward.
    Workflow_Instance__c compensatingInstance = buildCompensatingInstance(
      target
    );
    Database.insert(compensatingInstance, true, AccessLevel.SYSTEM_MODE);

    // Link original instance to new compensating instance
    target.Compensated_By__c = compensatingInstance.Id;
    Database.update(target, true, AccessLevel.SYSTEM_MODE);

    // Pre-create the first compensation step execution log
    preCreateFirstCompensationStep(compensatingInstance);

    // Schedule watchdog and enqueue orchestrator
    enqueueCompensatingOrchestrator(compensatingInstance.Id);

    return compensatingInstance.Id;
  }

  /**
   * Loads and validates the target instance for compensation, locking it FOR
   * UPDATE. Throws when it is missing, not Completed, or has no compensation stack.
   * @param instanceId the instance to compensate
   * @return the locked, validated target instance
   */
  private static Workflow_Instance__c loadCompensationTarget(Id instanceId) {
    List<Workflow_Instance__c> targetInstances = [
      SELECT
        Id,
        Status__c,
        Compensation_Stack__c,
        Workflow_Name__c,
        Correlation_Key__c,
        Root_Correlation_Key__c,
        Definition_Version__c,
        Previous_Run_At__c,
        Input__c,
        Parent_Instance__c,
        Causation_Id__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
      WITH SYSTEM_MODE
      FOR UPDATE
    ];

    if (targetInstances.isEmpty()) {
      throw new WorkflowEngine.WorkflowException(
        'Workflow instance not found: ' + instanceId
      );
    }

    Workflow_Instance__c target = targetInstances[0];

    if (target.Status__c != 'Completed') {
      throw new WorkflowEngine.WorkflowException(
        'Only Completed workflow instances can be compensated. Current status: ' +
        target.Status__c
      );
    }

    if (String.isBlank(target.Compensation_Stack__c)) {
      throw new WorkflowEngine.WorkflowException(
        'No compensation stack found on instance: ' + instanceId
      );
    }

    List<String> stack = (List<String>) JSON.deserialize(
      target.Compensation_Stack__c,
      List<String>.class
    );
    if (stack.isEmpty()) {
      throw new WorkflowEngine.WorkflowException(
        'Compensation stack is empty for instance: ' + instanceId
      );
    }
    return target;
  }

  /**
   * Builds the successor compensating instance, carrying the root correlation key
   * and causation lineage forward from the completed target.
   * @param target the completed instance being compensated
   * @return the unsaved compensating instance
   */
  private static Workflow_Instance__c buildCompensatingInstance(
    Workflow_Instance__c target
  ) {
    return new Workflow_Instance__c(
      Workflow_Name__c = target.Workflow_Name__c,
      Correlation_Key__c = target.Correlation_Key__c,
      Root_Correlation_Key__c = String.isNotBlank(
          target.Root_Correlation_Key__c
        )
        ? target.Root_Correlation_Key__c
        : target.Correlation_Key__c,
      Previous_Instance__c = target.Id,
      Definition_Version__c = target.Definition_Version__c,
      Status__c = 'Compensating',
      Compensation_Stack__c = target.Compensation_Stack__c,
      Input__c = target.Input__c,
      Causation_Id__c = String.isNotBlank(target.Causation_Id__c)
        ? target.Causation_Id__c
        : target.Parent_Instance__c
    );
  }

  /**
   * Schedules the watchdog and enqueues the orchestrator for a compensating
   * instance, dispatching directly under test and via event otherwise.
   * @param compensatingInstanceId the compensating instance to drive
   */
  private static void enqueueCompensatingOrchestrator(
    Id compensatingInstanceId
  ) {
    WorkflowTimeoutArming.scheduleTimeoutJobForInstance(compensatingInstanceId);
    if (!Test.isRunningTest()) {
      WorkflowOrchestratorEnqueue.enqueueOrchestrator(
        compensatingInstanceId,
        null
      );
      return;
    }
    if (!WorkflowEngine.disableQueueableInTest) {
      System.enqueueJob(new WorkflowOrchestrator(compensatingInstanceId));
    }
  }
}
