/**
 * @description Normalizes a start request's input into a top-level key/value map
 * for contract checking, validating the EXACT graph the engine persists and the
 * first step receives — never a different interpretation.
 *
 * The engine's persistence rule (scalar {@link WorkflowScalarStartService} and
 * bulk {@link WorkflowBulkStartFinalize}) is: store `req.inputJson` verbatim when
 * it is non-null, otherwise store `JSON.serialize(req.input)`. This parser mirrors
 * that byte-for-byte:
 * - `inputJson != null` → validate `JSON.deserializeUntyped(inputJson)` (the raw
 *   object graph the engine stores).
 * - otherwise → validate `JSON.deserializeUntyped(JSON.serialize(req.input))` for
 *   EVERY `input` type, including a `String`. A `String` `input` is therefore
 *   validated as the scalar string the step will receive (the engine stores the
 *   quoted, serialized string), NOT as raw JSON — so passing a JSON-object string
 *   as `input` to a `ValidatedWorkflow` whose contract expects object fields now
 *   correctly fails (all fields missing) instead of falsely passing. To supply an
 *   object payload, use `inputJson` (preserved raw), not a JSON string in `input`.
 *
 * Because every non-`inputJson` value goes through the same JSON round-trip the
 * engine uses to persist, all input forms validate identically: a native Apex
 * `Date`/`Datetime` in a `Map` is carried as its ISO-8601 string form (exactly as
 * the JSON path carries it), so `DATE_TYPE`/`DATETIME_TYPE` accept both forms; and
 * numbers normalize to the same `Integer`/`Long`/`Double` kinds. Records a single
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

  // Resolve the raw parsed graph exactly as the engine will persist it: the raw
  // inputJson when it is set (the engine stores it verbatim), otherwise the JSON
  // round-trip of req.input (the engine stores JSON.serialize(req.input)). No
  // input type is special-cased — a String input is serialized like any other
  // value, so it validates as the scalar string the step will receive, matching
  // persistence. Selector mirrors the engine's `req.inputJson != null` check.
  private static Object resolveGraph(
    WorkflowEngine.StartRequest req,
    List<WorkflowInputFieldError> errors
  ) {
    if (req.inputJson != null) {
      return tryParse(req.inputJson, errors);
    }
    if (req.input == null) {
      return null;
    }
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
