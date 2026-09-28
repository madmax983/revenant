/**
 * @description Test double for RetryConfigWorkflowExample (issue #103). It is
 * a partner API that can be down. Each outage makes one call fail. The API
 * stores one order for each idempotency key. This is a top-level class,
 * because an inner class cannot have static members.
 */
public inherited sharing class MockPartnerApi {
  /** @description Number of the next calls that get a 503. */
  public static Integer outagesLeft = 0;
  /** @description Number of calls, including failed calls. */
  public static Integer calls = 0;

  private static Set<String> storedKeys = new Set<String>();

  /**
   * @description Sends an order to the partner.
   * @param idempotencyKey The key that stops a duplicate order.
   * @return The HTTP status code: 503 while the API is down, else 200.
   */
  public static Integer pushOrder(String idempotencyKey) {
    calls++;
    if (outagesLeft > 0) {
      outagesLeft--;
      return 503;
    }
    storedKeys.add(idempotencyKey);
    return 200;
  }

  /**
   * @description Returns the number of orders that the partner stored.
   * @return The count of stored orders.
   */
  public static Integer storedOrders() {
    return storedKeys.size();
  }

  /** @description Clears all counters. */
  public static void reset() {
    outagesLeft = 0;
    calls = 0;
    storedKeys.clear();
  }
}
