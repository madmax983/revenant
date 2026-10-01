/**
 * @description Encodes and decodes author payloads at the persistence seam.
 * The engine calls `encode` before it writes a workflow input, step output,
 * step state or signal payload. The engine calls `decode` after it reads one.
 * Use it to keep sensitive payload data as ciphertext at rest.
 *
 * Select the codec in `Revenant_Config__mdt.Payload_Codec__c`. Blank selects
 * the identity codec. The codec owns its keys. The engine does not.
 *
 * Rules for an implementation:
 * - `decode(encode(p, ctx), ctx)` must return `p`.
 * - Both methods must not change data. Do not do DML.
 * - Do not make callouts. The engine calls `encode` after DML in the same
 *   transaction.
 * - Load key material without a query per call. For example, keep it in an
 *   instance field. The engine calls `decode` once for each row it reads.
 * - Throw an exception when the data cannot be decoded. Do not return
 *   ciphertext as plaintext. The engine replaces the message, so the message
 *   does not go into error fields.
 * - Use a top-level public class with a public no-argument constructor. The
 *   engine loads it by name.
 */
global interface PayloadCodec {
  /**
   * @description Encodes one serialized payload before the engine stores it.
   * @param plaintext the payload text. It is never blank.
   * @param ctx the payload context
   * @return the encoded text to store
   */
  String encode(String plaintext, CodecContext ctx);

  /**
   * @description Decodes one stored payload after the engine reads it.
   * @param stored the text that `encode` returned
   * @param ctx the same payload context that `encode` got
   * @return the original payload text
   */
  String decode(String stored, CodecContext ctx);
}
