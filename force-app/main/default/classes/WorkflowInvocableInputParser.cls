public inherited sharing class WorkflowInvocableInputParser {
  /**
   * Deserializes an untyped JSON input payload. Returns null when the payload
   * is blank; throws a WorkflowException with an 'Invalid Input JSON' message
   * when the payload is not valid JSON.
   */
  public static Object parseInputJson(String inputJson) {
    if (String.isBlank(inputJson)) {
      return null;
    }
    try {
      return JSON.deserializeUntyped(inputJson);
    } catch (Exception ex) {
      throw new WorkflowEngine.WorkflowException(
        'Invalid Input JSON: ' + ex.getMessage()
      );
    }
  }

  /**
   * Strictly parses an attributes JSON object into a String-to-String map.
   * Blank input yields null. Non-object JSON or a parse failure throws a
   * WorkflowException with an 'Invalid Attributes JSON' message.
   */
  public static Map<String, String> parseAttributesJson(String attributesJson) {
    if (String.isBlank(attributesJson)) {
      return null;
    }
    Map<String, String> attributes = new Map<String, String>();
    try {
      Object deserialized = JSON.deserializeUntyped(attributesJson);
      if (deserialized instanceof Map<String, Object>) {
        putStringValues((Map<String, Object>) deserialized, attributes);
      } else {
        throw new WorkflowEngine.WorkflowException(
          'Attributes JSON must represent a key-value object.'
        );
      }
    } catch (Exception ex) {
      throw new WorkflowEngine.WorkflowException(
        'Invalid Attributes JSON: ' + ex.getMessage()
      );
    }
    return attributes;
  }

  /**
   * Leniently parses an attributes JSON object into a String-to-String map.
   * Blank input yields null; malformed or non-object JSON yields an empty map.
   */
  public static Map<String, String> parseAttributesJsonLenient(
    String attributesJson
  ) {
    if (String.isBlank(attributesJson)) {
      return null;
    }
    Map<String, String> attributes = new Map<String, String>();
    try {
      Object deserialized = JSON.deserializeUntyped(attributesJson);
      if (deserialized instanceof Map<String, Object>) {
        putStringValues((Map<String, Object>) deserialized, attributes);
      }
    } catch (Exception ignored) {
      // Lenient parse: ignore malformed attribute payloads.
    }
    return attributes;
  }

  /**
   * Validates an attributes JSON payload against the engine's structural and
   * size limits. Blank input is a no-op. Note: unlike parseAttributesJson, a
   * non-object payload throws an unwrapped 'must represent a key-value object'
   * message, matching the engine's stricter debounce validation contract.
   */
  public static void validateAttributesJson(String attributesJson) {
    if (String.isBlank(attributesJson)) {
      return;
    }
    if (attributesJson.length() > 131072) {
      throw new WorkflowEngine.WorkflowException(
        'Attributes JSON payload exceeds maximum size limit of 131,072 characters.'
      );
    }
    Map<String, Object> raw = deserializeAttributeObject(attributesJson);
    if (raw.size() > WorkflowEngine.MAX_ATTRIBUTES_PER_INSTANCE) {
      throw new WorkflowEngine.WorkflowException(
        'Attribute count exceeds maximum limit of ' +
        WorkflowEngine.MAX_ATTRIBUTES_PER_INSTANCE
      );
    }
    for (String key : raw.keySet()) {
      validateAttributeEntry(key, raw.get(key));
    }
  }

  private static Map<String, Object> deserializeAttributeObject(
    String attributesJson
  ) {
    Object deserialized;
    try {
      deserialized = JSON.deserializeUntyped(attributesJson);
    } catch (Exception ex) {
      throw new WorkflowEngine.WorkflowException(
        'Invalid Attributes JSON: ' + ex.getMessage()
      );
    }
    if (!(deserialized instanceof Map<String, Object>)) {
      throw new WorkflowEngine.WorkflowException(
        'Attributes JSON must represent a key-value object.'
      );
    }
    return (Map<String, Object>) deserialized;
  }

  private static void validateAttributeEntry(String key, Object rawValue) {
    if (String.isBlank(key)) {
      throw new WorkflowEngine.WorkflowException(
        'Attribute key cannot be blank'
      );
    }
    if (key.length() > WorkflowEngine.MAX_ATTRIBUTE_KEY_LENGTH) {
      throw new WorkflowEngine.WorkflowException(
        'Attribute key length exceeds maximum limit of ' +
          WorkflowEngine.MAX_ATTRIBUTE_KEY_LENGTH +
          ' characters: ' +
          key
      );
    }
    String val = rawValue == null ? null : String.valueOf(rawValue);
    if (
      val != null &&
      val.length() > WorkflowEngine.MAX_ATTRIBUTE_VALUE_LENGTH
    ) {
      throw new WorkflowEngine.WorkflowException(
        'Attribute value length exceeds maximum limit of ' +
          WorkflowEngine.MAX_ATTRIBUTE_VALUE_LENGTH +
          ' characters: ' +
          val
      );
    }
  }

  private static void putStringValues(
    Map<String, Object> raw,
    Map<String, String> target
  ) {
    for (String k : raw.keySet()) {
      target.put(k, String.valueOf(raw.get(k)));
    }
  }
}
