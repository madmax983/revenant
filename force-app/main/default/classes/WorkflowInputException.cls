/**
 * @description Typed exception raised when a workflow's start input fails the
 * contract declared by its {@link ValidatedWorkflow} implementation. It is thrown
 * synchronously in the caller's transaction, before any `Workflow_Instance__c` is
 * inserted and before any work is enqueued, so a rejected start creates no durable
 * state (no instance row, no step, no append-only audit record).
 *
 * The exception enumerates EVERY violation, not just the first: its message lists
 * all offending fields, and {@link #getFieldErrors} exposes the same violations
 * structurally as {@link WorkflowInputFieldError} records for programmatic
 * handling. It is a top-level type (rather than a nested `WorkflowEngine` type) so
 * it can carry this structured payload and be caught precisely without importing
 * the engine facade.
 *
 * Construction note: Apex supplies the implicit `Exception(String)` constructor;
 * callers build the exception with the composed message and then attach the field
 * errors via {@link #setFieldErrors}.
 */
public class WorkflowInputException extends Exception {
  private List<WorkflowInputFieldError> fieldErrors = new List<WorkflowInputFieldError>();

  /**
   * @description Attaches the structured list of field violations enumerated in
   * this exception's message. Called by the validator immediately after
   * construction.
   * @param errors the complete set of field violations (never partial)
   */
  public void setFieldErrors(List<WorkflowInputFieldError> errors) {
    this.fieldErrors = errors == null
      ? new List<WorkflowInputFieldError>()
      : errors;
  }

  /**
   * @description Returns every field violation that caused this rejection, in the
   * order they were detected. The list is a defensive copy.
   * @return the structured field violations backing this exception's message
   */
  public List<WorkflowInputFieldError> getFieldErrors() {
    return this.fieldErrors.clone();
  }
}
