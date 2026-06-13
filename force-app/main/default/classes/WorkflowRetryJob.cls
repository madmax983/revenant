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
    // Enqueue the next step execution
    if (String.isNotBlank(this.stepName)) {
      if (Test.isRunningTest()) {
        System.enqueueJob(
          new WorkflowOrchestrator(this.instanceId, this.stepName)
        );
      } else {
        WorkflowEngine.enqueueOrchestrator(this.instanceId, this.stepName);
      }
    } else {
      if (Test.isRunningTest()) {
        System.enqueueJob(new WorkflowOrchestrator(this.instanceId));
      } else {
        WorkflowEngine.enqueueOrchestrator(this.instanceId, null);
      }
    }

    // Schedule watchdog for the step we just enqueued
    WorkflowEngine.scheduleTimeoutJobForInstance(this.instanceId);

    // Clean up this scheduled execution from the schedule queue
    System.abortJob(ctx.getTriggerId());
  }
}
