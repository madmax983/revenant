/**
 * @description Forever-public, structured description of a single start-input
 * violation carried by {@link WorkflowInputException}. Every field that fails the
 * contract produces one of these — the validator never fails fast, so a caller
 * receives the complete set in one exception. The shape is deliberately small and
 * stable: the offending key, a machine-readable {@link Reason}, and (where useful)
 * the expected primitive type and a human label for the actual value's type.
 * Instances are built through the {@link #missing}, {@link #wrongType}, and
 * {@link #malformedJson} factories.
 */
public inherited sharing class WorkflowInputFieldError {
  /**
   * @description Why a field failed validation.
   * - `MISSING`       — a required key was absent or explicitly null.
   * - `WRONG_TYPE`    — a present value did not satisfy the declared type.
   * - `MALFORMED_JSON`— the start payload itself could not be parsed as JSON, so
   *                     no per-field checks could run (reported once, with a null
   *                     `fieldName`).
   */
  public enum Reason {
    MISSING,
    WRONG_TYPE,
    MALFORMED_JSON
  }

  /** @description The offending top-level key, or null for a MALFORMED_JSON error. */
  public String fieldName { get; private set; }
  /** @description The machine-readable reason this field failed. */
  public Reason reason { get; private set; }
  /** @description The declared primitive type, when the reason is WRONG_TYPE; else null. */
  public WorkflowInputType expectedType { get; private set; }
  /** @description A human label for the actual value's type, when useful; else null. */
  public String actualType { get; private set; }

  /**
   * @description Builds a MISSING violation for a required key that was absent or
   * explicitly null.
   * @param fieldName the required key that was missing
   * @return the MISSING field error
   */
  public static WorkflowInputFieldError missing(String fieldName) {
    WorkflowInputFieldError err = new WorkflowInputFieldError();
    err.fieldName = fieldName;
    err.reason = Reason.MISSING;
    return err;
  }

  /**
   * @description Builds a WRONG_TYPE violation for a present value that did not
   * satisfy the declared type.
   * @param fieldName the offending key
   * @param expectedType the declared primitive type
   * @param actualType a human label for the actual value's type
   * @return the WRONG_TYPE field error
   */
  public static WorkflowInputFieldError wrongType(
    String fieldName,
    WorkflowInputType expectedType,
    String actualType
  ) {
    WorkflowInputFieldError err = new WorkflowInputFieldError();
    err.fieldName = fieldName;
    err.reason = Reason.WRONG_TYPE;
    err.expectedType = expectedType;
    err.actualType = actualType;
    return err;
  }

  /**
   * @description Builds the single MALFORMED_JSON violation used when the start
   * payload could not be parsed as JSON.
   * @return the MALFORMED_JSON field error
   */
  public static WorkflowInputFieldError malformedJson() {
    WorkflowInputFieldError err = new WorkflowInputFieldError();
    err.reason = Reason.MALFORMED_JSON;
    return err;
  }

  /**
   * @description Renders this single violation as a readable clause, e.g.
   * "field 'amount' expected DECIMAL but was String" or "field 'accountId' is
   * required but missing".
   * @return a human-readable description of this violation
   */
  public String describe() {
    if (this.reason == Reason.MALFORMED_JSON) {
      return 'input JSON could not be parsed';
    }
    if (this.reason == Reason.MISSING) {
      return 'field \'' + this.fieldName + '\' is required but missing';
    }
    return 'field \'' +
      this.fieldName +
      '\' expected ' +
      this.expectedType +
      ' but was ' +
      (this.actualType == null ? 'a different type' : this.actualType);
  }
}
