/**
 * @description Primitive value types a {@link WorkflowInputContract} field may
 * declare, matching the value kinds a JSON start payload can carry once parsed by
 * `JSON.deserializeUntyped`. This is a forever-public enum: values are only ever
 * added, never renamed or removed, so a contract compiled today keeps its meaning.
 *
 * Coercion rules applied by {@link WorkflowInputValidator} (strict, no mutation of
 * the payload):
 * - `STRING`   — the value is a JSON string.
 * - `INTEGER`  — the value is a whole number (`Integer` or `Long`); a fractional
 *                number or a numeric string does NOT satisfy it.
 * - `LONG`     — same acceptance set as `INTEGER` (`Integer` or `Long`), for
 *                authors who want to name a wide integer explicitly.
 * - `DECIMAL`  — the value is any JSON number (`Integer`, `Long`, `Double`, or
 *                `Decimal`); the issue's generic "Number" maps here.
 * - `BOOLEAN`  — the value is a JSON boolean; the strings "true"/"false" do NOT
 *                satisfy it.
 * - `DATE`     — the value is a JSON string parseable as an ISO-8601 date
 *                (`yyyy-MM-dd`).
 * - `DATETIME` — the value is a JSON string parseable as an ISO-8601 datetime.
 */
public enum WorkflowInputType {
  STRING,
  INTEGER,
  LONG,
  DECIMAL,
  BOOLEAN,
  DATE,
  DATETIME
}
