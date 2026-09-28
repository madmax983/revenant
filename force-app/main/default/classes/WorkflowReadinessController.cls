/**
 * @description Read endpoint of the Readiness panel in System Doctor (#114). It is a
 * separate class because WorkflowDashboardController is at the PMD public-member limit.
 * It uses the same view gate as the other dashboard panels.
 */
public inherited sharing class WorkflowReadinessController {
  /**
   * @description Returns the install readiness checks. Not cacheable: a fix must show
   * on the next click of Run Checks.
   * @return One row per check, in a fixed order.
   */
  @AuraEnabled
  public static List<WorkflowReadinessService.ReadinessCheck> getReadinessChecks() {
    return WorkflowReadinessService.runChecks();
  }
}
