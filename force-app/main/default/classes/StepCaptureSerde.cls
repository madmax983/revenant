/**
 * @description Serialization helpers for the capture-once payload, split out of
 * StepCaptures. Parses stored captured-values JSON, extracts and re-injects the
 * reserved retry/error bookkeeping keys (__maxAttempts / __failedStepName /
 * __errorMessage / __attemptCount), and defensively copies returned values.
 * Pure functions over a captured-values map and the retry metadata; holds no
 * state.
 */
public inherited sharing class StepCaptureSerde {
  /**
   * @description Parses a captured-values JSON string safely into a Map, catching
   * parsing exceptions and handling malformed payloads defensively.
   * @param jsonStr The captured values JSON to parse.
   * @return The parsed map, or an empty map when blank or malformed.
   */
  public static Map<String, Object> parseCaptures(String jsonStr) {
    if (String.isBlank(jsonStr)) {
      return new Map<String, Object>();
    }
    try {
      Object deserialized = JSON.deserializeUntyped(jsonStr);
      if (deserialized instanceof Map<String, Object>) {
        return (Map<String, Object>) deserialized;
      }
    } catch (Exception ignored) {
    }
    return new Map<String, Object>();
  }

  /**
   * @description Returns a defensive copy of a captured value so caller-local
   * mutations of a returned Map/List cannot reach the canonical instance held in
   * the captured-values map. Primitives are immutable, so they are returned as-is
   * to avoid needless allocation.
   * @param value The captured value to defensively copy.
   * @return A deep copy for Map/List values, or the value itself for primitives.
   */
  public static Object defensiveCopy(Object value) {
    if (value instanceof Map<String, Object> || value instanceof List<Object>) {
      return JSON.deserializeUntyped(JSON.serialize(value));
    }
    return value;
  }

  /**
   * @description Extracts the reserved retry/error bookkeeping keys from the
   * captured values (removing them) and writes them onto the retry metadata,
   * preserving the original extraction order exactly.
   * @param capturedValues The captured values map to strip reserved keys from.
   * @param retry The retry metadata to populate.
   */
  public static void extractReservedCaptures(
    Map<String, Object> capturedValues,
    StepRetryInfo retry
  ) {
    if (capturedValues.containsKey('__maxAttempts')) {
      try {
        retry.setMaxAttempts(
          Integer.valueOf(capturedValues.get('__maxAttempts'))
        );
      } catch (Exception ignored) {
      }
      capturedValues.remove('__maxAttempts');
    }
    if (capturedValues.containsKey('__failedStepName')) {
      retry.setFailedStepName(
        String.valueOf(capturedValues.get('__failedStepName'))
      );
      capturedValues.remove('__failedStepName');
    }
    if (capturedValues.containsKey('__errorMessage')) {
      retry.setErrorMessage(
        String.valueOf(capturedValues.get('__errorMessage'))
      );
      capturedValues.remove('__errorMessage');
    }
    if (capturedValues.containsKey('__attemptCount')) {
      try {
        retry.setAttemptCount(
          Integer.valueOf(capturedValues.get('__attemptCount'))
        );
      } catch (Exception ignored) {
      }
      capturedValues.remove('__attemptCount');
    }
  }

  /**
   * @description Serializes all captured values, re-injecting the four reserved
   * retry/error bookkeeping keys from the retry metadata, or returns null when
   * there is nothing to persist.
   * @param capturedValues The captured values accumulated this execution.
   * @param retry The retry metadata whose reserved keys are re-injected.
   * @return The serialized captured values (including reserved metadata), or null
   * when there is nothing to persist.
   */
  public static String getCapturedValuesJson(
    Map<String, Object> capturedValues,
    StepRetryInfo retry
  ) {
    if (hasNothingToSerialize(capturedValues, retry)) {
      return null;
    }
    Map<String, Object> toSerialize = new Map<String, Object>(capturedValues);
    if (retry.maxAttempts != null && retry.maxAttempts > 1) {
      toSerialize.put('__maxAttempts', retry.maxAttempts);
    }
    if (String.isNotBlank(retry.failedStepName)) {
      toSerialize.put('__failedStepName', retry.failedStepName);
    }
    if (String.isNotBlank(retry.errorMessage)) {
      toSerialize.put('__errorMessage', retry.errorMessage);
    }
    if (retry.attemptCount != null) {
      toSerialize.put('__attemptCount', retry.attemptCount);
    }
    return JSON.serialize(toSerialize);
  }

  // True when there are no captures and no reserved metadata (retry/error
  // bookkeeping) to persist, so getCapturedValuesJson() returns null.
  private static Boolean hasNothingToSerialize(
    Map<String, Object> capturedValues,
    StepRetryInfo retry
  ) {
    return capturedValues.isEmpty() &&
      (retry.maxAttempts == null ||
      retry.maxAttempts <= 1) &&
      String.isBlank(retry.failedStepName) &&
      String.isBlank(retry.errorMessage) &&
      retry.attemptCount == null;
  }
}
