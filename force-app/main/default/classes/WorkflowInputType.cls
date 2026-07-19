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
 * - `INTEGER_TYPE`  — the value is a whole number within the signed 32-bit range
 *                     [-2147483648, 2147483647] (an Apex `Integer`, or a `Long`
 *                     that fits). A whole number OUTSIDE that range is rejected —
 *                     use `LONG_TYPE` for wide integers — because a downstream step
 *                     reading the field as an Apex `Integer` would otherwise fail.
 *                     A fractional number or a numeric string never satisfies it.
 * - `LONG_TYPE`     — any whole number (`Integer` or `Long`), including values
 *                     outside the 32-bit range; use it to name a wide integer.
 * - `DECIMAL_TYPE`  — the value is any JSON number (`Integer`, `Long`, `Double`, or
 *                     `Decimal`); the issue's generic "Number" maps here.
 * - `BOOLEAN_TYPE`  — the value is a JSON boolean; the strings "true"/"false" do
 *                     NOT satisfy it.
 * - `DATE_TYPE`     — an ISO-8601 date (`yyyy-MM-dd`). Accepted as a JSON string,
 *                     or as a native Apex `Date` supplied in a `Map` start input
 *                     (the engine normalizes it to its ISO form before checking,
 *                     so both input forms validate identically).
 * - `DATETIME_TYPE` — an ISO-8601 datetime. Accepted as a JSON string, or as a
 *                     native Apex `Datetime` supplied in a `Map` start input
 *                     (normalized to its ISO form before checking).
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
