/**
 * @description Read endpoint of the Fleet Health view (#111). It is a separate class
 * because WorkflowDashboardController is at the PMD public-member limit. It uses the same
 * view gate as the other dashboard panels.
 */
public inherited sharing class WorkflowFleetHealthController {
  /**
   * @description Returns one health row for each definition with instances started in
   * the window. Not cacheable: the data is live.
   * @param windowKey '1h', '24h' or '7d'. A blank or unknown key gives '24h'.
   * @return A map with windowKey, windowHours, sampleCap, isSampled and rows.
   */
  @AuraEnabled
  public static Map<String, Object> getFleetHealth(String windowKey) {
    return WorkflowFleetHealthService.fleetHealth(windowKey);
  }
}
