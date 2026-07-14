/**
 * @description Argument validation for the StepResult factory methods, extracted from StepResult (issue: analyzer decomposition) so the factory-heavy StepResult class stays under the class-complexity thresholds. Every method throws IllegalArgumentException with the exact operator-facing message the corresponding factory previously threw, preserving behavior byte-for-byte. Method names are distinct from StepResult's so the class-level complexity metric does not treat the delegation as recursion.
 */
public inherited sharing class StepResultValidator {
  /**
   * @description Throws IllegalArgumentException with the given message when the value is null or blank.
   * @param value The string to check.
   * @param message The exact error message to throw when the value is blank.
   */
  public static void requireNonBlank(String value, String message) {
    if (String.isBlank(value)) {
      throw new IllegalArgumentException(message);
    }
  }

  /**
   * @description Throws IllegalArgumentException with the given message when the reference is null.
   * @param value The object to check.
   * @param message The exact error message to throw when the value is null.
   */
  public static void requireNonNull(Object value, String message) {
    if (value == null) {
      throw new IllegalArgumentException(message);
    }
  }

  /**
   * @description Throws IllegalArgumentException with the given message when the seconds value is null or negative.
   * @param seconds The seconds value to check.
   * @param message The exact error message to throw when the value is invalid.
   */
  public static void requireNonNegativeSeconds(
    Integer seconds,
    String message
  ) {
    if (seconds == null || seconds < 0) {
      throw new IllegalArgumentException(message);
    }
  }

  /**
   * @description Validates a durable-timeout pair: the timeout step must be non-blank and the timeout seconds must be a positive integer. Error messages are prefixed with the given factory context (e.g. 'StepResult.suspend') so each factory throws its own operator-facing message.
   * @param timeoutSeconds The positive number of seconds before the wait times out.
   * @param timeoutStep The non-blank step to route to on timeout.
   * @param contextPrefix The factory-name prefix for the thrown messages (e.g. 'StepResult.suspend').
   */
  public static void requirePositiveTimeout(
    Integer timeoutSeconds,
    String timeoutStep,
    String contextPrefix
  ) {
    if (String.isBlank(timeoutStep)) {
      throw new IllegalArgumentException(
        contextPrefix + ': timeoutStep must not be blank'
      );
    }
    if (timeoutSeconds == null || timeoutSeconds <= 0) {
      throw new IllegalArgumentException(
        contextPrefix + ': timeoutSeconds must be a positive integer'
      );
    }
  }

  /**
   * @description Validates the parallel-split step-name list: it must be non-null, non-empty, and contain no null or blank entries, throwing the split-specific messages otherwise.
   * @param stepNames The list of step names to run in parallel.
   */
  public static void requireValidStepNames(List<String> stepNames) {
    if (stepNames == null || stepNames.isEmpty()) {
      throw new IllegalArgumentException(
        'StepResult.split: stepNames list must not be null or empty'
      );
    }
    for (String stepName : stepNames) {
      if (String.isBlank(stepName)) {
        throw new IllegalArgumentException(
          'StepResult.split: stepNames list must not contain null or blank values'
        );
      }
    }
  }

  /**
   * @description Validates the fan-out child-request list: it must be non-null, non-empty, and contain no null entries, throwing the startChildren-specific messages otherwise.
   * @param children The list of child requests to start together.
   */
  public static void requireValidChildren(
    List<StepResult.ChildRequest> children
  ) {
    if (children == null || children.isEmpty()) {
      throw new IllegalArgumentException(
        'StepResult.startChildren: children list must not be null or empty'
      );
    }
    for (StepResult.ChildRequest child : children) {
      if (child == null) {
        throw new IllegalArgumentException(
          'StepResult.startChildren: children list must not contain null values'
        );
      }
    }
  }
}
