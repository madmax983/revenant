/**
 * CircuitBreakerGate — the public facade + admission gate of the durable, crash-safe
 * circuit breaker that fast-fails a fleet of guarded steps when a shared external
 * dependency is unhealthy, and auto-recovers once it heals (issue #128).
 *
 * A `WorkflowStep` opts in by implementing `CircuitBreakerGuarded` and naming the
 * dependency it calls. The breaker for that dependency is declared per key in a
 * `Circuit_Breaker_Config__mdt` record — resolved (via `CircuitBreakerConfigResolver`)
 * by the same DeveloperName convention as `Concurrency_Config__mdt` (non-alphanumeric
 * chars -> '_', truncated to 40), with a `Default` fallback. A dependency key with no
 * matching record (and no Default) has NO breaker: `tryAdmit` admits unconditionally
 * with zero SOQL and zero DML, so the unguarded/unconfigured hot path is free.
 *
 * Durable state lives in one `Circuit_Breaker_State__c` row per dependency key,
 * mutated under `SELECT ... FOR UPDATE` (via `CircuitBreakerStateStore`) so the many
 * instances hitting one hot dependency-key row in the same window are serialized and
 * the Closed -> Open -> HalfOpen -> Closed transitions are effectively-once — the same
 * locking discipline as `ConcurrencyGate`. Failure/success recording lives on
 * `CircuitBreakerReleaseProcessor` and the watchdog half-open sweep on
 * `CircuitBreakerReconciler`; this class stays the thin admission gate + delegating
 * facade to keep every collaborator below the class-level complexity thresholds
 * (mirroring the `ConcurrencyGate` decomposition).
 *
 * The breaker is keyed on dependency HEALTH, orthogonal to `ConcurrencyGate` (an
 * in-flight ceiling per workflow), `RateLimiter` (a token bucket per integration key)
 * and `RetryPolicy` (per-step backoff). It shares no state with the append-only step
 * audit trail or the compensation stack.
 */
