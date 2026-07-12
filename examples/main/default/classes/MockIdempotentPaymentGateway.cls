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
   * Outcome of a charge attempt: a first-seen key results in a real CHARGED
   * side effect, while a repeat key is served from cache as DEDUPLICATED.
   */
  public enum ChargeOutcome {
    CHARGED,
    DEDUPLICATED
  }

  public class ChargeResult {
    public String chargeId;
    public Boolean deduplicated;

    public ChargeResult(String chargeId, ChargeOutcome outcome) {
      this.chargeId = chargeId;
      this.deduplicated = (outcome == ChargeOutcome.DEDUPLICATED);
    }
  }

  public static ChargeResult charge(
    String idempotencyKey,
    Integer amountCents
  ) {
    if (
      String.isNotBlank(idempotencyKey) &&
      chargeIdByKey.containsKey(idempotencyKey)
    ) {
      // Server-side dedup on the caller-supplied key: no new side effect.
      return new ChargeResult(
        chargeIdByKey.get(idempotencyKey),
        ChargeOutcome.DEDUPLICATED
      );
    }
    // First time we have seen this key: the one real, effective charge.
    effectiveSideEffectCount++;
    sequence++;
    String chargeId = 'ch_' + sequence;
    if (String.isNotBlank(idempotencyKey)) {
      chargeIdByKey.put(idempotencyKey, chargeId);
    }
    return new ChargeResult(chargeId, ChargeOutcome.CHARGED);
  }

  @TestVisible
  private static void reset() {
    effectiveSideEffectCount = 0;
    chargeIdByKey = new Map<String, String>();
    sequence = 0;
  }
}
