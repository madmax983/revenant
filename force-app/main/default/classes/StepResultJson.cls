/**
 * @description JSON input-serialization helper extracted from StepResult (issue: analyzer decomposition). Serializes step/child/branch input the way StepResult's factories require: an already-JSON String is passed through untouched, while any other value (including a non-JSON String) is JSON-serialized. The public entry point serialize is intentionally named differently from any StepResult method to avoid the PMD class-metric recursion inflation.
 */
public inherited sharing class StepResultJson {
  /**
   * @description Serializes a factory input for durable storage: null stays null; a String that already looks like valid JSON is returned verbatim; any other String is JSON-serialized (quoted); every non-String value is JSON-serialized.
   * @param input The raw factory input to serialize, or null.
   * @return The serialized JSON String, or null when input is null.
   */
  public static String serialize(Object input) {
    if (input == null) {
      return null;
    }
    if (input instanceof String) {
      String strInput = (String) input;
      String trimmed = strInput.trim();
      if (isJsonLike(trimmed)) {
        try {
          JSON.deserializeUntyped(trimmed);
          return strInput;
        } catch (Exception ignored) {
        }
      }
      return JSON.serialize(strInput);
    }
    return JSON.serialize(input);
  }

  private static Boolean isJsonLike(String trimmed) {
    return hasJsonDelimiters(trimmed) ||
      trimmed == 'true' ||
      trimmed == 'false' ||
      trimmed == 'null' ||
      // Match standard integer or float patterns in JSON
      Pattern.matches('^-?\\d+(\\.\\d+)?([eE][+-]?\\d+)?$', trimmed);
  }

  /**
   * @description True when the trimmed value is wrapped in matching JSON object, array, or string delimiters.
   * @param trimmed The trimmed candidate string to inspect.
   * @return True if the value has matching JSON delimiters, otherwise false.
   */
  private static Boolean hasJsonDelimiters(String trimmed) {
    return (trimmed.startsWith('{') && trimmed.endsWith('}')) ||
      (trimmed.startsWith('[') && trimmed.endsWith(']')) ||
      (trimmed.startsWith('"') && trimmed.endsWith('"'));
  }
}
