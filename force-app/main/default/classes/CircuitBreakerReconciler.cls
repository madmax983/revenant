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
 * The per-row open duration is NOT stored on the state row; it is resolved from
 * `Circuit_Breaker_Config__mdt` per row (via `CircuitBreakerConfigResolver`, which
 * is governor-free). The bounded, restrictive `Status__c = 'Open'` query runs
 * `WITH SYSTEM_MODE FOR UPDATE`; the flip is a partial-success update so one bad row
 * cannot sink the sweep.
 */
public inherited sharing class CircuitBreakerReconciler {
  // Max Open breakers a single heartbeat flips, bounding the sweep's governor usage.
  // A backlog drains on subsequent heartbeats.
  @TestVisible
  private static Integer sweepBatchSize = 200;

  /**
   * @description Flips every eligible Open breaker (open duration elapsed) to
   * Half-Open, resetting its probe counter. Bounded per heartbeat and best-effort.
   * @param mockConfigs Test-injected configs (from `CircuitBreakerGate.mockConfigs`),
   * threaded to the resolver so a purely in-memory test can drive the sweep.
   */
  public static void sweepHalfOpen(
    Map<String, Circuit_Breaker_Config__mdt> mockConfigs
  ) {
    List<Circuit_Breaker_State__c> openRows = [
      SELECT
        Dependency_Key__c,
        Status__c,
        Opened_At__c,
        Half_Open_Probes_Admitted__c
      FROM Circuit_Breaker_State__c
      WHERE Status__c = 'Open'
      WITH SYSTEM_MODE
      LIMIT :sweepBatchSize
      FOR UPDATE
    ];
    if (openRows.isEmpty()) {
      return;
    }

    Datetime now = Datetime.now();
    List<Circuit_Breaker_State__c> toUpdate = new List<Circuit_Breaker_State__c>();
    for (Circuit_Breaker_State__c row : openRows) {
      if (isEligibleForHalfOpen(row, now, mockConfigs)) {
        row.Status__c = 'HalfOpen';
        row.Half_Open_Probes_Admitted__c = 0;
        toUpdate.add(row);
      }
    }
    if (!toUpdate.isEmpty()) {
      // Partial-success update: a per-row fault is isolated so the rest of the sweep
      // still lands. The heartbeat also wraps this call in a best-effort try/catch.
      Database.update(toUpdate, false, AccessLevel.SYSTEM_MODE);
    }
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
