public inherited sharing class WorkflowWatchdog implements Schedulable {
  public void execute(SchedulableContext ctx) {
    if (!Test.isRunningTest()) {
      System.enqueueJob(new QueueableWatchdog());
    } else {
      // Execute synchronously in test context to simplify testing
      WorkflowEngine.processWatchdogHeartbeat();
    }
  }

  public class QueueableWatchdog implements Queueable {
    public void execute(QueueableContext ctx) {
      WorkflowEngine.processWatchdogHeartbeat();
    }
  }
}
