/**
 * @description Primitive value types a {@link WorkflowInputContract} field may
 * declare, matching the value kinds a JSON start payload can carry once parsed by
 * `JSON.deserializeUntyped`. This is a forever-public enum: values are only ever
 * added, never renamed or removed, so a contract compiled today keeps its meaning.
 * Each constant carries a `_TYPE` suffix because the bare primitive names
 * (`String`, `Integer`, …) are reserved Apex identifiers and cannot be enum
 * constants.
 *
 * Coercion rules applied by {@link WorkflowInputValidator} (strict, no mutation of
 * the payload):
 * - `STRING_TYPE`   — the value is a JSON string.
 * - `INTEGER_TYPE`  — the value is a whole number (`Integer` or `Long`); a
 *                     fractional number or a numeric string does NOT satisfy it.
 * - `LONG_TYPE`     — same acceptance set as `INTEGER_TYPE` (`Integer` or `Long`),
 *                     for authors who want to name a wide integer explicitly.
 * - `DECIMAL_TYPE`  — the value is any JSON number (`Integer`, `Long`, `Double`, or
 *                     `Decimal`); the issue's generic "Number" maps here.
 * - `BOOLEAN_TYPE`  — the value is a JSON boolean; the strings "true"/"false" do
 *                     NOT satisfy it.
 * - `DATE_TYPE`     — the value is a JSON string parseable as an ISO-8601 date
 *                     (`yyyy-MM-dd`).
 * - `DATETIME_TYPE` — the value is a JSON string parseable as an ISO-8601 datetime.
 */
public enum WorkflowInputType {
  STRING_TYPE,
  INTEGER_TYPE,
  LONG_TYPE,
  DECIMAL_TYPE,
  BOOLEAN_TYPE,
  DATE_TYPE,
  DATETIME_TYPE
}
