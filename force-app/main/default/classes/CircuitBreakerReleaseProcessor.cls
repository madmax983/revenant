/**
 * CircuitBreakerReleaseProcessor — records guarded-step failures and successes
 * against the durable circuit-breaker state (issue #128), lifted out of
 * `CircuitBreakerGate` to keep the admission gate below the class-level complexity
 * thresholds, mirroring how `ConcurrencyReleaseProcessor` sits beside
 * `ConcurrencyGate`.
 *
 * A failure increments the rolling window under the row's `FOR UPDATE` lock (via
 * `CircuitBreakerStateStore`) and trips the breaker Open at the threshold; a
 * half-open probe failure re-opens it. A success closes a half-open probe. The bulk
 * failure path processes each dependency key independently under its own lock so a
 * lock wait or DML fault on one hot dependency-key row cannot drop or fault a valid
 * sibling key in the same batch (the #226 sibling-safety lesson) — each per-key
 * failure is isolated (best-effort logged) and the remaining keys still record.
 */
public inherited sharing class CircuitBreakerReleaseProcessor {
  /**
   * @description Bulk failure recording keyed by dependency to a failure count. Each
   * key is processed under its own lock with per-key error isolation. Null/blank keys
   * and null/non-positive counts are skipped.
   * @param failuresByKey Map of dependency key to the number of failures to record.
   */
  public static void recordFailureBulk(Map<String, Integer> failuresByKey) {
    if (failuresByKey == null || failuresByKey.isEmpty()) {
      return;
    }
    for (String dependencyKey : failuresByKey.keySet()) {
      Integer count = failuresByKey.get(dependencyKey);
      if (String.isBlank(dependencyKey) || count == null || count <= 0) {
        continue;
      }
      try {
        recordFailureForKey(dependencyKey, count);
      } catch (Exception isolatedKeyError) {
        // Sibling safety: one bad key (lock wait, over-long/invalid key, DML fault)
        // must not sink the rest of the batch. Isolate and continue.
        WorkflowLog.error(
          'CircuitBreaker',
          'recordFailureBulk skipped dependency key "' +
            dependencyKey +
            '": ' +
            isolatedKeyError.getMessage()
        );
      }
    }
  }

  // Records `count` failures against one dependency key under its own lock.
  private static void recordFailureForKey(String dependencyKey, Integer count) {
    Circuit_Breaker_Config__mdt config = CircuitBreakerGate.getConfig(
      dependencyKey
    );
    if (config == null) {
      return;
    }
    Circuit_Breaker_State__c state = CircuitBreakerStateStore.lockOrProvision(
      dependencyKey
    );
    if (applyFailure(state, config, count)) {
      update as system state;
    }
  }

  // Applies `incBy` failures to a locked/new state row, returning true when the row
  // changed and must be persisted. A closed breaker resets its window first, then
  // counts up and trips Open at the threshold; a half-open probe failure re-opens; an
  // already-open breaker is left as-is (its open timer is not disturbed).
  private static Boolean applyFailure(
    Circuit_Breaker_State__c state,
    Circuit_Breaker_Config__mdt config,
    Integer incBy
  ) {
    Datetime now = Datetime.now();
    if (state.Status__c == CircuitBreakerStateStore.STATUS_OPEN) {
      return false;
    }
    if (state.Status__c == CircuitBreakerStateStore.STATUS_HALF_OPEN) {
      // A trial probe failed: the dependency is still unhealthy — re-open.
      openBreaker(state, now);
      return true;
    }
    // Closed: reset the rolling window if it elapsed, then count up.
    if (
      state.Window_Started_At__c == null ||
      CircuitBreakerStateStore.windowElapsed(state, config, now)
    ) {
      state.Failure_Count__c = 0;
      state.Window_Started_At__c = now;
    }
    state.Failure_Count__c =
      CircuitBreakerStateStore.intOf(state.Failure_Count__c) + incBy;
    if (state.Failure_Count__c >= config.Failure_Threshold__c.intValue()) {
      openBreaker(state, now);
    }
    return true;
  }

  // Trips the breaker Open (from Closed at threshold, or re-open from a failed probe).
  private static void openBreaker(
    Circuit_Breaker_State__c state,
    Datetime now
  ) {
    state.Status__c = CircuitBreakerStateStore.STATUS_OPEN;
    state.Opened_At__c = now;
    state.Half_Open_Probes_Admitted__c = 0;
  }

  /**
   * @description Records a success against a dependency's breaker. A half-open probe
   * success closes the breaker (resetting the failure count and window) — 1 DML on
   * that closing transition. A closed breaker (or a dependency with no state row) is
   * a no-op (0 DML). An unconfigured dependency is a no-op (0 SOQL/0 DML).
   * @param dependencyKey The dependency key whose success to record.
   */
  public static void recordSuccess(String dependencyKey) {
    if (CircuitBreakerGate.getConfig(dependencyKey) == null) {
      return;
    }
    List<Circuit_Breaker_State__c> rows = CircuitBreakerStateStore.lockExisting(
      dependencyKey
    );
    if (rows.isEmpty()) {
      return;
    }
    Circuit_Breaker_State__c state = rows[0];
    if (state.Status__c != CircuitBreakerStateStore.STATUS_HALF_OPEN) {
      // Closed steady state (or a stray success while Open) changes nothing.
      return;
    }
    // A trial probe succeeded: the dependency has healed — close the breaker.
    state.Status__c = CircuitBreakerStateStore.STATUS_CLOSED;
    state.Failure_Count__c = 0;
    state.Window_Started_At__c = Datetime.now();
    state.Half_Open_Probes_Admitted__c = 0;
    update as system state;
  }
}
