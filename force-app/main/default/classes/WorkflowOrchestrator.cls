public inherited sharing class WorkflowOrchestrator implements Queueable, Database.AllowsCallouts {
  private Id instanceId;
  private String stepName;

  public WorkflowOrchestrator(Id instanceId) {
    this.instanceId = instanceId;
  }

  public WorkflowOrchestrator(Id instanceId, String stepName) {
    this.instanceId = instanceId;
    this.stepName = stepName;
  }

  public void execute(QueueableContext ctx) {
    // Attach transaction finalizer to rescue workflow on crash/limits
    if (ctx != null) {
      System.attachFinalizer(
        new WorkflowFinalizer(this.instanceId, this.stepName)
      );
    }

    // Execute step
    WorkflowEngine.runStep(this.instanceId, this.stepName);
  }
}
