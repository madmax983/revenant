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

  /**
   * @description Seeds the per-run state with the root workflow instance being driven.
   * @param instanceId The Id of the root workflow instance.
   */
  public WorkflowHarnessContext(Id instanceId) {
    this.rootInstanceId = instanceId;
    this.knownInstanceIds = new Set<Id>{ instanceId };
  }

  /**
   * @description Validates test context and a non-null instance Id, then builds the context.
   * @param instanceId The Id of the root workflow instance to drive.
   * @return A context seeded with the given instance.
   */
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

  /**
   * @description Guards that a step name was supplied, throwing a HarnessException when blank.
   * @param stepName The step name that must be non-blank.
   */
  public static void requireStep(String stepName) {
    if (String.isBlank(stepName)) {
      throw new WorkflowTestHarness.HarnessException('stepName is required.');
    }
  }

  /**
   * @description Guards that the hop budget is a positive number, throwing a HarnessException otherwise.
   * @param maxHops The maximum hop count that must be greater than zero.
   */
  public static void requirePositiveHops(Integer maxHops) {
    if (maxHops == null || maxHops <= 0) {
      throw new WorkflowTestHarness.HarnessException(
        'maxHops must be a positive number.'
      );
    }
  }
}
