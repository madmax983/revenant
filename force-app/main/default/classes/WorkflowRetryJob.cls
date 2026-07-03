public inherited sharing class WorkflowRetryJob implements Schedulable {
  private Id instanceId;
  private String stepName;

  public WorkflowRetryJob(Id instanceId, String stepName) {
    if (instanceId == null) {
      throw new WorkflowEngine.WorkflowException('instanceId is required.');
    }
    this.instanceId = instanceId;
    this.stepName = stepName;
  }

  public void execute(SchedulableContext ctx) {
    if (Test.isRunningTest()) {
      if (!WorkflowEngine.disableQueueableInTest) {
        System.enqueueJob(
          String.isNotBlank(this.stepName)
            ? new WorkflowOrchestrator(this.instanceId, this.stepName)
            : new WorkflowOrchestrator(this.instanceId)
        );
      }
    } else {
      WorkflowEngine.enqueueOrchestrator(this.instanceId, this.stepName);
    }

    // Schedule watchdog for the step we just enqueued
    WorkflowEngine.scheduleTimeoutJobForInstance(this.instanceId);

    // Clean up this scheduled execution from the schedule queue
    if (ctx != null && ctx.getTriggerId() != null) {
      System.abortJob(ctx.getTriggerId());
    }
  }

  public inherited sharing class QueueableRetryJob implements Queueable {
    private Id instanceId;
    private String stepName;

    public QueueableRetryJob(Id instanceId, String stepName) {
      this.instanceId = instanceId;
      this.stepName = stepName;
    }

    public void execute(QueueableContext ctx) {
      if (Test.isRunningTest()) {
        if (!WorkflowEngine.disableQueueableInTest) {
          System.enqueueJob(
            String.isNotBlank(this.stepName)
              ? new WorkflowOrchestrator(this.instanceId, this.stepName)
              : new WorkflowOrchestrator(this.instanceId)
          );
        }
      } else {
        WorkflowEngine.enqueueOrchestrator(this.instanceId, this.stepName);
      }

      // Schedule watchdog for the step we just enqueued
      WorkflowEngine.scheduleTimeoutJobForInstance(this.instanceId);
    }
  }
}
