/**
 * Test-only fault injection for the WorkflowTestHarness. Registers per-step fault
 * configurations (permanent, once, or N-times) in WorkflowEngine.injectedFaults,
 * keyed by root instance + step, and clears the ones this run owns. Instance-bound
 * to a WorkflowHarnessContext so the registration helpers stay concise.
 */
@IsTest
public inherited sharing class WorkflowHarnessFaults {
  private final WorkflowHarnessContext ctx;

  public WorkflowHarnessFaults(WorkflowHarnessContext ctx) {
    this.ctx = ctx;
  }

  public void registerFault(String stepName, String message) {
    requireAndPut(stepName, new WorkflowEngine.FaultConfig(message, null));
  }

  public void registerFaultOnce(String stepName, String message) {
    requireAndPut(stepName, new WorkflowEngine.FaultConfig(message, 1));
  }

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
