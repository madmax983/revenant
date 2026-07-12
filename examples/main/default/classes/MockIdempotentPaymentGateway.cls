/**
 * Reference helper for issue #2. Stands in for a Stripe-style idempotent
 * endpoint: it records exactly one effective side effect per distinct
 * Idempotency-Key. A repeat call carrying a key it has already seen returns the
 * prior charge WITHOUT charging again.
 *
 * This is a top-level class because Apex inner classes cannot declare static
 * members, and classes may only nest one level deep (so the `ChargeResult`
 * helper lives here, one level in, rather than nested two deep under the
 * workflow example).
 */
public inherited sharing class MockIdempotentPaymentGateway {
  // Counts only true (effective) side effects -- i.e. first-seen keys.
  public static Integer effectiveSideEffectCount = 0;
  private static Map<String, String> chargeIdByKey = new Map<String, String>();
  private static Integer sequence = 0;

  /**
   * @description Outcome of a charge attempt: the charge id and whether it was deduplicated
   * from a prior call with the same idempotency key.
   */
  public class ChargeResult {
    public String chargeId;
    public Boolean deduplicated;

    /**
     * @description Constructs a charge result.
     * @param chargeId The id of the charge, new or previously recorded.
     * @param deduplicated True if this result reused a prior charge for the same key.
     */
    public ChargeResult(String chargeId, Boolean deduplicated) {
      this.chargeId = chargeId;
      this.deduplicated = deduplicated;
    }
  }

  /**
   * @description Records exactly one effective charge per distinct idempotency key,
   * returning the prior charge without charging again when the key has been seen before.
   * @param idempotencyKey The caller-supplied key that dedups repeat calls.
   * @param amountCents The charge amount in cents.
   * @return A ChargeResult with the charge id and whether it was deduplicated.
   */
  public static ChargeResult charge(
    String idempotencyKey,
    Integer amountCents
  ) {
    if (
      String.isNotBlank(idempotencyKey) &&
      chargeIdByKey.containsKey(idempotencyKey)
    ) {
      // Server-side dedup on the caller-supplied key: no new side effect.
      return new ChargeResult(chargeIdByKey.get(idempotencyKey), true);
    }
    // First time we have seen this key: the one real, effective charge.
    effectiveSideEffectCount++;
    sequence++;
    String chargeId = 'ch_' + sequence;
    if (String.isNotBlank(idempotencyKey)) {
      chargeIdByKey.put(idempotencyKey, chargeId);
    }
    return new ChargeResult(chargeId, false);
  }

  @TestVisible
  private static void reset() {
    effectiveSideEffectCount = 0;
    chargeIdByKey = new Map<String, String>();
    sequence = 0;
  }
}
