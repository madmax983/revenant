/**
 * @description Normalizes a start request's input into a top-level key/value map
 * for contract checking. Prefers the pre-serialized `inputJson`, else the typed
 * `input` Object, parsing a JSON string when needed. Records a single
 * MALFORMED_JSON violation (and returns null) when a JSON string cannot be parsed;
 * a null or non-object payload becomes an empty map so required fields surface as
 * missing rather than as a parse failure. Pure in-memory logic — no SOQL, DML, or
 * callouts. Extracted from {@link WorkflowInputValidator} to keep each class
 * within the repo's per-class complexity budget.
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
  // typed input Object (parsing a String / serializing a typed object as needed).
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
    if (req.input instanceof Map<String, Object>) {
      return req.input;
    }
    // A typed Apex object / SObject: normalize through JSON to a plain graph.
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
