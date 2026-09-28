/**
 * @description Read endpoint of the Readiness panel in System Doctor (#114). It is a
 * separate class because WorkflowDashboardController is at the PMD public-member limit.
 */
public inherited sharing class WorkflowReadinessController {
  /**
   * @description Returns the install readiness checks.
   * @return One row per check.
   */
  @AuraEnabled
  public static List<WorkflowReadinessService.ReadinessCheck> getReadinessChecks() {
    return WorkflowReadinessService.runChecks();
  }
}