public inherited sharing class CircuitBreakerGate {
  // Test-only config injection (mirrors ConcurrencyGate.mockConfigs / RateLimiter).
  // Read by getConfig (below) and threaded to the resolver/reconciler.
  @TestVisible
  private static Map<String, Circuit_Breaker_Config__mdt> mockConfigs = new Map<String, Circuit_Breaker_Config__mdt>();

  /**
   * @description Outcome of an admission attempt against the breaker: whether the
   * guarded step may proceed and, when it may, whether it does so as a trial probe
   * against a half-open breaker.
   */
  public class BreakerDecision {
    /** @description True if the guarded step may proceed (breaker closed, half-open probe, or unconfigured). */
    public Boolean admitted { get; private set; }
    /** @description True only when admission consumed a half-open trial probe. */
    public Boolean isProbe { get; private set; }

    // Constructed only through the intent-named factories on the enclosing class so
    // the two outcome flags can never be passed in a confusing/mismatched order.
    // The factories live on the top-level class because Apex forbids static members
    // on inner classes.
    private BreakerDecision() {
      this.admitted = false;
      this.isProbe = false;
    }
  }

  // Intent-named BreakerDecision factories. Declared on the top-level class (Apex
  // forbids static members on inner classes) and used only internally.

  // Admitted because the dependency has no breaker configured — no state touched.
  private static BreakerDecision unconfigured() {
    BreakerDecision d = new BreakerDecision();
    d.admitted = true;
    d.isProbe = false;
    return d;
  }

  // Admitted against a closed (healthy) breaker.
  private static BreakerDecision admittedClosed() {
    BreakerDecision d = new BreakerDecision();
    d.admitted = true;
    d.isProbe = false;
    return d;
  }

  // Admitted as a trial probe against a half-open breaker.
  private static BreakerDecision admittedProbe() {
    BreakerDecision d = new BreakerDecision();
    d.admitted = true;
    d.isProbe = true;
    return d;
  }

  // Rejected because the breaker is open (or half-open with its probe budget spent).
  private static BreakerDecision rejectedOpen() {
    BreakerDecision d = new BreakerDecision();
    d.admitted = false;
    d.isProbe = false;
    return d;
  }

  /**
   * @description Resolves the breaker config for a dependency key, or null when the
   * dependency has no breaker (no specific record and no Default, or a misconfigured
   * record). Governor-free (CMDT getAll), cached per transaction.
   * @param dependencyKey The dependency key to resolve a breaker config for.
   * @return The matched valid config record, or null when the dependency is unconfigured.
   */
  public static Circuit_Breaker_Config__mdt getConfig(String dependencyKey) {
    return CircuitBreakerConfigResolver.getConfig(dependencyKey, mockConfigs);
  }

  /**
   * @description True when the dependency key has a circuit breaker configured.
   * Governor-free (no SOQL), so the admission hook can cheaply short-circuit.
   * @param dependencyKey The dependency key to check.
   * @return True if a valid breaker config resolves, otherwise false.
   */
  public static Boolean isConfigured(String dependencyKey) {
    return getConfig(dependencyKey) != null;
  }

  /**
   * @description Resolves the dependency key a step's breaker is guarding, or null
   * when the step is not `CircuitBreakerGuarded` (or supplies a blank key). Used by
   * the failure/success sinks, which do not hold the resolved step instance. Type
   * resolution is governor-free (no SOQL/DML), so an unguarded completed step costs
   * nothing here.
   * @param workflowName The instance's workflow definition name (for namespace resolution).
   * @param stepName The completed/failed step's class name.
   * @return The non-blank dependency key, or null when the step is not breaker-guarded.
   */
  public static String dependencyKeyIfGuarded(
    String workflowName,
    String stepName
  ) {
    if (String.isBlank(stepName)) {
      return null;
    }
    Type stepType = WorkflowTypeResolver.resolve(
      stepName,
      WorkflowTypeResolver.extractNamespace(workflowName)
    );
    if (stepType == null) {
      return null;
    }
    Object stepInstance = stepType.newInstance();
    if (!(stepInstance instanceof CircuitBreakerGuarded)) {
      return null;
    }
    String depKey = ((CircuitBreakerGuarded) stepInstance).dependencyKey();
    return String.isNotBlank(depKey) ? depKey : null;
  }

  /**
   * @description Records a failure against the breaker guarding the given step, if
   * any. A no-op (0 SOQL/0 DML) when the step is not `CircuitBreakerGuarded` or its
   * dependency is unconfigured — so the unguarded failure sink pays nothing. Called
   * from the retry/exhausted/explicit-fail outcome sinks.
   * @param workflowName The instance's workflow definition name (for namespace resolution).
   * @param stepName The failed step's class name.
   */
  public static void recordFailureForStep(
    String workflowName,
    String stepName
  ) {
    String depKey = dependencyKeyIfGuarded(workflowName, stepName);
    if (depKey != null) {
      recordFailure(depKey);
    }
  }

  /**
   * @description Records a success against the breaker guarding the given step, if
   * any (closing a half-open probe). A no-op (0 SOQL/0 DML) when the step is not
   * `CircuitBreakerGuarded` or its dependency is unconfigured. Called from the
   * step-complete sink.
   * @param workflowName The instance's workflow definition name (for namespace resolution).
   * @param stepName The completed step's class name.
   */
  public static void recordSuccessForStep(
    String workflowName,
    String stepName
  ) {
    String depKey = dependencyKeyIfGuarded(workflowName, stepName);
    if (depKey != null) {
      recordSuccess(depKey);
    }
  }

  /**
   * @description Attempts to admit a guarded step through the breaker for a
   * dependency key. Unconfigured -> admit (0 SOQL/0 DML). Otherwise locks the durable
   * state row (if any) `FOR UPDATE` and applies the state machine: a closed (or
   * never-failed) breaker admits; an open breaker rejects unless its open duration
   * has elapsed, in which case it auto-transitions to half-open and admits the first
   * probe; a half-open breaker admits probes up to its budget then rejects. State is
   * written only when the transition changes something (a pure closed read costs 0
   * DML, mirroring RateLimiter's steady-state skip).
   * @param dependencyKey The dependency key whose breaker to consult.
   * @return A BreakerDecision indicating whether to proceed and whether as a probe.
   */
  public static BreakerDecision tryAdmit(String dependencyKey) {
    Circuit_Breaker_Config__mdt config = getConfig(dependencyKey);
    if (config == null) {
      return unconfigured();
    }
    List<Circuit_Breaker_State__c> rows = CircuitBreakerStateStore.lockExisting(
      dependencyKey
    );
    if (rows.isEmpty()) {
      // Healthy dependency, no row yet: admit closed with no DML. The row is only
      // provisioned once failures start accumulating (recordFailure).
      return admittedClosed();
    }
    return applyAdmission(rows[0], config);
  }

  // Applies the breaker state machine to a locked existing row, writing only on a
  // real transition.
  private static BreakerDecision applyAdmission(
    Circuit_Breaker_State__c state,
    Circuit_Breaker_Config__mdt config
  ) {
    Datetime now = Datetime.now();
    if (state.Status__c == CircuitBreakerStateStore.STATUS_OPEN) {
      return admitOpen(state, config, now);
    }
    if (state.Status__c == CircuitBreakerStateStore.STATUS_HALF_OPEN) {
      return admitHalfOpen(state, config);
    }
    return admitClosed(state, config, now);
  }

  // Closed admission: reset the rolling window if it has elapsed (the only write on
  // this path), then admit.
  private static BreakerDecision admitClosed(
    Circuit_Breaker_State__c state,
    Circuit_Breaker_Config__mdt config,
    Datetime now
  ) {
    if (CircuitBreakerStateStore.windowElapsed(state, config, now)) {
      state.Failure_Count__c = 0;
      state.Window_Started_At__c = now;
      update as system state;
    }
    return admittedClosed();
  }

  // Open admission: auto-transition to half-open once the open duration has elapsed
  // (admitting the first probe), otherwise reject.
  private static BreakerDecision admitOpen(
    Circuit_Breaker_State__c state,
    Circuit_Breaker_Config__mdt config,
    Datetime now
  ) {
    if (
      !CircuitBreakerStateStore.openDurationElapsed(
        state.Opened_At__c,
        config,
        now
      )
    ) {
      return rejectedOpen();
    }
    state.Status__c = CircuitBreakerStateStore.STATUS_HALF_OPEN;
    state.Half_Open_Probes_Admitted__c = 1;
    update as system state;
    return admittedProbe();
  }

  // Half-open admission: admit a probe while the probe budget is unspent, else reject.
  private static BreakerDecision admitHalfOpen(
    Circuit_Breaker_State__c state,
    Circuit_Breaker_Config__mdt config
  ) {
    Integer admittedProbes = CircuitBreakerStateStore.intOf(
      state.Half_Open_Probes_Admitted__c
    );
    if (admittedProbes >= config.Half_Open_Probe_Count__c.intValue()) {
      return rejectedOpen();
    }
    state.Half_Open_Probes_Admitted__c = admittedProbes + 1;
    update as system state;
    return admittedProbe();
  }

  /**
   * @description Seconds remaining until an open breaker becomes eligible for
   * Half-Open (its `Opened_At__c` plus the configured open duration), floored at 1.
   * Used by the admission park path to sleep a fast-failed step exactly until the
   * breaker is due to admit trial probes. Returns null when it cannot be determined
   * (unconfigured, no state row, or not currently Open) so the caller can apply a
   * sane default. A non-locking read — it only computes a wake time.
   * @param dependencyKey The dependency key whose open breaker to measure.
   * @return Seconds until Half-Open (minimum 1), or null when indeterminate.
   */
  public static Integer secondsUntilHalfOpen(String dependencyKey) {
    Circuit_Breaker_Config__mdt config = getConfig(dependencyKey);
    if (config == null) {
      return null;
    }
    List<Circuit_Breaker_State__c> rows = [
      SELECT Status__c, Opened_At__c
      FROM Circuit_Breaker_State__c
      WHERE Dependency_Key__c = :dependencyKey
      WITH SYSTEM_MODE
    ];
    if (
      rows.isEmpty() ||
      rows[0].Status__c != CircuitBreakerStateStore.STATUS_OPEN ||
      rows[0].Opened_At__c == null
    ) {
      return null;
    }
    Long readyMs =
      rows[0].Opened_At__c.getTime() +
      config.Open_Duration_Seconds__c.longValue() * 1000;
    Integer remainingSecs = (Integer) Math.ceil(
      (readyMs - Datetime.now().getTime()) / 1000.0
    );
    return remainingSecs > 0 ? remainingSecs : 1;
  }

  /**
   * @description Records a single failure against a dependency's breaker (delegated
   * to CircuitBreakerReleaseProcessor). No-op for an unconfigured dependency.
   * @param dependencyKey The dependency key whose failure to record.
   */
  public static void recordFailure(String dependencyKey) {
    CircuitBreakerReleaseProcessor.recordFailureBulk(
      new Map<String, Integer>{ dependencyKey => 1 }
    );
  }

  /**
   * @description Bulk failure recording keyed by dependency to a failure count
   * (delegated to CircuitBreakerReleaseProcessor), with per-key isolation so one bad
   * key cannot sink valid siblings.
   * @param failuresByKey Map of dependency key to the number of failures to record.
   */
  public static void recordFailureBulk(Map<String, Integer> failuresByKey) {
    CircuitBreakerReleaseProcessor.recordFailureBulk(failuresByKey);
  }

  /**
   * @description Records a success against a dependency's breaker (delegated to
   * CircuitBreakerReleaseProcessor): a half-open probe success closes the breaker;
   * a closed/unconfigured dependency is a no-op.
   * @param dependencyKey The dependency key whose success to record.
   */
  public static void recordSuccess(String dependencyKey) {
    CircuitBreakerReleaseProcessor.recordSuccess(dependencyKey);
  }

  /**
   * @description Watchdog reconcile (delegated to CircuitBreakerReconciler): flips
   * every eligible Open breaker whose open duration has elapsed to Half-Open, so
   * recovery lands within one heartbeat cadence even for a zero-traffic dependency.
   */
  public static void sweepHalfOpen() {
    CircuitBreakerReconciler.sweepHalfOpen(mockConfigs);
  }
}
