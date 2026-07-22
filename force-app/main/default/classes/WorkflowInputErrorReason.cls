/**
 * @description Why a single start-input field failed validation, carried by
 * {@link WorkflowInputFieldError}. A top-level enum (rather than a type nested in
 * the error class) so it can name the error's `reason` property without a
 * case-insensitive collision, and so it sits alongside the other forever-public
 * input-validation types. Values are append-only.
 * - `MISSING`        — a required key was absent or explicitly null.
 * - `WRONG_TYPE`     — a present value did not satisfy the declared type.
 * - `MALFORMED_JSON` — the start payload itself could not be parsed as JSON, so no
 *                      per-field checks could run (reported once, with a null
 *                      `fieldName`).
 */
public enum WorkflowInputErrorReason {
  MISSING,
  WRONG_TYPE,
  MALFORMED_JSON
}
