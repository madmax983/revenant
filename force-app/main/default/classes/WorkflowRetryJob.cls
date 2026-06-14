public inherited sharing class WorkflowRetryJob implements Schedulable {
  private Id instanceId;
  private String stepName;

  public WorkflowRetryJob(Id instanceId) {
    this.instanceId = instanceId;
  }

  public WorkflowRetryJob(Id instanceId, String stepName) {
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
    System.abortJob(ctx.getTriggerId());
  }

  public class QueueableRetryJob implements Queueable {
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
