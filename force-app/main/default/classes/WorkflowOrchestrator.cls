/**
 * @description Queueable that advances a workflow instance by running one step in an
 * async context, attaching a finalizer so crashes and limit failures are rescued.
 */
public inherited sharing class WorkflowOrchestrator implements Queueable, Database.AllowsCallouts {
  private Id instanceId;
  private String stepName;

  /**
   * @description Constructs an orchestrator that runs the instance's current step.
   * @param instanceId The Id of the workflow instance to advance.
   */
  public WorkflowOrchestrator(Id instanceId) {
    this.instanceId = instanceId;
  }

  /**
   * @description Constructs an orchestrator that runs a specific named step.
   * @param instanceId The Id of the workflow instance to advance.
   * @param stepName The name of the step to execute.
   */
  public WorkflowOrchestrator(Id instanceId, String stepName) {
    this.instanceId = instanceId;
    this.stepName = stepName;
  }

  /**
   * @description Attaches the rescue finalizer and runs the target step for the instance.
   * @param ctx The queueable execution context.
   */
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
