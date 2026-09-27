/**
 * @description Read endpoint for the System Doctor Rate Limits panel (#61). It is a
 * separate class because WorkflowDashboardController is at the PMD public-member limit.
 * It uses the same view gate as the other dashboard panels.
 */
public inherited sharing class WorkflowRateLimitController {
  /**
   * @description Returns the live token bucket of each configured rate limit.
   * @param cacheBuster An arbitrary value the client varies to bypass the LDS cache.
   * @return A map with asOfMs (the clock time in epoch ms) and rows (one map per key).
   */
  @AuraEnabled(cacheable=true)
  public static Map<String, Object> getRateLimitStatus(String cacheBuster) {
    return WorkflowRateLimitStatusService.rateLimitStatus();
  }
}
