public inherited sharing class WorkflowSleepJob implements Schedulable {
  private Id instanceId;

  public WorkflowSleepJob(Id instanceId) {
    this.instanceId = instanceId;
  }

  public void execute(SchedulableContext ctx) {
    // Enqueue the next step execution
    if (Test.isRunningTest()) {
      if (!WorkflowEngine.disableQueueableInTest) {
        System.enqueueJob(new WorkflowOrchestrator(this.instanceId));
      }
    } else {
      WorkflowEngine.enqueueOrchestrator(this.instanceId, null);
    }

    // Schedule watchdog for the step we just resumed
    WorkflowEngine.scheduleTimeoutJobForInstance(this.instanceId);

    // Clean up this scheduled execution from the schedule queue
    System.abortJob(ctx.getTriggerId());
  }

  public class QueueableSleepJob implements Queueable {
    private Id instanceId;

    public QueueableSleepJob(Id instanceId) {
      this.instanceId = instanceId;
    }

    public void execute(QueueableContext ctx) {
      if (Test.isRunningTest()) {
        if (!WorkflowEngine.disableQueueableInTest) {
          System.enqueueJob(new WorkflowOrchestrator(this.instanceId));
        }
      } else {
        WorkflowEngine.enqueueOrchestrator(this.instanceId, null);
      }

      // Schedule watchdog for the step we just resumed
      WorkflowEngine.scheduleTimeoutJobForInstance(this.instanceId);
    }
  }
}
