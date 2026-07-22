/**
 * @description Operator signal actions for the workflow dashboard: manual signal injection
 * into a Suspended instance (gated on the signal-injection permission) and redelivery of a
 * captured unrouted signal. Extracted from WorkflowDashboardController; preserves the exact
 * authorization ordering, validation, and AuraHandledException messages. All SOQL runs WITH
 * SYSTEM_MODE.
 */
public inherited sharing class WorkflowSignalCommandService {
  /**
   * @description Operator action to manually inject a signal into an instance from the
   * dashboard. Signal injection MUTATES engine state, so it must clear the same operator-ACTION
   * baseline as the other recovery endpoints (Workflow_Operator_Action OR Workflow_Admin OR
   * Modify-All, via checkOperatorAction) IN ADDITION to holding the specific
   * Workflow_Signal_Injection capability. This prevents a read-only monitoring operator
   * (Workflow_Dashboard_View, which now satisfies checkAuthorization) from injecting signals
   * without an action grant.
   * @param instanceId The target workflow instance.
   * @param signalName The name of the signal to deliver.
   * @param payloadJson The signal payload as JSON, or blank.
   */
  public static void inject(
    Id instanceId,
    String signalName,
    String payloadJson
  ) {
    WorkflowDashboardSupport.checkAuthorization();
    WorkflowDashboardSupport.checkOperatorAction();
    validateSignalInjectionPermission();

    if (instanceId == null) {
      throw WorkflowDashboardSupport.auraError('Instance ID is required.');
    }
    if (String.isBlank(signalName)) {
      throw WorkflowDashboardSupport.auraError('Signal name is required.');
    }
    requireInjectableInstance(instanceId);

    Map<String, Object> payloadMap = parseInjectionPayload(payloadJson);
    payloadMap.put('operatorId', UserInfo.getUserId());
    payloadMap.put('operatorUsername', UserInfo.getUserName());
    payloadMap.put('operator', UserInfo.getName());

    try {
      WorkflowEngine.signal(
        String.valueOf(instanceId),
        signalName,
        JSON.serialize(payloadMap)
      );
    } catch (Exception ex) {
      throw WorkflowDashboardSupport.auraError(ex.getMessage());
    }
  }

  /**
   * @description Re-attempts routing of a captured unrouted signal to a matching instance
   * (held as Received for a paused target, without waking it).
   * @param signalId The captured Workflow_Signal__c to redeliver.
   * @return A map with a matched flag indicating whether an instance was found.
   */
  public static Map<String, Object> redeliver(Id signalId) {
    WorkflowDashboardSupport.checkAuthorization();
    WorkflowDashboardSupport.checkOperatorAction();
    Boolean matched = WorkflowUnroutedSignals.redeliverCapturedSignal(signalId);
    return new Map<String, Object>{ 'matched' => matched };
  }

  private static void validateSignalInjectionPermission() {
    if (
      !FeatureManagement.checkPermission('Workflow_Signal_Injection') &&
      !WorkflowDashboardSupport.currentUserHasModifyAllData()
    ) {
      throw WorkflowDashboardSupport.auraError(
        'Unauthorized: this action requires the "Workflow_Signal_Injection" permission.'
      );
    }
  }

  private static void requireInjectableInstance(Id instanceId) {
    List<Workflow_Instance__c> instances = [
      SELECT Status__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
      WITH SYSTEM_MODE
      LIMIT 1
    ];
    if (instances.isEmpty()) {
      throw WorkflowDashboardSupport.auraError('Workflow instance not found.');
    }
    if (instances[0].Status__c != 'Suspended') {
      throw WorkflowDashboardSupport.auraError(
        'Signal injection is only allowed on Suspended instances.'
      );
    }
  }

  private static Map<String, Object> parseInjectionPayload(String payloadJson) {
    if (payloadJson != null && payloadJson.length() > 250000) {
      throw WorkflowDashboardSupport.auraError(
        'Payload size exceeds maximum allowed limit of 250KB.'
      );
    }
    if (String.isBlank(payloadJson)) {
      return new Map<String, Object>();
    }
    Object parsed = deserializePayloadObject(payloadJson);
    if (parsed instanceof Map<String, Object>) {
      return (Map<String, Object>) parsed;
    }
    throw WorkflowDashboardSupport.auraError(
      'Invalid payload JSON: Payload JSON must be a JSON object (e.g., {"key": "value"}).'
    );
  }

  private static Object deserializePayloadObject(String payloadJson) {
    try {
      return JSON.deserializeUntyped(payloadJson);
    } catch (Exception ex) {
      throw WorkflowDashboardSupport.auraError(
        'Invalid payload JSON: ' + ex.getMessage()
      );
    }
  }
}
