/**
 * @description Read endpoint of the Global Admission panel in System Doctor
 * (issue #136). It uses the same view gate as the other dashboard panels.
 */
public inherited sharing class WorkflowGlobalAdmissionController {
  /**
   * @description Returns the global admission state. Not cacheable: the state
   * can change at any time.
   * @return A map with state, reason, reasons, controls and parkedCount.
   */
  @AuraEnabled
  public static Map<String, Object> getGlobalAdmission() {
    return GlobalAdmissionStatusService.read();
  }
}
