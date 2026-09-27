/**
 * @description Engine facade for the configured {@link PayloadCodec}. It
 * encodes author payloads before the engine writes them and decodes them after
 * the engine reads them.
 *
 * Stored form: `{"$codec":"<KIND>","data":"<codec output>"}`. The engine adds
 * this envelope, so it can find encoded values, skip a second encode, and give
 * `decode` the same {@link CodecContext}. Values without the envelope are
 * plaintext. They pass through unchanged, so rows written before the codec stay
 * readable. The identity codec adds no envelope, so stored bytes do not change.
 *
 * The engine does not encode control values: offload markers
 * (`{"$attachmentId":...}`), status, compensation stack, keys and timestamps.
 */
public inherited sharing class WorkflowPayloadCodecs {
  /** @description The first characters of every encoded value. */
  public static final String ENVELOPE_PREFIX = '{"$codec":';
  /**
   * @description Display text for an encoded payload on operator surfaces. It is
   * valid JSON, so JSON readers do not fail.
   */
  public static final String REDACTED_PAYLOAD = '{"$redacted":"Encoded by the payload codec. Operator views do not decode it."}';
  private static final String OFFLOAD_PREFIX = '{"$attachmentId":';
  private static final String DATA_KEY = 'data';
  // Matches a reserved stored-form key in JSON text.
  private static final Pattern RESERVED_KEY = Pattern.compile(
    '"(\\$attachmentId|\\$codec)"'
  );

  private static Boolean loaded = false;
  // Null means identity.
  private static PayloadCodec activeCodec;

  /**
   * @description Thrown when the codec configuration is not valid, or when a
   * stored value cannot be decoded. The engine fails closed: it never gives
   * ciphertext to a step as plaintext.
   */
  public class PayloadCodecException extends Exception {
  }

  /**
   * @description Returns true when the active codec is the identity codec.
   * @return true when payloads are stored unchanged
   */
  public static Boolean isIdentity() {
    return active() == null;
  }

  /**
   * @description Returns true when the value has the codec envelope.
   * @param stored a stored field value
   * @return true for an encoded value
   */
  public static Boolean isEncoded(String stored) {
    return stored != null && stored.startsWith(ENVELOPE_PREFIX);
  }

  /**
   * @description Encodes a payload for storage. Returns the value unchanged
   * when the codec is identity, the value is blank, or the value is already a
   * stored form (an envelope or an offload marker).
   * @param plaintext the payload text
   * @param kind the payload class
   * @return the stored form
   */
  public static String encode(String plaintext, CodecContext.PayloadKind kind) {
    PayloadCodec codec = active();
    if (
      codec == null ||
      String.isBlank(plaintext) ||
      isEncoded(plaintext) ||
      plaintext.startsWith(OFFLOAD_PREFIX)
    ) {
      return plaintext;
    }
    String data = codec.encode(plaintext, new CodecContext(kind));
    return ENVELOPE_PREFIX +
      JSON.serialize(kind.name()) +
      ',"' +
      DATA_KEY +
      '":' +
      JSON.serialize(data) +
      '}';
  }

  /**
   * @description Finds a reserved stored-form key (`$attachmentId` or `$codec`)
   * in JSON text. Operator input must not contain one, or the engine reads it as
   * a stored form.
   * @param jsonText the JSON text to check
   * @return the reserved key, or null when none is present
   */
  public static String findReservedMarker(String jsonText) {
    Matcher m = RESERVED_KEY.matcher(jsonText == null ? '' : jsonText);
    return m.find() ? m.group(1) : null;
  }

  /**
   * @description Returns text that is safe for an audit log. With a real codec
   * it returns a redaction note for non-blank text. Identity returns the text.
   * @param plaintext the payload text
   * @return the text, or the redaction note
   */
  public static String redactForLog(String plaintext) {
    return (String.isBlank(plaintext) || isIdentity())
      ? plaintext
      : REDACTED_PAYLOAD;
  }

  /**
   * @description Decodes a stored value. Returns the value unchanged when it
   * has no envelope. This method is read-only.
   * @param stored the stored field value or offload blob text
   * @return the payload text
   * @throws PayloadCodecException when no codec is configured or the envelope
   *         is not valid
   */
  public static String decode(String stored) {
    if (!isEncoded(stored)) {
      return stored;
    }
    PayloadCodec codec = active();
    if (codec == null) {
      throw new PayloadCodecException(
        'The payload is encoded, but no payload codec is configured. ' +
        'Set Revenant_Config__mdt.Payload_Codec__c.'
      );
    }
    Map<String, Object> envelope = parseEnvelope(stored);
    return codec.decode(
      (String) envelope.get(DATA_KEY),
      new CodecContext(toKind((String) envelope.get('$codec')))
    );
  }

  /**
   * @description Makes a codec from a class name. Blank returns null
   * (identity). A name that does not give a {@link PayloadCodec} throws.
   * @param className the codec class name, with namespace if necessary
   * @return the codec, or null for identity
   */
  @TestVisible
  private static PayloadCodec resolve(String className) {
    if (String.isBlank(className)) {
      return null;
    }
    Type codecType = Type.forName(className.trim());
    if (codecType == null) {
      throw new PayloadCodecException(
        'Payload codec class not found: ' + className
      );
    }
    Object instance;
    try {
      instance = codecType.newInstance();
    } catch (Exception e) {
      throw new PayloadCodecException(
        'Payload codec class cannot be made: ' + className,
        e
      );
    }
    if (!(instance instanceof PayloadCodec)) {
      throw new PayloadCodecException(
        'Class does not implement PayloadCodec: ' + className
      );
    }
    return (PayloadCodec) instance;
  }

  /**
   * @description Sets the active codec for a test. Null selects identity.
   * @param codec the codec to use
   */
  @TestVisible
  private static void setCodec(PayloadCodec codec) {
    activeCodec = normalize(codec);
    loaded = true;
  }

  private static PayloadCodec active() {
    if (!loaded) {
      activeCodec = normalize(resolve(WorkflowEngine.payloadCodecClass));
      loaded = true;
    }
    return activeCodec;
  }

  private static PayloadCodec normalize(PayloadCodec codec) {
    return (codec instanceof IdentityPayloadCodec) ? null : codec;
  }

  private static Map<String, Object> parseEnvelope(String stored) {
    try {
      Map<String, Object> envelope = (Map<String, Object>) JSON.deserializeUntyped(
        stored
      );
      if (envelope.get(DATA_KEY) instanceof String) {
        return envelope;
      }
    } catch (Exception e) {
      throw new PayloadCodecException('The payload envelope is not valid.', e);
    }
    throw new PayloadCodecException('The payload envelope has no data.');
  }

  private static CodecContext.PayloadKind toKind(String name) {
    for (CodecContext.PayloadKind kind : CodecContext.PayloadKind.values()) {
      if (kind.name() == name) {
        return kind;
      }
    }
    throw new PayloadCodecException('Unknown payload kind: ' + name);
  }
}
