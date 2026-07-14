/**
 * ConcurrencyGate — a durable, crash-safe semaphore that caps the number of
 * simultaneously in-flight instances of a workflow definition (issue #28).
 *
 * A slot is acquired once at admission (the first time an instance is about to
 * execute a step) and released on every terminal transition. The ceiling N is
 * declared per definition in a `Concurrency_Config__mdt` record, resolved by the
 * same DeveloperName convention as `Workflow_Alert_Config__mdt` (non-alphanumeric
 * chars -> '_', truncated to 40), with a `Default` fallback record. A workflow
 * with no matching record (and no Default) is unbounded.
 *
 * The live count lives in a `Concurrency_State__c` counter row, mutated under
 * `SELECT ... FOR UPDATE` so concurrent admissions are serialized and the ceiling
 * is never exceeded — the same locking discipline as `RateLimiter`/`Rate_Limit_State__c`.
 * Admission is a single guarded counter check, never an unbounded SOQL scan.
 *
 * Slot accounting is entirely separate from the append-only step audit trail and
 * the compensation stack.
 */
public inherited sharing class ConcurrencyGate {
  // Test-only config injection (mirrors RateLimiter.mockConfigs / WorkflowAlertManager).
  @TestVisible
  private static Map<String, Concurrency_Config__mdt> mockConfigs = new Map<String, Concurrency_Config__mdt>();

  @TestVisible
  private static Boolean simulateDuplicateOnInsert = false;

  /**
   * @description Outcome of an admission attempt: whether the instance may proceed and
   * whether doing so consumed a real concurrency slot.
   */
  public class AdmissionResult {
    // True if the instance may proceed to execute (either it took a slot, or the
    // workflow is unbounded).
    /** @description True if the instance may proceed to execute. */
    public Boolean admitted { get; private set; }
    // True only when a real slot was consumed (a ceiling is configured). When false
    // and admitted is true, the workflow is unbounded and no counter was touched.
    /** @description True only when a real bounded slot was consumed. */
    public Boolean slotConsumed { get; private set; }

    // Constructed only through the intent-named factories on the enclosing class so
    // the two outcome flags can never be passed in a confusing/mismatched order.
    // The factories live on the top-level class because Apex forbids static members
    // on inner classes.
    private AdmissionResult() {
      this.admitted = false;
      this.slotConsumed = false;
    }
  }

  // Intent-named AdmissionResult factories. Declared on the top-level class (Apex
  // forbids static members on inner classes) and used only internally by tryAcquire.

  // Admitted because the workflow is unbounded — no counter was touched.
  private static AdmissionResult unbounded() {
    AdmissionResult r = new AdmissionResult();
    r.admitted = true;
    r.slotConsumed = false;
    return r;
  }

  // Admitted after consuming a real slot on a bounded workflow.
  private static AdmissionResult acquired() {
    AdmissionResult r = new AdmissionResult();
    r.admitted = true;
    r.slotConsumed = true;
    return r;
  }

  // Rejected — the ceiling is full, no slot consumed.
  private static AdmissionResult rejected() {
    AdmissionResult r = new AdmissionResult();
    r.admitted = false;
    r.slotConsumed = false;
    return r;
  }

  /**
   * @description Resolves the configured ceiling for a workflow definition, or null when
   * the workflow is unbounded (no specific record and no Default). Cached per transaction.
   * @param workflowName The workflow definition name to resolve a ceiling for.
   * @return The configured positive ceiling, or null when the workflow is unbounded.
   */
  public static Integer getCeiling(String workflowName) {
    return ConcurrencyConfigResolver.getCeiling(workflowName, mockConfigs);
  }

  /**
   * @description True when the workflow has a concurrency ceiling configured.
   * @param workflowName The workflow definition name to check.
   * @return True if a ceiling is configured, otherwise false.
   */
  public static Boolean isConfigured(String workflowName) {
    return getCeiling(workflowName) != null;
  }

  /**
   * @description Attempts to acquire a slot for the workflow. For an unbounded workflow
   * this is a no-op that admits without touching any counter. For a bounded workflow it
   * locks the durable counter row and admits (incrementing) only while the live count is
   * below the ceiling.
   * @param workflowName The workflow definition name to admit an instance of.
   * @return An AdmissionResult indicating whether the instance was admitted and whether a
   * slot was consumed.
   */
  public static AdmissionResult tryAcquire(String workflowName) {
    Integer ceiling = getCeiling(workflowName);
    if (ceiling == null) {
      return unbounded();
    }

    Concurrency_State__c state = lockOrProvision(workflowName);
    Integer inFlight = (state.In_Flight_Count__c == null)
      ? 0
      : (Integer) state.In_Flight_Count__c;

    if (inFlight < ceiling) {
      state.In_Flight_Count__c = inFlight + 1;
      update as system state;
      return acquired();
    }
    return rejected();
  }

  /**
   * @description Releases `count` slots for the workflow (floored at zero). No-op when no
   * counter row exists. Used by the terminal-transition release path.
   * @param workflowName The workflow definition name whose slots to release.
   * @param count The number of slots to free.
   */
  public static void release(String workflowName, Integer count) {
    if (String.isBlank(workflowName) || count == null || count <= 0) {
      return;
    }
    releaseBulk(new Map<String, Integer>{ workflowName => count });
  }

  /**
   * @description Bulk release keyed by workflow definition to number of slots to free.
   * Locks each existing counter row once and decrements (floored at zero). Called from the
   * instance trigger so many concurrent terminal transitions decrement correctly.
   * @param countsByWorkflow Map of workflow definition name to the number of slots to free.
   */
  public static void releaseBulk(Map<String, Integer> countsByWorkflow) {
    ConcurrencyReleaseProcessor.releaseBulk(countsByWorkflow);
  }

  /**
   * @description Reconciles the counter for a single workflow to the true number of
   * non-terminal slot-holding instances, reclaiming slots leaked by instances that died
   * without releasing (crash / killed transaction). Heavy enough to live on the watchdog
   * sweep, never on the admission hot path.
   * @param workflowName The workflow definition name whose counter to reconcile.
   */
  public static void reconcile(String workflowName) {
    ConcurrencyReconciler.reconcile(new Set<String>{ workflowName });
  }

  /** Reconciles every existing counter row. Called by the watchdog heartbeat. */
  public static void reconcileAll() {
    ConcurrencyReconciler.reconcile(null);
  }

  /**
   * @description Locks the workflow's counter row, lazily provisioning it on first use.
   * Mirrors RateLimiter's duplicate-insert race recovery: a concurrent first-use insert
   * that loses the unique-key race is caught and the winner's row is re-locked.
   * @param workflowName The workflow definition name whose counter row to lock or provision.
   * @return The locked counter row for the workflow.
   */
  private static Concurrency_State__c lockOrProvision(String workflowName) {
    List<Concurrency_State__c> states = lockExistingState(workflowName);
    if (!states.isEmpty()) {
      return states[0];
    }

    Concurrency_State__c state = new Concurrency_State__c(
      Workflow_Definition__c = workflowName,
      In_Flight_Count__c = 0
    );
    try {
      insert as system state;
      return state;
    } catch (DmlException e) {
      return recoverProvisionRace(e, workflowName);
    }
  }

  // Locks the existing counter row for a workflow (empty list = none yet). Honors the
  // test hook that simulates a lost provision race by returning no row.
  private static List<Concurrency_State__c> lockExistingState(
    String workflowName
  ) {
    if (Test.isRunningTest() && simulateDuplicateOnInsert) {
      return new List<Concurrency_State__c>();
    }
    return [
      SELECT In_Flight_Count__c
      FROM Concurrency_State__c
      WHERE Workflow_Definition__c = :workflowName
      WITH SYSTEM_MODE
      FOR UPDATE
    ];
  }

  // Recovers from a concurrent first-use insert that lost the unique-key race: on a
  // DUPLICATE_VALUE the winner's row is re-locked and returned; any other DML error is
  // rethrown.
  private static Concurrency_State__c recoverProvisionRace(
    DmlException e,
    String workflowName
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
    List<Concurrency_State__c> existing = [
      SELECT In_Flight_Count__c
      FROM Concurrency_State__c
      WHERE Workflow_Definition__c = :workflowName
      WITH SYSTEM_MODE
      FOR UPDATE
    ];
    if (existing.isEmpty()) {
      throw e;
    }
    return existing[0];
  }
}
