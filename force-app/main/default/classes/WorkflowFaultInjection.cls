/**
 * @description Test-only fault-injection subsystem for the Revenant engine. Holds
 * the armed fault configurations and the child-to-parent instance registry used
 * to resolve a run's root instance, and decides whether a step execution should
 * be diverted into an injected failure or retry while a test is running. In
 * production the armed-fault map is empty, so {@link #checkAndInjectFault} is a
 * no-op. Extracted from `WorkflowEngine`; the engine's start/signal and
 * compensation paths call the public entry points here. All SOQL runs in system
 * mode.
 */
public inherited sharing class WorkflowFaultInjection {
  /**
   * @description Armed injected faults keyed by root-instance:step-name. Written
   * by the test harness (`WorkflowHarnessFaults`) and consumed as faults fire.
   */
  @TestVisible
  private static Map<String, FaultConfig> injectedFaults = new Map<String, FaultConfig>();

  /**
   * @description In-memory child-to-parent instance registry used to walk to a
   * run's root instance when resolving injected-fault keys across child hops.
   */
  @TestVisible
  private static Map<Id, Id> childToParentMap = new Map<Id, Id>();

  /**
   * @description Configuration for a single armed injected fault: the failure
   * message and how many times it should still fire.
   */
  @TestVisible
  private class FaultConfig {
    /** @description Failure message thrown when the fault fires. */
    public String message;
    /** @description Times the fault should still fire, or null for every run. */
    public Integer remainingFailures;
    /**
     * @description Builds a fault-injection entry for a keyed step.
     * @param message failure message thrown when the fault fires
     * @param remainingFailures number of times the fault should still fire, or
     * null to fail on every execution
     */
    public FaultConfig(String message, Integer remainingFailures) {
      this.message = message;
      this.remainingFailures = remainingFailures;
    }
  }

  /**
   * @description Reports whether any injected faults are currently armed. Lets
   * the engine's production guards short-circuit without reading the internal
   * fault map directly.
   * @return true when at least one injected fault is armed
   */
  public static Boolean hasArmedFaults() {
    return injectedFaults != null && !injectedFaults.isEmpty();
  }

  /**
   * @description Reports whether an injected fault is armed for the given key.
   * @param key the root-instance:step-name fault key to test
   * @return true when a fault is armed for the key
   */
  public static Boolean hasFaultForKey(String key) {
    return injectedFaults.containsKey(key);
  }

  /**
   * @description Records a child-to-parent instance relationship used to resolve
   * a run's root instance when matching injected-fault keys.
   * @param childId the child instance id
   * @param parentId the parent instance id
   */
  public static void registerChildParent(Id childId, Id parentId) {
    if (childId != null && parentId != null) {
      childToParentMap.put(childId, parentId);
    }
  }

  /**
   * @description Resolves the root instance id for the given instance by walking
   * the child-to-parent registry (falling back to a per-hop query), bounded to
   * ten hops.
   * @param instanceId the instance whose root to resolve
   * @return the resolved root instance id, or null when the input is null
   */
  public static Id getRootInstanceId(Id instanceId) {
    if (instanceId == null) {
      return null;
    }
    Id currentId = instanceId;
    for (Integer i = 0; i < 10; i++) {
      if (childToParentMap.containsKey(currentId)) {
        currentId = childToParentMap.get(currentId);
      } else {
        // Fallback: Query parent from DB to resolve root across hops/transactions
        Id parentId = queryParentInstanceId(currentId);
        if (parentId != null) {
          childToParentMap.put(currentId, parentId);
          currentId = parentId;
        } else {
          break;
        }
      }
    }
    return currentId;
  }

  /**
   * @description Resolves the direct parent instance id for a single hop of the
   * root-instance parent-chain walk in {@link getRootInstanceId}.
   * <p><b>Intentional per-iteration SOQL.</b> This runs exactly one SOQL query
   * per hop of a sequential parent-chain graph walk: each hop's parent id is
   * only knowable after the prior hop's row is read, so the walk cannot be
   * bulkified into a single query. It is governor-safe because the caller caps
   * the walk at a <b>10-hop bound</b> (the {@code for (i &lt; 10)} loop),
   * limiting this to at most 10 queries per invocation.
   * @param currentId the instance whose parent id to resolve
   * @return the parent instance id, or null when the row is missing or has no
   *         parent (signalling the caller to stop walking)
   */
  private static Id queryParentInstanceId(Id currentId) {
    List<Workflow_Instance__c> insts = [
      SELECT Parent_Instance__c
      FROM Workflow_Instance__c
      WHERE Id = :currentId
      WITH SYSTEM_MODE
      LIMIT 1
    ];
    if (!insts.isEmpty() && insts[0].Parent_Instance__c != null) {
      return insts[0].Parent_Instance__c;
    }
    return null;
  }

  /**
   * @description Consumes one injected-fault occurrence for the key and reports
   * whether this invocation should fail. A null remainingFailures fails every
   * time; a positive count is decremented (and the fault removed when it reaches
   * zero); a zero/negative count does not fail.
   * @param config the fault configuration (mutated when it has a finite count)
   * @param key the injected-fault map key, removed when the count is exhausted
   * @return true when this invocation should inject the fault
   */
  private static Boolean consumeFaultShouldFail(
    FaultConfig config,
    String key
  ) {
    if (config.remainingFailures == null) {
      return true;
    }
    if (config.remainingFailures > 0) {
      config.remainingFailures--;
      if (config.remainingFailures == 0) {
        injectedFaults.remove(key);
      }
      return true;
    }
    return false;
  }

  /**
   * @description Builds the injected-fault outcome: a retry when the step is
   * RetryConfigurable with a policy, otherwise a thrown WorkflowException
   * carrying the fault message.
   * @param stepInstance the step being executed
   * @param config the fault configuration supplying the failure message
   * @return a retry StepResult when a retry policy applies
   */
  private static StepResult faultResult(
    WorkflowStep stepInstance,
    FaultConfig config
  ) {
    if (stepInstance instanceof RetryConfigurable) {
      RetryPolicy policy = ((RetryConfigurable) stepInstance).getRetryPolicy();
      if (policy != null) {
        return StepResult.retry(policy);
      }
    }
    throw new WorkflowEngine.WorkflowException(config.message);
  }

  /**
   * @description Returns an injected fault result for the step when test fault
   * injection is armed for its root-instance:step-name key, or null to run the
   * step normally.
   * @param instanceId the running instance id
   * @param stepName the step name being executed
   * @param stepInstance the step being executed
   * @return the injected StepResult, or null when no fault applies
   */
  public static StepResult checkAndInjectFault(
    Id instanceId,
    String stepName,
    WorkflowStep stepInstance
  ) {
    if (
      !(Test.isRunningTest() &&
      injectedFaults != null &&
      !injectedFaults.isEmpty() &&
      String.isNotBlank(stepName))
    ) {
      return null;
    }
    Id rootId = getRootInstanceId(instanceId);
    String key =
      (rootId != null ? String.valueOf(rootId) : '') +
      ':' +
      stepName.toLowerCase();
    FaultConfig config = injectedFaults.get(key);
    if (config == null) {
      return null;
    }
    if (!consumeFaultShouldFail(config, key)) {
      return null;
    }
    return faultResult(stepInstance, config);
  }
}
