/**
 * @description Reads the global admission state for System Doctor (issue
 * #136). Cost: max 3 SOQL (the capacity read when auto-brake is on, the
 * counter row when a ceiling is set, and one bounded parked count). No DML.
 */
public inherited sharing class GlobalAdmissionStatusService {
  /** @description The parked count stops at this value. */
  @TestVisible
  private static final Integer PARKED_COUNT_CAP = 10000;

  /**
   * @description Returns the global admission envelope. It checks the dashboard
   * view gate first.
   * @return A map with asOfMs, state (OPEN or BRAKED), governed, reason,
   * reasons, emergencyStop, autoBrake, capacityStatus, ceiling, inFlight,
   * parkedCount and parkedCapped.
   */
  public static Map<String, Object> read() {
    WorkflowDashboardSupport.checkAuthorization();
    try {
      return build(GlobalAdmissionBrake.evaluateAll());
    } catch (Exception ex) {
      throw WorkflowDashboardSupport.auraError(ex.getMessage());
    }
  }

  private static Map<String, Object> build(GlobalAdmissionPolicy.Decision d) {
    GlobalAdmissionPolicy.Inputs i = d.inputs;
    Integer countLimit = PARKED_COUNT_CAP + 1;
    Integer parked = [
      SELECT COUNT()
      FROM Workflow_Instance__c
      WHERE
        Global_Admission__c = :GlobalAdmissionPolicy.STATE_PARKED
        AND Status__c = 'Suspended'
      WITH SYSTEM_MODE
      LIMIT :countLimit
    ];
    return new Map<String, Object>{
      'asOfMs' => System.currentTimeMillis(),
      'state' => d.braked ? 'BRAKED' : 'OPEN',
      'governed' => d.governed,
      'reason' => d.reason,
      'reasons' => d.reasons,
      'emergencyStop' => i.emergencyStop,
      'autoBrake' => i.autoBrake,
      'capacityStatus' => i.capacityStatus,
      'ceiling' => i.ceiling,
      'inFlight' => i.inFlight,
      'parkedCount' => Math.min(parked, PARKED_COUNT_CAP),
      'parkedCapped' => parked > PARKED_COUNT_CAP
    };
  }
}
