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
