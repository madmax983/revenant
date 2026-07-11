/**
 * Mutable per-run state shared across the WorkflowTestHarness collaborator classes.
 * Test-only. Holds the root instance Id, the running hop count, and the caches the
 * harness keeps so the per-hop tree scan stays cheap on SOQL. Also hosts the small
 * argument-validation guards reused by the driving/firing collaborators.
 */
@IsTest
public inherited sharing class WorkflowHarnessContext {
  public final Id rootInstanceId;
  public Integer totalHops = 0;
  // Instances discovered so far (root + spawned children). Cached so the per-hop
  // tree scan stays cheap on SOQL instead of re-walking the whole tree each hop.
  public final Set<Id> knownInstanceIds;
  public final Set<Id> scannedInstanceIds = new Set<Id>();
  public Boolean disableAutoTimeSkip = false;

  public WorkflowHarnessContext(Id instanceId) {
    this.rootInstanceId = instanceId;
    this.knownInstanceIds = new Set<Id>{ instanceId };
  }

  /** Validates test context + a non-null instance Id, then builds the context. */
  public static WorkflowHarnessContext forInstance(Id instanceId) {
    if (!Test.isRunningTest()) {
      throw new WorkflowTestHarness.HarnessException(
        'WorkflowTestHarness is test-context only.'
      );
    }
    if (instanceId == null) {
      throw new WorkflowTestHarness.HarnessException(
        'A workflow instance Id is required.'
      );
    }
    return new WorkflowHarnessContext(instanceId);
  }

  public static void requireStep(String stepName) {
    if (String.isBlank(stepName)) {
      throw new WorkflowTestHarness.HarnessException('stepName is required.');
    }
  }

  public static void requirePositiveHops(Integer maxHops) {
    if (maxHops == null || maxHops <= 0) {
      throw new WorkflowTestHarness.HarnessException(
        'maxHops must be a positive number.'
      );
    }
  }
}
