/**
 * @description Normalizes a start request's input into a top-level key/value map
 * for contract checking. Prefers the pre-serialized `inputJson`, else the typed
 * `input` Object. Crucially, EVERY input form is normalized through the same JSON
 * round-trip the engine uses to persist the payload (`JSON.serialize` ->
 * `JSON.deserializeUntyped`), so a given value validates identically whether it
 * arrives as an `inputJson` string, a `Map<String, Object>`, or a typed Apex
 * object/SObject. In particular a native Apex `Date`/`Datetime` supplied in a Map
 * is carried as its ISO-8601 string form — exactly as the JSON path carries it —
 * so `DATE_TYPE`/`DATETIME_TYPE` accept both forms consistently (the former
 * Map-vs-JSON false negative is gone). Records a single MALFORMED_JSON violation
 * (and returns null) when a JSON string cannot be parsed; a null or non-object
 * payload becomes an empty map so required fields surface as missing rather than
 * as a parse failure. Pure in-memory logic — no SOQL, DML, or callouts. Extracted
 * from {@link WorkflowInputValidator} to keep each class within the repo's
 * per-class complexity budget.
 */
public inherited sharing class WorkflowInputPayloadParser {
  /**
   * @description Parses the request's start input into a top-level field map, or
   * null when the payload was malformed JSON (in which case a MALFORMED_JSON error
   * is appended to `errors`).
   * @param req the start request whose input to normalize
   * @param errors the running violation list to append a MALFORMED_JSON error to
   * @return the top-level field map, or null when the payload was malformed
   */
  public static Map<String, Object> parse(
    WorkflowEngine.StartRequest req,
    List<WorkflowInputFieldError> errors
  ) {
    Object graph = resolveGraph(req, errors);
    if (!errors.isEmpty()) {
      // A malformed-JSON error was recorded; per-field checks cannot run.
      return null;
    }
    if (graph instanceof Map<String, Object>) {
      return (Map<String, Object>) graph;
    }
    return new Map<String, Object>();
  }

  // Resolve the raw parsed graph from the request, preferring inputJson, then the
  // typed input Object. Every non-blank input is normalized through the SAME JSON
  // round-trip the engine uses to persist (JSON.serialize -> deserializeUntyped),
  // so a value validates identically whether it arrives as an inputJson string, a
  // Map<String, Object>, or a typed Apex object/SObject: a native Apex Date /
  // Datetime in a Map becomes its ISO-8601 string form (exactly as the JSON path
  // carries it), and numbers normalize to the same Integer/Long/Double kinds. This
  // removes the Map-vs-JSON false negative for DATE_TYPE / DATETIME_TYPE without a
  // separate code path.
  private static Object resolveGraph(
    WorkflowEngine.StartRequest req,
    List<WorkflowInputFieldError> errors
  ) {
    if (String.isNotBlank(req.inputJson)) {
      return tryParse(req.inputJson, errors);
    }
    if (req.input == null) {
      return null;
    }
    if (req.input instanceof String) {
      return tryParse((String) req.input, errors);
    }
    // A Map<String, Object>, a typed Apex object, or an SObject: normalize through
    // the engine's own JSON serialization so all input forms validate identically.
    return tryParse(JSON.serialize(req.input), errors);
  }

  // Parse a JSON string, recording a MALFORMED_JSON error (and returning null) on
  // failure. A successful parse of a non-object graph returns that graph.
  private static Object tryParse(
    String raw,
    List<WorkflowInputFieldError> errors
  ) {
    try {
      return JSON.deserializeUntyped(raw);
    } catch (Exception parseFailure) {
      errors.add(WorkflowInputFieldError.malformedJson());
      return null;
    }
  }
}
