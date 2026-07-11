public inherited sharing class WorkflowTimeoutJob implements Schedulable {
  private Id instanceId;
  private String stepName;

  public WorkflowTimeoutJob(Id instanceId, String stepName) {
    this.instanceId = instanceId;
    this.stepName = stepName;
  }

  public void execute(SchedulableContext ctx) {
    try {
      executeInternal();
    } finally {
      // Clean up this scheduled execution
      if (ctx != null) {
        System.abortJob(ctx.getTriggerId());
      }
    }
  }

  public void executeInternal() {
    // Parent-first locking: query and lock the parent instance first
    Workflow_Instance__c instance = lockInstance();
    if (instance == null) {
      return;
    }

    if (!isEnforceableStatus(instance.Status__c)) {
      return;
    }

    if (shouldHoldForPause(instance)) {
      return;
    }

    // A Running/Pending step execution was found and enforced (or intentionally
    // skipped) — the pre-start check below only applies when no such record exists.
    if (enforceActiveStep(instance)) {
      return;
    }

    // Check if the workflow instance is still active and waiting on this step
    // (pre-start check)
    if (isExpectedStep(instance)) {
      WorkflowEngine.failWorkflowInstance(
        this.instanceId,
        this.stepName,
        'Step execution timed out before starting.',
        WorkflowEngine.CAT_TIMEOUT
      );
    }
  }

  private Workflow_Instance__c lockInstance() {
    List<Workflow_Instance__c> instances = [
      SELECT
        Status__c,
        Current_Step__c,
        Compensation_Stack__c,
        Workflow_Name__c,
        Concurrency_Slot_Held__c,
        Concurrency_Parked__c
      FROM Workflow_Instance__c
      WHERE Id = :this.instanceId
      WITH SYSTEM_MODE
      FOR UPDATE
    ];
    return instances.isEmpty() ? null : instances[0];
  }

  private Boolean isEnforceableStatus(String status) {
    return status == 'Pending' ||
      status == 'Running' ||
      status == 'Compensating' ||
      status == 'Cancelling';
  }

  /**
   * Operator pause gate: if the definition is paused, this instance is parked (or about
   * to be, once its pending RUN_STEP reaches the gate). A timeout job armed by the
   * pre-pause handoff must NOT fail the step during that window — the step is held and
   * re-armed on resume via reArmTimeoutsForResume. Compensating/Cancelling bypass the
   * pause gate elsewhere, so let those time out normally rather than stalling an
   * in-progress rollback.
   *
   * Returns true when the timeout must be held (caller returns without enforcing).
   */
  private Boolean shouldHoldForPause(Workflow_Instance__c instance) {
    Boolean pauseCandidate = (instance.Status__c == 'Pending' ||
    instance.Status__c == 'Running');
    if (
      !pauseCandidate ||
      !WorkflowPauseGate.anyPaused() ||
      !WorkflowPauseGate.isDefinitionPaused(instance.Workflow_Name__c)
    ) {
      return false;
    }

    // Only hold pre-start (Pending) steps: a Running step that is stuck in a dead
    // queueable stays Running (not parked), so reArmTimeoutsForResume will not re-arm it
    // on resume. Clearing its deadline here would leave the stuck step permanently
    // unenforceable. Pending steps are cleared so a post-resume heartbeat cannot fire
    // instantly; the deadline re-attaches when the step parks (reArmTimeoutsForResume)
    // or re-runs.
    List<Workflow_Step_Execution__c> pausedStep = queryPausedStep();
    if (!pausedStep.isEmpty() && pausedStep[0].Status__c == 'Pending') {
      pausedStep[0].Timeout_At__c = null;
      update as system pausedStep[0];
      return true;
    }
    if (pausedStep.isEmpty()) {
      return true; // no active step with a deadline — hold without clearing
    }
    // Step is Running (stuck) — fall through to enforce the timeout normally
    return false;
  }

  private List<Workflow_Step_Execution__c> queryPausedStep() {
    return [
      SELECT Id, Status__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :this.instanceId
        AND Step_Name__c = :this.stepName
        AND Status__c IN ('Running', 'Pending')
        AND Timeout_At__c != NULL
      WITH SYSTEM_MODE
      FOR UPDATE
    ];
  }

  /**
   * Enforces the timeout against the latest Running/Pending step execution.
   * Returns true when such a record exists (handled — including intentional skips),
   * so the caller does not fall through to the pre-start check. Returns false only when
   * no Running/Pending step execution exists.
   */
  private Boolean enforceActiveStep(Workflow_Instance__c instance) {
    List<Workflow_Step_Execution__c> stepExecs = [
      SELECT Status__c, Error_Details__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :this.instanceId
        AND Step_Name__c = :this.stepName
        AND Status__c IN ('Running', 'Pending')
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC, Id DESC
      LIMIT 1
    ];

    if (stepExecs.isEmpty()) {
      return false;
    }

    Workflow_Step_Execution__c stepExec = [
      SELECT Status__c, Error_Details__c, Timeout_At__c
      FROM Workflow_Step_Execution__c
      WHERE Id = :stepExecs[0].Id
      WITH SYSTEM_MODE
      FOR UPDATE
    ];

    // Re-validate status after lock
    if (stepExec.Status__c != 'Running' && stepExec.Status__c != 'Pending') {
      return true;
    }
    if (shouldSkipForFreshDeadline(stepExec, instance)) {
      return true;
    }

    String errorMsg = (stepExec.Status__c == 'Running')
      ? 'Step execution timed out.'
      : 'Step execution timed out before starting.';

    stepExec.Status__c = 'Failed';
    stepExec.Error_Details__c = errorMsg;
    update as system stepExec;

    WorkflowEngine.failWorkflowInstance(
      this.instanceId,
      this.stepName,
      errorMsg,
      WorkflowEngine.CAT_TIMEOUT
    );
    return true;
  }

  /**
   * Stale-job guard: a pause/resume cycle re-arms the step with a fresh future deadline
   * and schedules a new job; a delayed QueueableTimeoutJob from before the re-arm may
   * fire early. Skip it — the re-armed job enforces the new (correct) deadline.
   *
   * A NULL deadline on a concurrency-PARKED instance means its timeout was deferred until
   * an admission slot is won: a stray job must not fail a step that is only waiting for
   * capacity; admission re-arms a real deadline. Keyed off the DURABLE
   * Concurrency_Parked__c marker (set when a bounded start/child defers its timeout, and
   * again when parkForConcurrency suspends a denied admission) rather than the CURRENT
   * CMDT (isConfigured). A ceiling added AFTER an unbounded child/successor scheduled its
   * pre-start watchdog would otherwise retroactively reclassify that watchdog as a
   * deferred admission and leave the overdue step Pending forever. Because the marker is
   * stamped at scheduling time and cleared only on admission, the null-deadline jobs
   * reaching here split cleanly: parked rows (parked=true, skip) vs. genuine pre-start
   * watchdogs (parked=false, fail "before starting").
   */
  private Boolean shouldSkipForFreshDeadline(
    Workflow_Step_Execution__c stepExec,
    Workflow_Instance__c instance
  ) {
    if (stepExec.Timeout_At__c != null) {
      return stepExec.Timeout_At__c > DateTime.now();
    }
    return instance.Concurrency_Parked__c == true;
  }

  private Boolean isExpectedStep(Workflow_Instance__c instance) {
    if (
      instance.Status__c == 'Compensating' ||
      instance.Status__c == 'Cancelling'
    ) {
      return isExpectedCompensationStep(instance);
    }
    return isExpectedForwardStep(instance);
  }

  private Boolean isExpectedCompensationStep(Workflow_Instance__c instance) {
    if (String.isBlank(instance.Compensation_Stack__c)) {
      return false;
    }
    List<String> stack = (List<String>) JSON.deserialize(
      instance.Compensation_Stack__c,
      List<String>.class
    );
    return !stack.isEmpty() &&
      (stack[stack.size() - 1] + '_Compensate') == this.stepName;
  }

  private Boolean isExpectedForwardStep(Workflow_Instance__c instance) {
    if (instance.Current_Step__c == this.stepName) {
      return true;
    }
    if (
      String.isBlank(instance.Current_Step__c) ||
      !instance.Current_Step__c.contains(',')
    ) {
      return false;
    }
    for (String pStep : instance.Current_Step__c.split(',')) {
      if (pStep.trim() == this.stepName) {
        return true;
      }
    }
    return false;
  }

  public class QueueableTimeoutJob implements Queueable {
    private Id instanceId;
    private String stepName;

    public QueueableTimeoutJob(Id instanceId, String stepName) {
      this.instanceId = instanceId;
      this.stepName = stepName;
    }

    public void execute(QueueableContext ctx) {
      // Surface an unhandled failure of the timeout enforcement to the log sink rather
      // than letting it vanish. The finalizer runs even if execute() throws.
      System.attachFinalizer(
        new TimeoutJobFinalizer(this.instanceId, this.stepName)
      );
      new WorkflowTimeoutJob(this.instanceId, this.stepName).executeInternal();
    }
  }

  // Best-effort failure sink for the timeout queueable. On an unhandled exception the
  // step deadline would otherwise go unenforced and the failure unrecorded; this logs it.
  // The success path is untouched (it only acts on UNHANDLED_EXCEPTION).
  public class TimeoutJobFinalizer implements Finalizer {
    private final Id instanceId;
    private final String stepName;

    public TimeoutJobFinalizer(Id instanceId, String stepName) {
      this.instanceId = instanceId;
      this.stepName = stepName;
    }

    public void execute(FinalizerContext ctx) {
      if (
        ctx == null ||
        ctx.getResult() != ParentJobResult.UNHANDLED_EXCEPTION
      ) {
        return;
      }
      Exception ex = ctx.getException();
      String detail = (ex == null) ? 'unknown error' : ex.getMessage();
      // WorkflowLog.error swallows its own DML failures, so this stays best-effort.
      WorkflowLog.error(
        'WorkflowTimeoutJob.QueueableTimeoutJob',
        'Timeout enforcement failed for step "' + stepName + '": ' + detail,
        instanceId
      );
    }
  }
}
