/**
 * @description The default {@link PayloadCodec}. It returns each payload
 * unchanged. The engine does not wrap identity output, so stored bytes stay
 * the same as before the codec seam.
 */
public inherited sharing class IdentityPayloadCodec implements PayloadCodec {
  /**
   * @description Returns the payload unchanged.
   * @param plaintext the payload text
   * @param ctx the payload context
   * @return the same text
   */
  public String encode(String plaintext, CodecContext ctx) {
    return plaintext;
  }

  /**
   * @description Returns the stored text unchanged.
   * @param stored the stored text
   * @param ctx the payload context
   * @return the same text
   */
  public String decode(String stored, CodecContext ctx) {
    return stored;
  }
}
