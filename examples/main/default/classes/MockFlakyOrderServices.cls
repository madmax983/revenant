/**
 * @description Test double for AutoRetryWorkflowExample (issue #101). It is a
 * payment gateway and a receipt mailer that can be down. Each outage makes one
 * call throw. The gateway charges once for each idempotency key. This is a
 * top-level class, because an inner class cannot have static members.
 */
public inherited sharing class MockFlakyOrderServices {
  /** @description Thrown when a mock service is down. */
  public class ServiceUnavailableException extends Exception {
  }

  /** @description Number of the next gateway calls that throw a 503. */
  public static Integer gatewayOutagesLeft = 0;
  /** @description Number of the next charges whose response is lost (504). */
  public static Integer lostResponsesLeft = 0;
  /** @description Number of the next receipt calls that throw. */
  public static Integer receiptOutagesLeft = 0;
  /** @description Number of charge calls, including failed calls. */
  public static Integer chargeAttempts = 0;
  /** @description Number of real charges. */
  public static Integer effectiveCharges = 0;
  /** @description Number of refunds. */
  public static Integer refunds = 0;
  /** @description Charge id of the last refund. */
  public static String lastRefundedChargeId;
  /** @description Number of receipt calls, including failed calls. */
  public static Integer receiptAttempts = 0;
  /** @description Number of receipts sent. */
  public static Integer receiptsSent = 0;

  private static Map<String, String> chargeIdByKey = new Map<String, String>();

  /**
   * @description Charges a card. Throws a 503 while the gateway is down. A
   * lost response charges the card, then throws a 504. A repeat call with the
   * same key returns the first charge.
   * @param idempotencyKey The key that stops a double charge.
   * @param amountCents The amount in cents.
   * @return The charge id.
   */
  public static String charge(String idempotencyKey, Integer amountCents) {
    chargeAttempts++;
    if (gatewayOutagesLeft > 0) {
      gatewayOutagesLeft--;
      throw new ServiceUnavailableException('503 Service Unavailable');
    }
    if (!chargeIdByKey.containsKey(idempotencyKey)) {
      effectiveCharges++;
      chargeIdByKey.put(idempotencyKey, 'ch_' + effectiveCharges);
    }
    if (lostResponsesLeft > 0) {
      lostResponsesLeft--;
      throw new ServiceUnavailableException('504 Gateway Timeout');
    }
    return chargeIdByKey.get(idempotencyKey);
  }

  /**
   * @description Refunds a charge.
   * @param chargeId The charge to refund.
   */
  public static void refund(String chargeId) {
    refunds++;
    lastRefundedChargeId = chargeId;
  }

  /**
   * @description Sends a receipt email. Throws while the mailer is down.
   * @param orderId The order of the receipt.
   */
  public static void sendReceipt(String orderId) {
    receiptAttempts++;
    if (receiptOutagesLeft > 0) {
      receiptOutagesLeft--;
      throw new ServiceUnavailableException('421 Mail service not available');
    }
    receiptsSent++;
  }

  /**
   * @description Sets all counters and outages to the start values.
   */
  @TestVisible
  private static void reset() {
    gatewayOutagesLeft = 0;
    lostResponsesLeft = 0;
    lastRefundedChargeId = null;
    receiptOutagesLeft = 0;
    chargeAttempts = 0;
    effectiveCharges = 0;
    refunds = 0;
    receiptAttempts = 0;
    receiptsSent = 0;
    chargeIdByKey = new Map<String, String>();
  }
}
