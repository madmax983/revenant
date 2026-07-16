/**
 * @description Crash-recovery surface for the Revenant engine. Rescues a workflow
 * whose host transaction failed or hit a governor limit by writing the crashed
 * step's outcome in its own DML transaction, and re-drives the step on a transient
 * row-lock error (within the transient-retry budget) instead of failing the whole
 * workflow. Extracted from `WorkflowEngine`; the public `handleCrash` entry points
 * stay resident on the engine and delegate to `processCrash` here. The resident
 * `WorkflowEngine.FailInstanceRequest` DTO, the `WorkflowEngine.CAT_*` failure
 * categories, `WorkflowEngine.failWorkflowInstance` and `WorkflowStepExecStore.saveStepExecAsCrash`
 * are referenced fully qualified. Transient row-lock retry classification and
 * re-drive is delegated to `WorkflowTransientLockRetry`. All SOQL/DML executes in
 * system mode.
 */
public inherited sharing class WorkflowCrashHandler {
  /**
   * @description Rescues a crashed or governor-limited step in its own DML
   * transaction so the outcome is durable even when the parent transaction rolled
   * back. Re-drives the step on a transient row-lock error (within the retry
   * budget); otherwise fails the workflow with the crash details.
   * @param instanceId Id of the instance to rescue
   * @param stepName name of the step that crashed, or null when unknown
   * @param ex the exception that caused the crash
   */
  public static void processCrash(
    Id instanceId,
    String stepName,
    Exception ex
  ) {
    // Run as separate DML transaction to ensure it's written even if parent rolled back
    List<Workflow_Instance__c> instances = [
      SELECT Id, Status__c, Current_Step__c, Compensation_Stack__c, Input__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
      WITH SYSTEM_MODE
      LIMIT 1
      FOR UPDATE
    ];

    if (instances.isEmpty()) {
      return;
    }

    Workflow_Instance__c instance = instances[0];

    Boolean midRollback = isMidRollback(instance);
    String targetStepName = resolveCrashStepName(
      instance,
      stepName,
      midRollback
    );

    // Transient row-lock contention (UNABLE_TO_LOCK_ROW) is retryable, not a crash:
    // it arises when many transactions touch the same row at once — e.g. a fan-in
    // where every child-completion signal locks the shared parent row — and clears on
    // its own once the competing transactions commit. Re-drive the step after a short
    // backoff instead of failing/compensating the whole workflow. Bounded by the
    // step's consecutive Transient_Retry_Count__c so a genuinely stuck row still fails.
    if (
      WorkflowTransientLockRetry.isTransientLockError(ex) &&
      String.isNotBlank(targetStepName) &&
      WorkflowTransientLockRetry.scheduleTransientLockRetry(
        instance,
        targetStepName
      )
    ) {
      return;
    }

    recordCrashedStep(instance, targetStepName, ex);

    // Use fail helper
    String errorMsg =
      'Transaction crashed: ' +
      (ex != null ? ex.getMessage() : 'Unknown governor limit');
    WorkflowEngine.FailInstanceRequest stepExceptionReq = new WorkflowEngine.FailInstanceRequest();
    stepExceptionReq.instanceId = instanceId;
    stepExceptionReq.stepName = targetStepName;
    stepExceptionReq.errorMessage = errorMsg;
    stepExceptionReq.failureCategory = WorkflowEngine.CAT_STEP_EXCEPTION;
    WorkflowEngine.failWorkflowInstance(stepExceptionReq);
  }

  // The instance is mid-rollback when its status is Compensating/Cancelling, OR
  // when it is Suspended and its most recent step execution is a '_Compensate'
  // attempt (a sleeping/approval-gated compensation whose in-transaction status
  // flip was rolled back by the crash). Detected the same way runStep() does so
  // the crash is recorded against the '_Compensate' step, not the stale forward
  // step.
  private static Boolean isMidRollback(Workflow_Instance__c instance) {
    Boolean midRollback =
      instance.Status__c == 'Compensating' ||
      instance.Status__c == 'Cancelling';
    if (!midRollback && instance.Status__c == 'Suspended') {
      List<Workflow_Step_Execution__c> latestSteps = [
        SELECT Step_Name__c
        FROM Workflow_Step_Execution__c
        WHERE Workflow_Instance__c = :instance.Id
        WITH SYSTEM_MODE
        ORDER BY CreatedDate DESC, Id DESC
        LIMIT 1
      ];
      midRollback =
        !latestSteps.isEmpty() &&
        latestSteps[0].Step_Name__c != null &&
        latestSteps[0].Step_Name__c.endsWith('_Compensate');
    }
    return midRollback;
  }

  // Resolve the step the crash is recorded against. An explicit stepName always
  // wins; otherwise a mid-rollback crash targets the top-of-stack '_Compensate'
  // step, and a forward crash targets the stale Current_Step__c.
  private static String resolveCrashStepName(
    Workflow_Instance__c instance,
    String stepName,
    Boolean midRollback
  ) {
    if (String.isNotBlank(stepName)) {
      return stepName;
    }
    if (midRollback && String.isNotBlank(instance.Compensation_Stack__c)) {
      List<String> stack = (List<String>) JSON.deserialize(
        instance.Compensation_Stack__c,
        List<String>.class
      );
      return stack.isEmpty()
        ? instance.Current_Step__c
        : stack[stack.size() - 1] + '_Compensate';
    }
    return instance.Current_Step__c;
  }

  private static String crashErrorDetails(Exception ex) {
    return ex != null
      ? ex.getMessage() + '\n' + ex.getStackTraceString()
      : 'Unknown governor limit / crash';
  }

  // Mark the crashing step's execution log Failed (updating the latest log if it
  // exists, otherwise inserting a fresh Failed log seeded with the right undo
  // context).
  private static void recordCrashedStep(
    Workflow_Instance__c instance,
    String targetStepName,
    Exception ex
  ) {
    if (String.isBlank(targetStepName)) {
      return;
    }
    List<Workflow_Step_Execution__c> stepExecs = [
      SELECT Id
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :instance.Id
        AND Step_Name__c = :targetStepName
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC, Id DESC
      LIMIT 1
    ];
    if (!stepExecs.isEmpty()) {
      Workflow_Step_Execution__c stepExec = stepExecs[0];
      stepExec.Status__c = 'Failed';
      stepExec.Error_Details__c = crashErrorDetails(ex);
      WorkflowStepExecStore.saveStepExecAsCrash(stepExec);
      return;
    }
    // Construct and insert the step execution log with failed status
    Workflow_Step_Execution__c stepExec = buildCrashedStepExec(
      instance,
      targetStepName,
      ex
    );
    WorkflowStepExecStore.saveStepExecAsCrash(stepExec);
  }

  private static Workflow_Step_Execution__c buildCrashedStepExec(
    Workflow_Instance__c instance,
    String targetStepName,
    Exception ex
  ) {
    Workflow_Step_Execution__c stepExec = new Workflow_Step_Execution__c();
    stepExec.Workflow_Instance__c = instance.Id;
    stepExec.Step_Name__c = targetStepName;
    stepExec.Status__c = 'Failed';
    stepExec.Error_Details__c = crashErrorDetails(ex);

    if (targetStepName.endsWith('_Compensate')) {
      seedCompensationCrashInput(stepExec, instance.Id, targetStepName);
    } else {
      seedForwardCrashInput(stepExec, instance);
    }
    return stepExec;
  }

  // Crash row for a compensation step: seed from THIS step's own forward
  // execution (input/output), matching how compensation logs are seeded
  // everywhere else. Using the latest completed step overall would be wrong once
  // earlier compensations have popped — that row belongs to an already-reversed
  // step, giving the wrong undo context on resume.
  private static void seedCompensationCrashInput(
    Workflow_Step_Execution__c stepExec,
    Id instanceId,
    String targetStepName
  ) {
    String forwardStepName = targetStepName.removeEnd('_Compensate');
    List<Workflow_Step_Execution__c> forwardExecs = [
      SELECT Input__c, Output__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :instanceId
        AND Step_Name__c = :forwardStepName
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC, Id DESC
      LIMIT 1
    ];
    if (!forwardExecs.isEmpty()) {
      stepExec.Input__c = forwardExecs[0].Input__c;
      stepExec.Output__c = forwardExecs[0].Output__c;
    }
  }

  // Forward step crash: feed the previous step's output as input.
  private static void seedForwardCrashInput(
    Workflow_Step_Execution__c stepExec,
    Workflow_Instance__c instance
  ) {
    List<Workflow_Step_Execution__c> completedSteps = [
      SELECT Output__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :instance.Id
        AND Status__c IN ('Completed', 'OperatorSkipped')
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC, Id DESC
      LIMIT 1
    ];
    stepExec.Input__c = !completedSteps.isEmpty()
      ? completedSteps[0].Output__c
      : instance.Input__c;
  }
}
