/**
 * Test-only fault injection for the WorkflowTestHarness. Registers per-step fault
 * configurations (permanent, once, or N-times) in WorkflowEngine.injectedFaults,
 * keyed by root instance + step, and clears the ones this run owns. Instance-bound
 * to a WorkflowHarnessContext so the registration helpers stay concise.
 */
@IsTest
public inherited sharing class WorkflowHarnessFaults {
  private final WorkflowHarnessContext ctx;

  /**
   * @description Binds this fault registrar to the harness context whose root
   * instance id scopes and namespaces the injected fault keys.
   * @param ctx The harness context owning the workflow run these faults apply to.
   */
  public WorkflowHarnessFaults(WorkflowHarnessContext ctx) {
    this.ctx = ctx;
  }

  /**
   * @description Registers a permanent fault that makes the named step fail with the
   * given message on every attempt until removed.
   * @param stepName The fully-qualified step name to fault.
   * @param message The failure message the injected fault raises.
   */
  public void registerFault(String stepName, String message) {
    requireAndPut(stepName, new WorkflowEngine.FaultConfig(message, null));
  }

  /**
   * @description Registers a one-shot fault that makes the named step fail with the
   * given message on its next attempt only, then lets it proceed normally.
   * @param stepName The fully-qualified step name to fault once.
   * @param message The failure message the injected fault raises.
   */
  public void registerFaultOnce(String stepName, String message) {
    requireAndPut(stepName, new WorkflowEngine.FaultConfig(message, 1));
  }

  /**
   * @description Registers a fault that makes the named step fail with the given
   * message for a bounded number of attempts before succeeding.
   * @param stepName The fully-qualified step name to fault.
   * @param message The failure message the injected fault raises.
   * @param failCount The number of attempts to fail; must be greater than 0.
   */
  public void registerFault(
    String stepName,
    String message,
    Integer failCount
  ) {
    WorkflowHarnessContext.requireStep(stepName);
    if (failCount == null || failCount <= 0) {
      throw new WorkflowTestHarness.HarnessException(
        'failCount must be greater than 0.'
      );
    }
    ensureFaultMap();
    WorkflowEngine.injectedFaults.put(
      faultKey(stepName),
      new WorkflowEngine.FaultConfig(message, failCount)
    );
  }

  /**
   * @description Clears every injected fault owned by this run, i.e. all fault keys
   * prefixed with this context's root instance id, leaving other runs' faults intact.
   */
  public void removeFaults() {
    if (WorkflowEngine.injectedFaults == null) {
      return;
    }
    String prefix = ctx.rootInstanceId + ':';
    List<String> keysToRemove = new List<String>();
    for (String key : WorkflowEngine.injectedFaults.keySet()) {
      if (key.startsWith(prefix)) {
        keysToRemove.add(key);
      }
    }
    for (String key : keysToRemove) {
      WorkflowEngine.injectedFaults.remove(key);
    }
  }

  private void requireAndPut(String stepName, WorkflowEngine.FaultConfig cfg) {
    WorkflowHarnessContext.requireStep(stepName);
    ensureFaultMap();
    WorkflowEngine.injectedFaults.put(faultKey(stepName), cfg);
  }

  private String faultKey(String stepName) {
    return ctx.rootInstanceId + ':' + stepName.toLowerCase();
  }

  private void ensureFaultMap() {
    if (WorkflowEngine.injectedFaults == null) {
      WorkflowEngine.injectedFaults = new Map<String, WorkflowEngine.FaultConfig>();
    }
  }
}
