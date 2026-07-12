/**
 * @description Transactional finalizer attached to a workflow step's Queueable so
 * that an unhandled exception (including uncatchable limit failures) is durably
 * recorded as a crash against the owning instance, allowing the engine to recover
 * or route the failure rather than losing the step silently.
 */
public inherited sharing class WorkflowFinalizer implements System.Finalizer {
  private Id instanceId;
  private String stepName;

  /**
   * @description Constructs a finalizer bound to a workflow instance with no
   * specific step attributed to the crash.
   * @param instanceId The Id of the workflow instance whose job this finalizes.
   */
  public WorkflowFinalizer(Id instanceId) {
    this.instanceId = instanceId;
  }

  /**
   * @description Constructs a finalizer bound to a workflow instance and the step
   * currently executing, so a crash is attributed to that step.
   * @param instanceId The Id of the workflow instance whose job this finalizes.
   * @param stepName The name of the step executing when the job ran.
   */
  public WorkflowFinalizer(Id instanceId, String stepName) {
    this.instanceId = instanceId;
    this.stepName = stepName;
  }

  /**
   * @description Invoked after the parent Queueable completes; on an unhandled
   * exception it forwards the failure to WorkflowEngine.handleCrash so the step
   * is durably marked crashed and recovery can proceed.
   * @param ctx The finalizer context exposing the parent job's result and
   * exception.
   */
  public void execute(System.FinalizerContext ctx) {
    if (ctx.getResult() == ParentJobResult.UNHANDLED_EXCEPTION) {
      Exception ex = ctx.getException();
      WorkflowEngine.handleCrash(this.instanceId, this.stepName, ex);
    }
  }
}
