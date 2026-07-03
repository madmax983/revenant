public inherited sharing class WorkflowSleepJob implements Schedulable {
  private Id instanceId;
  private String stepName;

  public WorkflowSleepJob(Id instanceId) {
    this(instanceId, null);
  }

  public WorkflowSleepJob(Id instanceId, String stepName) {
    if (instanceId == null) {
      throw new WorkflowEngine.WorkflowException('instanceId is required.');
    }
    this.instanceId = instanceId;
    this.stepName = stepName;
  }

  public void execute(SchedulableContext ctx) {
    // If the sleep has already been resumed by fireSleep or the watchdog, this scheduled job is stale and must no-op.
    if (!checkAndClearSleepMarkers(this.instanceId, this.stepName)) {
      if (ctx != null && ctx.getTriggerId() != null) {
        System.abortJob(ctx.getTriggerId());
      }
      return;
    }

    // Enqueue the next step execution
    if (Test.isRunningTest()) {
      if (!WorkflowEngine.disableQueueableInTest) {
        System.enqueueJob(new WorkflowOrchestrator(this.instanceId, this.stepName));
      }
    } else {
      WorkflowEngine.enqueueOrchestrator(this.instanceId, this.stepName);
    }

    // Schedule watchdog for the step we just resumed
    WorkflowEngine.scheduleTimeoutJobForInstance(this.instanceId);

    // Clean up this scheduled execution from the schedule queue
    if (ctx != null && ctx.getTriggerId() != null) {
      System.abortJob(ctx.getTriggerId());
    }
  }

  private static Boolean checkAndClearSleepMarkers(Id instanceId, String stepName) {
    List<Workflow_Instance__c> insts = [
      SELECT Status__c, Sleep_Until__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
      WITH SYSTEM_MODE
      FOR UPDATE
    ];
    if (insts.isEmpty()) {
      return false;
    }
    if (Test.isRunningTest() && WorkflowEngine.disableQueueableInTest) {
      return false;
    }
    Workflow_Instance__c inst = insts[0];
    if (inst.Status__c != 'Suspended' || inst.Sleep_Until__c == null) {
      return false;
    }
    if (String.isNotBlank(stepName)) {
      List<Workflow_Step_Execution__c> steps = [
        SELECT Id
        FROM Workflow_Step_Execution__c
        WHERE Workflow_Instance__c = :instanceId
          AND Step_Name__c = :stepName
          AND Status__c = 'Pending'
        WITH SYSTEM_MODE
        LIMIT 1
      ];
      if (steps.isEmpty()) {
        return false;
      }
    }

    Workflow_Instance__c toUpdate = new Workflow_Instance__c(
      Id = instanceId,
      Sleep_Until__c = null,
      Async_Job_Id__c = null
    );
    update as system toUpdate;
    return true;
  }

  public inherited sharing class QueueableSleepJob implements Queueable {
    private Id instanceId;
    private String stepName;

    public QueueableSleepJob(Id instanceId) {
      this(instanceId, null);
    }

    public QueueableSleepJob(Id instanceId, String stepName) {
      this.instanceId = instanceId;
      this.stepName = stepName;
    }

    public void execute(QueueableContext ctx) {
      // If the sleep has already been resumed by fireSleep or the watchdog, this queueable job is stale and must no-op.
      if (!checkAndClearSleepMarkers(this.instanceId, this.stepName)) {
        return;
      }

      if (Test.isRunningTest()) {
        if (!WorkflowEngine.disableQueueableInTest) {
          System.enqueueJob(new WorkflowOrchestrator(this.instanceId, this.stepName));
        }
      } else {
        WorkflowEngine.enqueueOrchestrator(this.instanceId, this.stepName);
      }

      // Schedule watchdog for the step we just resumed
      WorkflowEngine.scheduleTimeoutJobForInstance(this.instanceId);
    }
  }
}
