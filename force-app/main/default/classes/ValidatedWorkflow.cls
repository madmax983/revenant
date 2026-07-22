/**
 * @description Opt-in contract a workflow author implements to declare the shape
 * of the start input its instances require. When a workflow definition also
 * implements this interface, the engine validates each start payload against the
 * declared {@link WorkflowInputContract} synchronously in the caller's
 * transaction — before any `Workflow_Instance__c` is inserted and before any
 * work is enqueued — and rejects a missing-field, wrong-type, or malformed-JSON
 * payload with a field-level {@link WorkflowInputException}. Definitions that do
 * not implement this interface are unaffected: their start input is never
 * inspected, so the feature is fully backward compatible and costs nothing to the
 * simple case. Detection is a single in-memory `instanceof` on the resolved
 * definition instance; it adds no SOQL and no DML to the start path.
 */
public interface ValidatedWorkflow {
  /**
   * @description Declares the required (and optionally the type-checked optional)
   * fields of this workflow's start input. Called once per start, in memory, on a
   * freshly instantiated definition; it must not perform SOQL, DML, or callouts.
   * Returning `null` or an empty contract disables validation for the workflow
   * (equivalent to not implementing this interface).
   * @return The input contract describing the start payload's required fields and
   *   their primitive types.
   */
  WorkflowInputContract getInputContract();
}
