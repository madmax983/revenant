/**
 * @description Auto-retry of thrown step errors (issue #101). Finds the
 * `AutoRetryConfigurable` policy for a step and builds the texts for an
 * exhausted auto-retry. `WorkflowStepInvoke` catches the throw.
 * `WorkflowContinueAsNew.handleRetryOutcome` does the retry or the failure.
 */
public inherited sharing class WorkflowAutoRetry {
  private static final String EXHAUSTED_PREFIX = 'Auto-retry exhausted after ';

  /**
   * @description Returns the auto-retry policy for a step. The step policy
   * applies first (a null step policy means fail fast). Then the definition
   * policy applies.
   * @param instance The instance that runs the step.
   * @param step The step to run.
   * @return The policy, or null when there is no policy.
   */
  public static RetryPolicy resolvePolicy(
    Workflow_Instance__c instance,
    WorkflowStep step
  ) {
    if (step instanceof AutoRetryConfigurable) {
      return ((AutoRetryConfigurable) step).getAutoRetryPolicy();
    }
    Object definition = resolveDefinition(instance.Workflow_Name__c);
    if (definition instanceof AutoRetryConfigurable) {
      return ((AutoRetryConfigurable) definition).getAutoRetryPolicy();
    }
    return null;
  }

  /**
   * @description Returns the instance error text for an exhausted auto-retry.
   * @param attempts The number of attempts that failed.
   * @param ex The last thrown exception.
   * @return The error text.
   */
  public static String exhaustedMessage(Integer attempts, Exception ex) {
    return EXHAUSTED_PREFIX + attempts + ' attempts: ' + ex.getMessage();
  }

  /**
   * @description Returns the step error details for an exhausted auto-retry.
   * The details keep the original message and stack trace.
   * @param attempts The number of attempts that failed.
   * @param ex The last thrown exception.
   * @return The error details.
   */
  public static String exhaustedDetails(Integer attempts, Exception ex) {
    return exhaustedMessage(attempts, ex) + '\n' + ex.getStackTraceString();
  }

  // Returns the definition object, or null when the name does not resolve. A
  // resolve error means "no policy", so a workflow without a policy never fails
  // here.
  private static Object resolveDefinition(String workflowName) {
    try {
      Type definitionType = WorkflowTypeResolver.resolve(
        workflowName,
        WorkflowTypeResolver.extractNamespace(workflowName)
      );
      return definitionType == null ? null : definitionType.newInstance();
    } catch (Exception ignored) {
      return null;
    }
  }
}
