/**
 * @description Engine facade for the configured {@link PayloadCodec}. It
 * encodes author payloads before the engine writes them and decodes them after
 * the engine reads them.
 *
 * Stored form: {@link WorkflowPayloadEnvelope}. The envelope identifies encoded
 * values and gives `decode` the same {@link CodecContext}. A value without a valid envelope is plaintext. It
 * passes through unchanged, so rows written before the codec stay readable.
 * The identity codec adds no envelope, so stored bytes do not change.
 *
 * `encode` always encodes non-blank input, also when the input looks like an
 * envelope. Engine copy paths copy stored forms field to field and do not call
 * `encode`.
 *
 * The engine does not encode control values: offload markers
 * (`{"$attachmentId":...}`), wait markers, status, compensation stack, keys and
 * timestamps.
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
  // Matches a reserved stored-form key in JSON text.
  private static final Pattern RESERVED_KEY = Pattern.compile(
    '"(\\$attachmentId|\\$codec)"'
  );

  private static Boolean loaded = false;
  // Null means identity.
  private static PayloadCodec activeCodec;

  /**
   * @description Thrown when the codec configuration is not valid, or when a
   * stored value cannot be encoded or decoded. The engine fails closed: it never
   * gives ciphertext to a step as plaintext. The message does not contain
   * payload text.
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
   * @description Returns true when the value is a valid engine envelope.
   * @param stored a stored field value
   * @return true for an encoded value
   */
  public static Boolean isEncoded(String stored) {
    return WorkflowPayloadEnvelope.kindOf(stored) != null;
  }

  /**
   * @description Encodes a payload for storage. Returns the value unchanged
   * when it is blank, when the codec is identity, or when it is an offload
   * marker. It encodes all other values, also values that look like an envelope.
   * @param plaintext the payload text
   * @param kind the payload class
   * @return the stored form
   */
  public static String encode(String plaintext, CodecContext.PayloadKind kind) {
    if (String.isBlank(plaintext) || plaintext.startsWith(OFFLOAD_PREFIX)) {
      return plaintext;
    }
    PayloadCodec codec = active();
    if (codec == null) {
      return plaintext;
    }
    String data;
    try {
      data = codec.encode(plaintext, new CodecContext(kind));
    } catch (Exception e) {
      throw new PayloadCodecException(
        'Payload codec failed to encode ' + kind.name() + ': ' + e.getTypeName()
      );
    }
    return WorkflowPayloadEnvelope.wrap(kind, data);
  }

  /**
   * @description Decodes a stored value. Returns the value unchanged when it
   * has no valid envelope. This method is read-only.
   * @param stored the stored field value or offload file text
   * @return the payload text
   * @throws PayloadCodecException when no codec is configured, or when the
   *         codec cannot decode the value
   */
  public static String decode(String stored) {
    CodecContext.PayloadKind kind = WorkflowPayloadEnvelope.kindOf(stored);
    if (kind == null) {
      return stored;
    }
    PayloadCodec codec = active();
    if (codec == null) {
      throw new PayloadCodecException(
        'The payload is encoded, but no payload codec is configured. ' +
        'Set Revenant_Config__mdt.Payload_Codec__c.'
      );
    }
    try {
      return codec.decode(
        WorkflowPayloadEnvelope.dataOf(stored, kind),
        new CodecContext(kind)
      );
    } catch (Exception e) {
      throw new PayloadCodecException(
        'Payload codec failed to decode ' + kind.name() + ': ' + e.getTypeName()
      );
    }
  }

  /**
   * @description Estimates whether the engine can offload a payload. Use it for
   * DML reserve estimates. A codec can make the stored text much larger, and
   * {@link PayloadCodec} sets no limit on the growth. So with a codec, every
   * non-blank payload counts. A high estimate only drops best-effort rows.
   * @param payload the plaintext payload
   * @return true when the payload can go to a file
   */
  public static Boolean mayOffload(String payload) {
    return String.isNotBlank(payload) &&
      (!isIdentity() || payload.length() > 100000);
  }

  /**
   * @description Finds a reserved stored-form key (`$attachmentId` or `$codec`)
   * in JSON text. Operator input must not contain one.
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
   * @description Makes a codec from a class name. Blank returns null
   * (identity). A name that does not give a {@link PayloadCodec} throws. The
   * lookup uses {@link WorkflowTypeResolver}, so namespaced and subscriber
   * classes resolve.
   * @param className the codec class name, with namespace if necessary
   * @return the codec, or null for identity
   */
  @TestVisible
  private static PayloadCodec resolve(String className) {
    if (String.isBlank(className)) {
      return null;
    }
    Type codecType = WorkflowTypeResolver.resolve(className.trim());
    if (codecType == null) {
      throw new PayloadCodecException(
        'Payload codec class not found: ' + className
      );
    }
    if (!PayloadCodec.class.isAssignableFrom(codecType)) {
      throw new PayloadCodecException(
        'Class does not implement PayloadCodec: ' + className
      );
    }
    try {
      return (PayloadCodec) codecType.newInstance();
    } catch (Exception e) {
      throw new PayloadCodecException(
        'Payload codec class cannot be made: ' + className
      );
    }
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
      if (WorkflowEngine.payloadCodecConfigFailed) {
        throw new PayloadCodecException(
          'Revenant_Config__mdt could not be read. Payload access stops.'
        );
      }
      activeCodec = normalize(resolve(WorkflowEngine.payloadCodecClass));
      loaded = true;
    }
    return activeCodec;
  }

  private static PayloadCodec normalize(PayloadCodec codec) {
    return (codec instanceof IdentityPayloadCodec) ? null : codec;
  }
}
