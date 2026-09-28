/**
 * @description Read endpoint of the Async Apex Capacity panel in System Doctor (#129).
 * It is a separate class because WorkflowDashboardController is at the PMD
 * public-member limit. It uses the same view gate as the other dashboard panels.
 */
public inherited sharing class WorkflowAsyncCapacityController {
  /**
   * @description Returns the async Apex capacity envelope. Not cacheable: the values
   * change each minute.
   * @return A map with asOfMs, status, chainAtRisk, thresholds, metrics and jobCounts.
   */
  @AuraEnabled
  public static Map<String, Object> getAsyncCapacity() {
    return WorkflowAsyncCapacityService.asyncCapacity();
  }
}
