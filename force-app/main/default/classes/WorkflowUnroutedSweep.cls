/**
 * @description Unrouted-signal safety-net sweep for the watchdog heartbeat
 * (§2b). Queries the sparse backlog of Unrouted signals, resolves the Suspended
 * instances whose Id or Correlation_Key matches, and redelivers the still-
 * Unrouted signals to them (excluding paused definitions).
 *
 * Extracted from WorkflowEngine as part of the watchdog decomposition; driven by
 * WorkflowHeartbeatService. All DML and SOQL run in system mode so the engine can
 * drive workflows regardless of the invoking user's object permissions.
 */
public inherited sharing class WorkflowUnroutedSweep {
  /**
   * @description §2b. Sweep Suspended instances for matching Unrouted signals
   * (safety net).
   */
  public static void sweepUnroutedSuspendedSignals() {
    if (WorkflowPauseGate.wildcardPaused()) {
      return;
    }

    // 1. Query sparse Unrouted signals first (safety net capped backlog)
    List<Workflow_Signal__c> unrouted = [
      SELECT
        Id,
        Correlation_Key__c,
        Status__c,
        Idempotency_Key__c,
        Signal_Key__c
      FROM Workflow_Signal__c
      WHERE Status__c = 'Unrouted'
      WITH SYSTEM_MODE
      ORDER BY CreatedDate ASC, Id ASC
      LIMIT 1000
    ];

    if (unrouted.isEmpty()) {
      return;
    }

    Set<String> keys = new Set<String>();
    for (Workflow_Signal__c sig : unrouted) {
      if (String.isNotBlank(sig.Correlation_Key__c)) {
        keys.add(sig.Correlation_Key__c);
      }
    }

    if (keys.isEmpty()) {
      return;
    }

    List<Workflow_Instance__c> matchInsts = findSuspendedInstancesForKeys(keys);
    if (matchInsts.isEmpty()) {
      return;
    }

    redeliverUnroutedSignalsFor(matchInsts);
  }

  // Resolve the Suspended instances whose Id or Correlation_Key matches any of
  // the given Unrouted-signal keys (bounded, excluding paused definitions).
  private static List<Workflow_Instance__c> findSuspendedInstancesForKeys(
    Set<String> keys
  ) {
    Set<String> pausedDefNames = WorkflowPauseGate.pausedNames();

    // Limit batch size defensively for this non-bulkified redelivery loop
    Integer sweepLimit = 20;

    // Split correlation keys from Id binds to avoid System.QueryException: Invalid ID
    String wflowPrefix = Workflow_Instance__c.SObjectType.getDescribe(
        SObjectDescribeOptions.DEFERRED
      )
      .getKeyPrefix();
    Pattern idPattern = Pattern.compile('^[a-zA-Z0-9]{15}([a-zA-Z0-9]{3})?$');
    Set<Id> instIds = new Set<Id>();
    Set<String> corrKeys = new Set<String>();

    for (String key : keys) {
      if (idPattern.matcher(key).matches() && key.startsWith(wflowPrefix)) {
        instIds.add((Id) key);
      } else {
        corrKeys.add(key);
      }
    }

    return [
      SELECT
        Id,
        Correlation_Key__c,
        Status__c,
        Concurrency_Parked__c,
        Concurrency_Slot_Held__c
      FROM Workflow_Instance__c
      WHERE
        Status__c = 'Suspended'
        AND (Id IN :instIds
        OR Correlation_Key__c IN :corrKeys)
        AND Workflow_Name__c NOT IN :pausedDefNames
      WITH SYSTEM_MODE
      LIMIT :sweepLimit
      FOR UPDATE
    ];
  }

  // Group all still-Unrouted signals for the matched instances and redeliver them.
  private static void redeliverUnroutedSignalsFor(
    List<Workflow_Instance__c> matchInsts
  ) {
    Map<String, Workflow_Instance__c> keyToInst = new Map<String, Workflow_Instance__c>();
    Set<String> matchInstKeys = new Set<String>();
    for (Workflow_Instance__c inst : matchInsts) {
      String instIdStr = String.valueOf(inst.Id);
      keyToInst.put(WorkflowKeys.normalizeKey(instIdStr), inst);
      matchInstKeys.add(instIdStr);
      if (String.isNotBlank(inst.Correlation_Key__c)) {
        keyToInst.put(WorkflowKeys.normalizeKey(inst.Correlation_Key__c), inst);
        matchInstKeys.add(inst.Correlation_Key__c);
      }
    }

    List<Workflow_Signal__c> allMatchSignals = [
      SELECT
        Id,
        Correlation_Key__c,
        Status__c,
        Idempotency_Key__c,
        Signal_Key__c,
        CreatedDate
      FROM Workflow_Signal__c
      WHERE Status__c = 'Unrouted' AND Correlation_Key__c IN :matchInstKeys
      WITH SYSTEM_MODE
      ORDER BY CreatedDate ASC, Id ASC
      LIMIT 10000
    ];

    if (allMatchSignals.isEmpty()) {
      return;
    }

    Map<Id, List<Workflow_Signal__c>> instIdToSignals = new Map<Id, List<Workflow_Signal__c>>();
    for (Workflow_Signal__c sig : allMatchSignals) {
      if (String.isBlank(sig.Correlation_Key__c)) {
        continue;
      }
      Workflow_Instance__c inst = keyToInst.get(
        WorkflowKeys.normalizeKey(sig.Correlation_Key__c)
      );
      if (inst == null) {
        continue;
      }
      if (!instIdToSignals.containsKey(inst.Id)) {
        instIdToSignals.put(inst.Id, new List<Workflow_Signal__c>());
      }
      instIdToSignals.get(inst.Id).add(sig);
    }

    WorkflowSignalRedelivery.redeliverCapturedSignalsBulk(
      matchInsts,
      instIdToSignals
    );
  }
}
