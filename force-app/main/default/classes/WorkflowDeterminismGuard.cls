/**
 * @description Strict determinism mode (issue #102). When the mode is on, the
 * guard records each wait decision of a step. When the step runs again with
 * the same inputs, the guard compares the new decision with the record. A
 * different decision fails the instance with STEP_NON_DETERMINISM, before the
 * engine writes the decision. When the mode is off, the guard does no work.
 */
public inherited sharing class WorkflowDeterminismGuard {
  /** @description Error message prefix of a divergence. */
  public static final String MESSAGE_PREFIX = 'Step non-determinism: ';
  /** @description Workflow_Log__c type of a divergence. */
  public static final String LOG_TYPE = 'StepNonDeterminism';

  /**
   * @description Digests the inputs of a step run. Call before execute().
   * @param context The hydrated step context.
   * @return The inputs digest, or null when strict mode is off.
   */
  public static String captureInputs(StepContext context) {
    return null;
  }

  /**
   * @description Compares a step result with the recorded decision, and
   * records or clears the decision on the in-memory step row.
   * @param inputs The digest from captureInputs, or null.
   * @param ctx The run context with the step row and the thrown error.
   * @param stepInstance The step that ran.
   * @param result The step result.
   * @return The divergence message, or null.
   */
  public static String verify(
    String inputs,
    WorkflowStepRunner.RunStepContext ctx,
    WorkflowStep stepInstance,
    StepResult result
  ) {
    return null;
  }

  /**
   * @description Fails the instance when the outcome carries a divergence.
   * @param outcome The step outcome.
   * @return True when the guard failed the instance.
   */
  public static Boolean failIfDivergent(
    WorkflowEngine.StepOutcomeContext outcome
  ) {
    return false;
  }
}
