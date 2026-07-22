/**
 * CircuitBreakerStateStore — the durable-state access layer shared by the circuit
 * breaker's admission gate and its failure/success recorder (issue #128), lifted
 * out so neither `CircuitBreakerGate` (admission) nor `CircuitBreakerReleaseProcessor`
 * (recording) carries the whole class-level complexity of the breaker, mirroring how
 * `ConcurrencyReconciler`/`ConcurrencyReleaseProcessor` sit beside `ConcurrencyGate`.
 *
 * It owns the `Circuit_Breaker_State__c` row's locking discipline: every mutation
 * happens under `SELECT ... FOR UPDATE WITH SYSTEM_MODE` so the many instances that
 * hit one hot dependency-key row in the same window are serialized and the breaker's
 * transitions are effectively-once, plus the lazy first-failure provisioning with
 * DUPLICATE_VALUE race recovery (copied from `ConcurrencyGate.lockOrProvision`). The
 * shared window/duration math and the breaker status constants live here too.
 */
public inherited sharing class CircuitBreakerStateStore {
  /** @description Durable breaker status (healthy, admit normally). */
  public static final String STATUS_CLOSED = 'Closed';
  /** @description Durable breaker status (tripped, fast-fail/park). */
  public static final String STATUS_OPEN = 'Open';
  /** @description Durable breaker status (admit bounded trial probes). */
  public static final String STATUS_HALF_OPEN = 'HalfOpen';

  // Test-only hook forcing the lazy-provision insert to lose the unique-key race so
  // the DUPLICATE_VALUE recovery path is exercised (mirrors ConcurrencyGate).
  @TestVisible
  private static Boolean simulateDuplicateOnInsert = false;

  /**
   * @description Locks the existing state row for a dependency key (empty list =
   * none yet). Honors the test hook that simulates a lost provision race by
   * returning no row. No provisioning — the admission and success paths admit/no-op
   * when there is no row.
   * @param dependencyKey The dependency key whose state row to lock.
   * @return The locked row in a single-element list, or an empty list when none exists.
   */
  public static List<Circuit_Breaker_State__c> lockExisting(
    String dependencyKey
  ) {
    if (Test.isRunningTest() && simulateDuplicateOnInsert) {
      return new List<Circuit_Breaker_State__c>();
    }
    return querySelectForUpdate(dependencyKey);
  }

  /**
   * @description Locks the dependency key's state row, lazily provisioning a Closed
   * row on first failure. Mirrors ConcurrencyGate's duplicate-insert race recovery:
   * a concurrent first-use insert that loses the unique-key race is caught and the
   * winner's row re-locked; any other DML error (e.g. an invalid/over-long key) is
   * rethrown so the caller can isolate it.
   * @param dependencyKey The dependency key whose state row to lock or provision.
   * @return The locked (existing or freshly provisioned) state row.
   */
  public static Circuit_Breaker_State__c lockOrProvision(String dependencyKey) {
    List<Circuit_Breaker_State__c> rows = lockExisting(dependencyKey);
    if (!rows.isEmpty()) {
      return rows[0];
    }
    Circuit_Breaker_State__c state = new Circuit_Breaker_State__c(
      Dependency_Key__c = dependencyKey,
      Status__c = STATUS_CLOSED,
      Failure_Count__c = 0,
      Half_Open_Probes_Admitted__c = 0
    );
    try {
      insert as system state;
      return state;
    } catch (DmlException e) {
      return recoverProvisionRace(e, dependencyKey);
    }
  }

  // Recovers from a concurrent first-use insert that lost the unique-key race.
  private static Circuit_Breaker_State__c recoverProvisionRace(
    DmlException e,
    String dependencyKey
  ) {
    Boolean isDuplicate = e.getMessage().contains('DUPLICATE_VALUE');
    for (Integer i = 0; !isDuplicate && i < e.getNumDml(); i++) {
      if (e.getDmlType(i) == StatusCode.DUPLICATE_VALUE) {
        isDuplicate = true;
      }
    }
    if (!isDuplicate) {
      throw e;
    }
    List<Circuit_Breaker_State__c> existing = querySelectForUpdate(
      dependencyKey
    );
    if (existing.isEmpty()) {
      throw e;
    }
    return existing[0];
  }

  private static List<Circuit_Breaker_State__c> querySelectForUpdate(
    String dependencyKey
  ) {
    return [
      SELECT
        Status__c,
        Failure_Count__c,
        Window_Started_At__c,
        Opened_At__c,
        Half_Open_Probes_Admitted__c
      FROM Circuit_Breaker_State__c
      WHERE Dependency_Key__c = :dependencyKey
      WITH SYSTEM_MODE
      FOR UPDATE
    ];
  }

  /**
   * @description True when a Closed breaker's rolling failure window has elapsed and
   * should reset.
   * @param state The state row.
   * @param config The breaker config supplying the window length.
   * @param now The evaluation instant.
   * @return True when the window has elapsed.
   */
  public static Boolean windowElapsed(
    Circuit_Breaker_State__c state,
    Circuit_Breaker_Config__mdt config,
    Datetime now
  ) {
    if (state.Window_Started_At__c == null) {
      return false;
    }
    Long elapsedMs = now.getTime() - state.Window_Started_At__c.getTime();
    return elapsedMs > config.Rolling_Window_Seconds__c.longValue() * 1000;
  }

  /**
   * @description True when an Open breaker's configured open duration has elapsed
   * (eligible for the Half-Open transition). A null `Opened_At__c` is treated as
   * eligible.
   * @param openedAt When the breaker last opened.
   * @param config The breaker config supplying the open duration.
   * @param now The evaluation instant.
   * @return True when the open duration has elapsed.
   */
  public static Boolean openDurationElapsed(
    Datetime openedAt,
    Circuit_Breaker_Config__mdt config,
    Datetime now
  ) {
    if (openedAt == null) {
      return true;
    }
    Long elapsedMs = now.getTime() - openedAt.getTime();
    return elapsedMs >= config.Open_Duration_Seconds__c.longValue() * 1000;
  }

  /**
   * @description Null-safe Decimal-to-Integer coercion for the numeric state counters.
   * @param value The counter value (may be null).
   * @return The integer value, or 0 when null.
   */
  public static Integer intOf(Decimal value) {
    return value == null ? 0 : value.intValue();
  }
}
