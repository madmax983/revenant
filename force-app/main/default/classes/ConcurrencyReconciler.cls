/**
 * ConcurrencyReconciler — reconciles `Concurrency_State__c` counter rows against the
 * true number of non-terminal slot-holding instances, reclaiming slots leaked by
 * instances that died without releasing (crash / killed transaction). Lifted out of
 * `ConcurrencyGate` (issue #28) to keep the admission gate below the class-level
 * complexity thresholds.
 *
 * This is heavy work: it locks counter rows `FOR UPDATE` and runs an aggregate over
 * `Workflow_Instance__c`. It lives on the watchdog sweep, never on the admission hot
 * path. The public `reconcile` / `reconcileAll` entry points remain on
 * `ConcurrencyGate` as thin delegators into this class's single entry.
 */
public inherited sharing class ConcurrencyReconciler {
  // Instance statuses that no longer hold a slot. A slot-holder is any instance NOT
  // in this set (so the recoverable, non-terminal CompensationFailed still counts).
  private static final Set<String> TERMINAL_STATUSES = new Set<String>{
    'Completed',
    'Failed',
    'Compensated',
    'Cancelled',
    'ContinuedAsNew'
  };

  /**
   * @description Reconciles counter rows to the true non-terminal slot-holder count. Pass a
   * specific set of workflow names to reconcile only those rows, or null to reconcile every
   * existing counter row (the watchdog heartbeat path).
   * @param onlyWorkflows The workflow definition names to reconcile, or null for all rows.
   */
  public static void reconcile(Set<String> onlyWorkflows) {
    List<Concurrency_State__c> states = loadStatesForReconcile(onlyWorkflows);
    if (states.isEmpty()) {
      return;
    }

    Set<String> workflowNames = new Set<String>();
    for (Concurrency_State__c state : states) {
      workflowNames.add(state.Workflow_Definition__c);
    }

    Map<String, Integer> trueCounts = computeTrueCounts(workflowNames);
    List<Concurrency_State__c> toUpdate = applyReconciledCounts(
      states,
      trueCounts
    );
    if (!toUpdate.isEmpty()) {
      update as system toUpdate;
    }
  }

  // Locks every counter row (or only the requested subset) for reconciliation. The
  // unscoped read has a LIMIT ceiling equal to the SOQL row cap so it stays inside the
  // AvoidNonRestrictiveQueries guard while returning the identical result set — the
  // counter table holds one row per configured workflow definition, far below the cap,
  // and a query returning more than the cap would already fail without the LIMIT.
  private static List<Concurrency_State__c> loadStatesForReconcile(
    Set<String> onlyWorkflows
  ) {
    if (onlyWorkflows == null) {
      return [
        SELECT Workflow_Definition__c, In_Flight_Count__c
        FROM Concurrency_State__c
        WITH SYSTEM_MODE
        LIMIT 50000
        FOR UPDATE
      ];
    }
    return [
      SELECT Workflow_Definition__c, In_Flight_Count__c
      FROM Concurrency_State__c
      WHERE Workflow_Definition__c IN :onlyWorkflows
      WITH SYSTEM_MODE
      FOR UPDATE
    ];
  }

  // One aggregate yields the true non-terminal slot-holder count per workflow.
  // Key the counts case-insensitively: Workflow_Definition__c is a case-insensitive
  // unique field, so instances started with differing casing all map to one state
  // row, but a case-sensitive Apex lookup would miss them and wrongly reset the
  // counter to 0. Fold each group into a normalized (lower-cased) key, summing.
  private static Map<String, Integer> computeTrueCounts(
    Set<String> workflowNames
  ) {
    Map<String, Integer> trueCounts = new Map<String, Integer>();
    for (AggregateResult ar : [
      SELECT Workflow_Name__c wf, COUNT(Id) cnt
      FROM Workflow_Instance__c
      WHERE
        Workflow_Name__c IN :workflowNames
        AND Concurrency_Slot_Held__c = TRUE
        AND Status__c NOT IN :TERMINAL_STATUSES
      WITH SYSTEM_MODE
      GROUP BY Workflow_Name__c
    ]) {
      String nk = ((String) ar.get('wf')).toLowerCase();
      Integer cnt = (Integer) ar.get('cnt');
      trueCounts.put(
        nk,
        (trueCounts.containsKey(nk) ? trueCounts.get(nk) : 0) + cnt
      );
    }
    return trueCounts;
  }

  // Resets each counter row to its reconciled truth, returning only the rows whose
  // stored value actually changed (or was null).
  private static List<Concurrency_State__c> applyReconciledCounts(
    List<Concurrency_State__c> states,
    Map<String, Integer> trueCounts
  ) {
    List<Concurrency_State__c> toUpdate = new List<Concurrency_State__c>();
    for (Concurrency_State__c state : states) {
      String stateKey = state.Workflow_Definition__c.toLowerCase();
      Integer truth = trueCounts.containsKey(stateKey)
        ? trueCounts.get(stateKey)
        : 0;
      if (
        state.In_Flight_Count__c == null ||
        (Integer) state.In_Flight_Count__c != truth
      ) {
        state.In_Flight_Count__c = truth;
        toUpdate.add(state);
      }
    }
    return toUpdate;
  }
}
