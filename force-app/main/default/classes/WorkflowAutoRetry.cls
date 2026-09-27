/**
 * @description Auto-retry of thrown step errors (issue #101). Finds the
 * `AutoRetryConfigurable` policy for a step, decides which thrown exceptions
 * use auto-retry, and builds the error text. `WorkflowStepInvoke` catches the
 * thrown exception. `WorkflowContinueAsNew.handleRetryOutcome` does the retry
 * or the failure.
 */
public inherited sharing class WorkflowAutoRetry {
  private static final String LOG_TYPE = 'AutoRetry';
  private static final String EXHAUSTED_PREFIX = 'Auto-retry exhausted after ';
  private static final String UNCOMMITTED_WORK = 'uncommitted work pending';
  /** @description Text for a callout that a savepoint blocked. */
  public static final String CALLOUT_CONFLICT = 'Auto-retry sets a savepoint before execute(). A step that makes a callout must implement CalloutStep. ';

  // Definition objects by workflow name, for this transaction only.
  private static Map<String, Object> definitionsByName = new Map<String, Object>();

  /**
   * @description Returns the auto-retry policy for a step. If the step
   * implements `AutoRetryConfigurable`, its policy applies, also when null. If
   * not, the definition policy applies. A getter that throws gives no policy.
   * @param instance The instance that runs the step.
   * @param step The step to run.
   * @return The policy, or null when there is no policy.
   */
  public static RetryPolicy resolvePolicy(
    Workflow_Instance__c instance,
    WorkflowStep step
  ) {
    try {
      if (step instanceof AutoRetryConfigurable) {
        return ((AutoRetryConfigurable) step).getAutoRetryPolicy();
      }
      Object definition = resolveDefinition(instance.Workflow_Name__c);
      if (definition instanceof AutoRetryConfigurable) {
        return ((AutoRetryConfigurable) definition).getAutoRetryPolicy();
      }
    } catch (Exception ignored) {
      // No policy: the step fails fast on a thrown exception, as before.
    }
    return null;
  }

  /**
   * @description Returns true when the engine can set a savepoint before
   * `execute()`. A savepoint blocks a callout, so a `CalloutStep` gets none.
   * @param step The step to run.
   * @return True when the engine sets a savepoint.
   */
  public static Boolean canRollBack(WorkflowStep step) {
    return !(step instanceof CalloutStep);
  }

  /**
   * @description Returns true when a thrown exception does not use auto-retry.
   * A row-lock error keeps its own retry path (`WorkflowTransientLockRetry`).
   * @param ex The thrown exception.
   * @return True when the engine must rethrow the exception.
   */
  public static Boolean isExcluded(Exception ex) {
    return WorkflowTransientLockRetry.isTransientLockError(ex);
  }

  /**
   * @description Returns true when the savepoint blocked a callout.
   * @param ex The thrown exception.
   * @return True for an "uncommitted work pending" callout error.
   */
  public static Boolean isCalloutConflict(Exception ex) {
    return ex instanceof CalloutException &&
      String.isNotBlank(ex.getMessage()) &&
      ex.getMessage().toLowerCase().contains(UNCOMMITTED_WORK);
  }

  /**
   * @description Returns the instance error text for exhausted retries.
   * @param attempts The number of attempts that failed.
   * @param ex The last thrown exception, or null for a returned `retry()`.
   * @return The error text.
   */
  public static String exhaustedMessage(Integer attempts, Exception ex) {
    if (ex == null) {
      return 'Max retries exceeded.';
    }
    return EXHAUSTED_PREFIX + attempts + ' attempts: ' + describe(ex);
  }

  /**
   * @description Returns the step error details for exhausted retries. For a
   * thrown exception, the details keep the message and the stack trace.
   * @param maxAttempts The maximum attempts of the policy.
   * @param attempts The number of attempts that failed.
   * @param ex The last thrown exception, or null for a returned `retry()`.
   * @return The error details.
   */
  public static String exhaustedDetails(
    Integer maxAttempts,
    Integer attempts,
    Exception ex
  ) {
    if (ex == null) {
      return 'Max retries (' + maxAttempts + ') exceeded.';
    }
    return exhaustedMessage(attempts, ex) + '\n' + ex.getStackTraceString();
  }

  /**
   * @description Writes a Warn log for a thrown exception that the engine
   * retries. Does nothing for a returned `retry()`.
   * @param outcome The step outcome with the instance, the step and the error.
   * @param maxAttempts The maximum attempts of the policy.
   */
  public static void logRetriedAttempt(
    WorkflowEngine.StepOutcomeContext outcome,
    Integer maxAttempts
  ) {
    if (outcome.thrownError == null) {
      return;
    }
    WorkflowLog.warn(
      LOG_TYPE,
      outcome.stepExec.Step_Name__c +
        ': attempt ' +
        outcome.stepExec.Retry_Count__c.intValue() +
        ' of ' +
        maxAttempts +
        ' failed: ' +
        describe(outcome.thrownError),
      outcome.instance.Id
    );
  }

  // The message, or the type name when the message is blank.
  private static String describe(Exception ex) {
    return String.isBlank(ex.getMessage()) ? ex.getTypeName() : ex.getMessage();
  }

  // Returns the definition object, or null when the name does not resolve.
  private static Object resolveDefinition(String workflowName) {
    if (String.isBlank(workflowName)) {
      return null;
    }
    if (!definitionsByName.containsKey(workflowName)) {
      Type definitionType = WorkflowTypeResolver.resolve(
        workflowName,
        WorkflowTypeResolver.extractNamespace(workflowName)
      );
      definitionsByName.put(
        workflowName,
        definitionType == null ? null : definitionType.newInstance()
      );
    }
    return definitionsByName.get(workflowName);
  }
}
