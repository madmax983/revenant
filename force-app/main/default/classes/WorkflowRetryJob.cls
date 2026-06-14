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
      System.enqueueJob(
        String.isNotBlank(this.stepName)
          ? new WorkflowOrchestrator(this.instanceId, this.stepName)
          : new WorkflowOrchestrator(this.instanceId)
      );
    } else {
      WorkflowEngine.enqueueOrchestrator(this.instanceId, this.stepName);
    }

    // Schedule watchdog for the step we just enqueued
    WorkflowEngine.scheduleTimeoutJobForInstance(this.instanceId);

    // Clean up this scheduled execution from the schedule queue
    System.abortJob(ctx.getTriggerId());
  }
}
