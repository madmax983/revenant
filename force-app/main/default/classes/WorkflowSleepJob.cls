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
    // Clear expired sleep markers before enqueueing to prevent immediate watchdog double-wakes
    clearSleepMarkers(this.instanceId);

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

  private static void clearSleepMarkers(Id instanceId) {
    List<Workflow_Instance__c> insts = [
      SELECT Status__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
      WITH SYSTEM_MODE
      FOR UPDATE
    ];
    if (insts.isEmpty()) {
      return;
    }
    Workflow_Instance__c inst = insts[0];
    Workflow_Instance__c toUpdate = new Workflow_Instance__c(
      Id = instanceId,
      Sleep_Until__c = null,
      Async_Job_Id__c = null
    );
    if (inst.Status__c == 'Suspended') {
      toUpdate.Status__c = 'Running';
    }
    update as system toUpdate;
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
      // Clear expired sleep markers before enqueueing to prevent immediate watchdog double-wakes
      clearSleepMarkers(this.instanceId);

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
