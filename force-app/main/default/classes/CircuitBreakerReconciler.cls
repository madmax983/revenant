/**
 * CircuitBreakerReconciler — the watchdog-driven half-open sweep for the circuit
 * breaker (issue #128), lifted out of `CircuitBreakerGate` to keep the admission
 * gate below the class-level complexity thresholds, exactly as
 * `ConcurrencyReconciler` sits beside `ConcurrencyGate`.
 *
 * `tryAdmit` performs the Open -> Half-Open transition on demand when live traffic
 * hits an eligible breaker, but a dependency that opened and then went completely
 * quiet has no traffic to drive that transition. This sweep is the zero-traffic
 * backstop: each heartbeat it flips every Open breaker whose configured open
 * duration has elapsed to Half-Open (resetting the probe counter), so recovery
 * lands within one watchdog cadence even with no calls. Heavy enough to live on the
 * watchdog sweep, never on the admission hot path.
 *
 * The open duration is not on the state row. The resolver gets it from
 * `Circuit_Breaker_Config__mdt` (governor-free). Thus SOQL cannot select only
 * due rows (issue #236). SOQL also does not allow `ORDER BY` with `FOR UPDATE`.
 * The sweep has two steps:
 * 1. Find: an unlocked read of Open rows, oldest first. Keep only due rows.
 * 2. Lock: read the due rows `FOR UPDATE`. Check again, then flip.
 * Rows that are not due do not fill the batch, and the sweep does not lock them.
 * The flip is a partial-success update, so one bad row cannot stop the sweep.
 */
public inherited sharing class CircuitBreakerReconciler {
  // Max rows that one heartbeat flips. A backlog drains on later heartbeats.
  @TestVisible
  private static Integer sweepBatchSize = 200;

  // Max Open rows that one heartbeat reads to find due rows.
  @TestVisible
  private static Integer sweepScanLimit = 2000;

  /**
   * @description Flips every eligible Open breaker (open duration elapsed) to
   * Half-Open, resetting its probe counter. Bounded per heartbeat and best-effort.
   * @param mockConfigs Test-injected configs (from `CircuitBreakerGate.mockConfigs`),
   * threaded to the resolver so a purely in-memory test can drive the sweep.
   */
  public static void sweepHalfOpen(
    Map<String, Circuit_Breaker_Config__mdt> mockConfigs
  ) {
    Datetime now = Datetime.now();
    List<Id> dueIds = findDueIds(now, mockConfigs);
    if (dueIds.isEmpty()) {
      return;
    }

    List<Circuit_Breaker_State__c> toUpdate = lockDueRows(
      dueIds,
      now,
      mockConfigs
    );
    for (Circuit_Breaker_State__c row : toUpdate) {
      row.Status__c = 'HalfOpen';
      row.Half_Open_Probes_Admitted__c = 0;
      row.Half_Open_Epoch__c =
        CircuitBreakerStateStore.intOf(row.Half_Open_Epoch__c) + 1;
    }
    if (!toUpdate.isEmpty()) {
      // Partial-success update: a per-row fault is isolated so the rest of the sweep
      // still lands. The heartbeat also wraps this call in a best-effort try/catch.
      Database.update(toUpdate, false, AccessLevel.SYSTEM_MODE);
    }
  }

  /**
   * @description Finds the Ids of due Open rows, oldest first. Reads up to
   * `sweepScanLimit` rows without a lock. Keeps up to `sweepBatchSize` due rows.
   * @param now The time to compare with each open duration.
   * @param mockConfigs Test-injected configs.
   * @return The due row Ids, ordered by `Opened_At__c` (nulls first), then `Id`.
   */
  @TestVisible
  private static List<Id> findDueIds(
    Datetime now,
    Map<String, Circuit_Breaker_Config__mdt> mockConfigs
  ) {
    List<Id> ids = new List<Id>();
    for (Circuit_Breaker_State__c row : [
      SELECT Id, Dependency_Key__c, Opened_At__c
      FROM Circuit_Breaker_State__c
      WHERE Status__c = 'Open'
      WITH SYSTEM_MODE
      ORDER BY Opened_At__c ASC NULLS FIRST, Id ASC
      LIMIT :sweepScanLimit
    ]) {
      if (ids.size() >= sweepBatchSize) {
        break;
      }
      if (isEligibleForHalfOpen(row, now, mockConfigs)) {
        ids.add(row.Id);
      }
    }
    return ids;
  }

  /**
   * @description Locks the found rows and reads them again. A row that is not
   * Open now, or that opened again and is not due, is skipped.
   * @param ids The Ids from `findDueIds`.
   * @param now The time to compare with each open duration.
   * @param mockConfigs Test-injected configs.
   * @return The locked rows that are still Open and due.
   */
  @TestVisible
  private static List<Circuit_Breaker_State__c> lockDueRows(
    List<Id> ids,
    Datetime now,
    Map<String, Circuit_Breaker_Config__mdt> mockConfigs
  ) {
    List<Circuit_Breaker_State__c> locked = [
      SELECT
        Id,
        Dependency_Key__c,
        Status__c,
        Opened_At__c,
        Half_Open_Probes_Admitted__c,
        Half_Open_Epoch__c
      FROM Circuit_Breaker_State__c
      WHERE Id IN :ids AND Status__c = 'Open'
      WITH SYSTEM_MODE
      FOR UPDATE
    ];
    List<Circuit_Breaker_State__c> due = new List<Circuit_Breaker_State__c>();
    for (Circuit_Breaker_State__c row : locked) {
      if (isEligibleForHalfOpen(row, now, mockConfigs)) {
        due.add(row);
      }
    }
    return due;
  }

  // True when an Open breaker's configured open duration has elapsed. A row whose
  // dependency is no longer configured (config removed) is left untouched — there is
  // no duration to reconcile it against.
  private static Boolean isEligibleForHalfOpen(
    Circuit_Breaker_State__c row,
    Datetime now,
    Map<String, Circuit_Breaker_Config__mdt> mockConfigs
  ) {
    Circuit_Breaker_Config__mdt config = CircuitBreakerConfigResolver.getConfig(
      row.Dependency_Key__c,
      mockConfigs
    );
    if (config == null) {
      return false;
    }
    return CircuitBreakerStateStore.openDurationElapsed(
      row.Opened_At__c,
      config,
      now
    );
  }
}
