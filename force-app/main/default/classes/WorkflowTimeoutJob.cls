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
    List<Workflow_Instance__c> instances = [
      SELECT Status__c, Current_Step__c, Compensation_Stack__c, Workflow_Name__c
      FROM Workflow_Instance__c
      WHERE Id = :this.instanceId
      WITH SYSTEM_MODE
      FOR UPDATE
    ];

    if (instances.isEmpty()) {
      return;
    }

    Workflow_Instance__c instance = instances[0];
    if (
      instance.Status__c != 'Pending' &&
      instance.Status__c != 'Running' &&
      instance.Status__c != 'Compensating' &&
      instance.Status__c != 'Cancelling'
    ) {
      return;
    }

    // Operator pause gate: if the definition is paused, this instance is parked
    // (or about to be, once its pending RUN_STEP reaches the gate). A timeout job
    // armed by the pre-pause handoff must NOT fail the step during that window —
    // the step is held and re-armed on resume via reArmTimeoutsForResume.
    // Compensating/Cancelling bypass the pause gate elsewhere, so let those time
    // out normally rather than stalling an in-progress rollback.
    if (
      (instance.Status__c == 'Pending' || instance.Status__c == 'Running') &&
      WorkflowPauseGate.anyPaused() &&
      WorkflowPauseGate.isDefinitionPaused(instance.Workflow_Name__c)
    ) {
      // Only hold pre-start (Pending) steps: a Running step that is stuck in a
      // dead queueable stays Running (not parked), so reArmTimeoutsForResume
      // will not re-arm it on resume. Clearing its deadline here would leave
      // the stuck step permanently unenforceable. Pending steps are cleared so
      // a post-resume heartbeat cannot fire instantly; the deadline re-attaches
      // when the step parks (reArmTimeoutsForResume) or re-runs.
      List<Workflow_Step_Execution__c> pausedStep = [
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
      if (!pausedStep.isEmpty() && pausedStep[0].Status__c == 'Pending') {
        pausedStep[0].Timeout_At__c = null;
        update as system pausedStep[0];
        return;
      }
      if (pausedStep.isEmpty()) {
        return; // no active step with a deadline — hold without clearing
      }
      // Step is Running (stuck) — fall through to enforce the timeout normally
    }

    // Query the step execution record with FOR UPDATE
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

    if (!stepExecs.isEmpty()) {
      Workflow_Step_Execution__c stepExec = [
        SELECT Status__c, Error_Details__c, Timeout_At__c
        FROM Workflow_Step_Execution__c
        WHERE Id = :stepExecs[0].Id
        WITH SYSTEM_MODE
        FOR UPDATE
      ];

      // Re-validate status after lock
      if (stepExec.Status__c != 'Running' && stepExec.Status__c != 'Pending') {
        return;
      }
      // Stale-job guard: a pause/resume cycle re-arms the step with a fresh
      // future deadline and schedules a new job; a delayed QueueableTimeoutJob
      // from before the re-arm may fire early. Skip it — the re-armed job
      // enforces the new (correct) deadline. A NULL deadline likewise means no
      // timeout is currently armed: it was deferred (a concurrency-bounded start
      // awaiting an admission slot) or cleared (parked/paused), so a stray job must
      // not fail an unarmed step "before starting". The watchdog sweep already
      // excludes null deadlines (Timeout_At__c <= now); mirror that here.
      if (
        stepExec.Timeout_At__c == null ||
        stepExec.Timeout_At__c > DateTime.now()
      ) {
        return;
      }

      String errorMsg;
      if (stepExec.Status__c == 'Running') {
        errorMsg = 'Step execution timed out.';
      } else {
        errorMsg = 'Step execution timed out before starting.';
      }

      stepExec.Status__c = 'Failed';
      stepExec.Error_Details__c = errorMsg;
      update as system stepExec;

      WorkflowEngine.failWorkflowInstance(
        this.instanceId,
        this.stepName,
        errorMsg
      );
      return;
    }

    // Check if the workflow instance is still active and waiting on this step (pre-start check)
    Boolean isExpectedStep = false;
    if (
      instance.Status__c == 'Compensating' ||
      instance.Status__c == 'Cancelling'
    ) {
      if (String.isNotBlank(instance.Compensation_Stack__c)) {
        List<String> stack = (List<String>) JSON.deserialize(
          instance.Compensation_Stack__c,
          List<String>.class
        );
        if (
          !stack.isEmpty() &&
          (stack[stack.size() - 1] + '_Compensate') == this.stepName
        ) {
          isExpectedStep = true;
        }
      }
    } else {
      if (instance.Current_Step__c == this.stepName) {
        isExpectedStep = true;
      } else if (
        String.isNotBlank(instance.Current_Step__c) &&
        instance.Current_Step__c.contains(',')
      ) {
        for (String pStep : instance.Current_Step__c.split(',')) {
          if (pStep.trim() == this.stepName) {
            isExpectedStep = true;
            break;
          }
        }
      }
    }

    if (isExpectedStep) {
      WorkflowEngine.failWorkflowInstance(
        this.instanceId,
        this.stepName,
        'Step execution timed out before starting.'
      );
    }
  }

  public class QueueableTimeoutJob implements Queueable {
    private Id instanceId;
    private String stepName;

    public QueueableTimeoutJob(Id instanceId, String stepName) {
      this.instanceId = instanceId;
      this.stepName = stepName;
    }

    public void execute(QueueableContext ctx) {
      new WorkflowTimeoutJob(this.instanceId, this.stepName).executeInternal();
    }
  }
}
