/**
 * @description Redelivery entry point for captured (pre-arrival) unrouted
 * signals in the Revenant engine. When a signal arrives before its target
 * `Workflow_Instance__c` exists it is persisted as an `Unrouted`
 * `Workflow_Signal__c`. Once a matching instance becomes active this class
 * correlates the captured signal to it, re-parents the row to `Received`, and
 * wakes the instance through the normal resume handoff. The load and target
 * resolution lock their rows FOR UPDATE and run in system mode; the actual
 * re-parent/wake (with its savepoint and duplicate-key tombstoning) remains on
 * {@link WorkflowSignalRedelivery#deliverRedeliveredSignal} because it shares the engine's
 * signal-dedup, wake and enqueue-guard primitives with the still-resident signal
 * router. Extracted from `WorkflowEngine`; callers invoke
 * {@link WorkflowUnroutedSignals#redeliverCapturedSignal} directly.
 */
public inherited sharing class WorkflowUnroutedSignals {
  /**
   * @description Re-delivers a captured (Unrouted) signal by correlating it to a
   * now-active workflow instance. If a match is found the signal row is
   * re-parented (Workflow_Instance__c set, Status flipped to 'Received') and the
   * instance is woken via the normal resume handoff. Returns true if a match was
   * found, false if the signal is still unmatched (safe no-op).
   * @param signalId Id of the captured (Unrouted) signal to redeliver
   * @return true when the signal was matched and re-parented; false when still unmatched
   */
  public static Boolean redeliverCapturedSignal(Id signalId) {
    Workflow_Signal__c sig = loadUnroutedSignal(signalId);
    if (sig == null) {
      return false;
    }

    String keyOrId = sig.Correlation_Key__c;
    if (String.isBlank(keyOrId)) {
      return false;
    }

    Workflow_Instance__c instance = resolveRedeliveryTarget(keyOrId);
    if (instance == null) {
      return false;
    }

    return WorkflowSignalRedelivery.deliverRedeliveredSignal(sig, instance);
  }

  /**
   * @description Loads and locks the Unrouted captured signal to redeliver.
   * @param signalId the captured signal id
   * @return the locked Unrouted signal row, or null when none matches
   */
  private static Workflow_Signal__c loadUnroutedSignal(Id signalId) {
    if (signalId == null) {
      return null;
    }
    List<Workflow_Signal__c> rows = [
      SELECT
        Id,
        Status__c,
        Correlation_Key__c,
        Signal_Name__c,
        Payload__c,
        Signal_Key__c,
        Idempotency_Key__c
      FROM Workflow_Signal__c
      WHERE Id = :signalId AND Status__c = 'Unrouted'
      WITH SYSTEM_MODE
      LIMIT 1
      FOR UPDATE
    ];
    return rows.isEmpty() ? null : rows[0];
  }

  /**
   * @description Resolves and locks the active instance to redeliver the
   * captured signal to, preferring an id-shaped key match, then falling back to a
   * correlation-key match.
   * @param keyOrId the captured signal's correlation key (id or key)
   * @return the locked active instance, or null when none is active
   */
  private static Workflow_Instance__c resolveRedeliveryTarget(String keyOrId) {
    List<String> activeStatuses = new List<String>{
      'Pending',
      'Running',
      'Suspended',
      'Compensating',
      'Cancelling',
      'Paused'
    };

    List<Workflow_Instance__c> instances = new List<Workflow_Instance__c>();
    if (isInstanceId(keyOrId)) {
      instances = [
        SELECT Id, Status__c, Concurrency_Parked__c, Concurrency_Slot_Held__c
        FROM Workflow_Instance__c
        WHERE Id = :keyOrId AND Status__c IN :activeStatuses
        WITH SYSTEM_MODE
        LIMIT 1
        FOR UPDATE
      ];
    }
    if (instances.isEmpty()) {
      instances = [
        SELECT Id, Status__c, Concurrency_Parked__c, Concurrency_Slot_Held__c
        FROM Workflow_Instance__c
        WHERE Correlation_Key__c = :keyOrId AND Status__c IN :activeStatuses
        WITH SYSTEM_MODE
        LIMIT 1
        FOR UPDATE
      ];
    }
    return instances.isEmpty() ? null : instances[0];
  }

  /**
   * @description Tests whether the given key-or-id string is a
   * Workflow_Instance__c record id (15/18-char id-shaped and carrying the
   * object's key prefix).
   * @param keyOrId the correlation key or instance id supplied by the caller
   * @return true when the value is a workflow instance id
   */
  private static Boolean isInstanceId(String keyOrId) {
    String wflowPrefix = Workflow_Instance__c.SObjectType.getDescribe(
        SObjectDescribeOptions.DEFERRED
      )
      .getKeyPrefix();
    Pattern idPattern = Pattern.compile('^[a-zA-Z0-9]{15}([a-zA-Z0-9]{3})?$');
    return String.isNotBlank(keyOrId) &&
      idPattern.matcher(keyOrId).matches() &&
      keyOrId.startsWith(wflowPrefix);
  }
}
