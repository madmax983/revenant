/**
 * @description The stored form of an encoded payload:
 * `{"$codec":"<KIND>","data":"<codec output>"}`. Only
 * {@link WorkflowPayloadCodecs} makes and reads it. A value is an envelope only
 * when it has this exact shape and a known kind. The envelope is valid JSON, so
 * JSON readers do not fail on it.
 */
public inherited sharing class WorkflowPayloadEnvelope {
  private static final String KIND_START = '{"$codec":"';
  private static final String DATA_MARKER = '","data":"';
  private static final String ENVELOPE_END = '"}';
  private static final Map<String, CodecContext.PayloadKind> KINDS = kindsByName();
  // JSON strings cannot hold raw control characters.
  private static final Pattern CONTROL_CHAR = Pattern.compile('[\\x00-\\x1f]');

  /**
   * @description Makes an envelope.
   * @param kind the payload class
   * @param data the codec output
   * @return the envelope text
   */
  public static String wrap(CodecContext.PayloadKind kind, String data) {
    return KIND_START + kind.name() + DATA_MARKER + escape(data) + ENVELOPE_END;
  }

  /**
   * @description Returns the kind of a valid envelope. It reads only the short
   * kind text, so it is cheap for large values.
   * @param stored a stored value
   * @return the kind, or null when the value is not an envelope
   */
  public static CodecContext.PayloadKind kindOf(String stored) {
    if (
      stored == null ||
      !stored.startsWith(KIND_START) ||
      !stored.endsWith(ENVELOPE_END)
    ) {
      return null;
    }
    Integer markerAt = stored.indexOf(DATA_MARKER, KIND_START.length());
    CodecContext.PayloadKind kind = markerAt < 0
      ? null
      : KINDS.get(stored.substring(KIND_START.length(), markerAt));
    return (kind != null && hasOnlyData(stored, markerAt)) ? kind : null;
  }

  // True when `data` is the last and only other property, in the exact form
  // the engine writes.
  private static Boolean hasOnlyData(String stored, Integer markerAt) {
    Integer dataStart = markerAt + DATA_MARKER.length();
    Integer dataEnd = stored.length() - ENVELOPE_END.length();
    Matcher control = CONTROL_CHAR.matcher(stored);
    control.region(dataStart, dataEnd);
    if (control.find()) {
      return false;
    }
    // Data without a backslash needs only an index check. Any backslash gets
    // a full JSON check, so a bad escape stays plaintext.
    if (stored.indexOf('\\', dataStart) < 0) {
      return stored.indexOf('"', dataStart) == dataEnd;
    }
    // The data must be one JSON string in the exact form the engine writes.
    // This rejects bad escapes, extra keys and duplicate keys.
    String raw = stored.substring(dataStart, dataEnd);
    try {
      String data = (String) JSON.deserialize('"' + raw + '"', String.class);
      return escape(data).equals(raw);
    } catch (Exception e) {
      return false;
    }
  }

  /**
   * @description Returns the codec output of a valid envelope. The engine
   * writes the data without escapes when it can, so a JSON parse is usually not
   * necessary.
   * @param stored a valid envelope
   * @param kind the kind that {@link #kindOf} returned
   * @return the codec output
   */
  public static String dataOf(String stored, CodecContext.PayloadKind kind) {
    String raw = stored.substring(
      KIND_START.length() + kind.name().length() + DATA_MARKER.length(),
      stored.length() - ENVELOPE_END.length()
    );
    return raw.contains('\\')
      ? (String) JSON.deserialize('"' + raw + '"', String.class)
      : raw;
  }

  // Returns the data as JSON string content. Printable ASCII without quotes or
  // backslashes (for example base64) needs no escapes.
  private static String escape(String data) {
    if (data.isAsciiPrintable() && !data.containsAny('"\\')) {
      return data;
    }
    String json = JSON.serialize(data);
    return json.substring(1, json.length() - 1);
  }

  private static Map<String, CodecContext.PayloadKind> kindsByName() {
    Map<String, CodecContext.PayloadKind> byName = new Map<String, CodecContext.PayloadKind>();
    for (CodecContext.PayloadKind kind : CodecContext.PayloadKind.values()) {
      byName.put(kind.name(), kind);
    }
    return byName;
  }
}
