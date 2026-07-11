/**
 * @description A workflow definition that can reroute execution when a step fails,
 * mapping a failed step to a compensating or recovery step instead of aborting the
 * instance.
 */
public interface ErrorRoutingWorkflow extends WorkflowDefinition {
  /**
   * @description Determines which step to run in response to a failed step.
   * @param failedStepName The name of the step that failed.
   * @param error Details of the failure, including message and attempt count.
   * @return The name of the recovery/compensation step, or null to abort.
   */
  String getErrorStep(String failedStepName, StepError error);
}
