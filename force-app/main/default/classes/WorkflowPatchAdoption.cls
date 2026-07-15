/**
 * @description Patch-adoption reporting for the Revenant engine. Counts the
 * non-terminal `Workflow_Instance__c` runs still pinned to the legacy branch of a
 * given patch/change id &mdash; either because a step recorded an explicit
 * `false` decision under the patch key or because the run predates the patch's
 * introduction date. The scan is read-only (zero DML) and chunks its SOQL to stay
 * under governor limits on large data volumes. Extracted from `WorkflowEngine`;
 * all SOQL executes in system mode so the report is complete regardless of the
 * invoking user's object permissions. The per-chunk step-execution scan lives on
 * {@link WorkflowPatchAdoptionScan} so each cohesive phase stays within its own
 * complexity budget; offloaded capture payloads are rehydrated through
 * {@link WorkflowPayloadOffload}.
 */
public inherited sharing class WorkflowPatchAdoption {
  /**
   * @description Maximum active-instance rows scanned per adoption count. When the
   * active population reaches this cap the count is refused as unreliable.
   */
  @TestVisible
  private static Integer adoptionQueryLimit = 45000;

  /**
   * @description Test-only override for the active-instance population, letting
   * unit tests exercise the scan without inserting records.
   */
  @TestVisible
  private static List<Workflow_Instance__c> mockInstancesForAdoption;

  /**
   * @description Mutable accumulator threaded through the patch-adoption scan
   * helpers (across `WorkflowPatchAdoption` and `WorkflowPatchAdoptionScan`) so
   * each helper stays within the parameter and complexity budgets.
   */
  public class AdoptionScan {
    /** @description The `__patch:<changeId>` captures key being scanned for. */
    public String key;
    /** @description Workflow names observed to record the patch key. */
    public Set<String> targetWorkflows = new Set<String>();
    /** @description Instances that recorded an explicit `false` decision. */
    public Set<Id> instancesWithExplicitFalse = new Set<Id>();
  }

  /**
   * @description Returns the count of non-terminal workflow instances that have
   * recorded a decision of 'false' for the given changeId.
   * @param changeId The unique name of the patch.
   * @return The number of active instances pinning the old branch.
   */
  public static Integer getPatchAdoptionCount(String changeId) {
    return getPatchAdoptionCount(null, changeId, null);
  }

  /**
   * @description Returns the count of non-terminal workflow instances that have
   * recorded a decision of 'false' for the given changeId, using an optional
   * introduction date to count legacy instances that have not yet reached the
   * patch check.
   * @param changeId The unique name of the patch.
   * @param introducedAt Optional DateTime representing when the patch was introduced.
   * @return The number of active instances pinning the old branch.
   */
  public static Integer getPatchAdoptionCount(
    String changeId,
    DateTime introducedAt
  ) {
    return getPatchAdoptionCount(null, changeId, introducedAt);
  }

  /**
   * @description Returns the count of non-terminal workflow instances that have
   * recorded a decision of 'false' for the given changeId, scoped to a specific
   * workflow name and using an optional introduction date.
   * @param workflowName Optional name of the workflow to scope active scans to.
   * @param changeId The unique name of the patch.
   * @param introducedAt Optional DateTime representing when the patch was introduced.
   * @return The number of active instances pinning the old branch.
   */
  public static Integer getPatchAdoptionCount(
    String workflowName,
    String changeId,
    DateTime introducedAt
  ) {
    if (String.isBlank(changeId)) {
      return 0;
    }
    Integer queryLimit = adoptionQueryLimit;

    // 1. Query all active (non-terminal) workflow instances directly
    List<Workflow_Instance__c> instances = queryAdoptionInstances(
      workflowName,
      queryLimit
    );

    if (instances.size() >= queryLimit) {
      throw new WorkflowEngine.WorkflowException(
        'Active instances exceed query limit (' +
          queryLimit +
          ' rows). Adoption count cannot be computed reliably.'
      );
    }

    AdoptionScan scan = new AdoptionScan();
    scan.key = '__patch:' + changeId;
    if (String.isNotBlank(workflowName)) {
      scan.targetWorkflows.add(workflowName);
    }

    // 2. Query step executions in batches of 1,000 instances to stay under 50k SOQL row limits
    WorkflowPatchAdoptionScan.scanInstancesForExplicitFalse(instances, scan);

    // 3. Count instances pinning the legacy branch
    return countPinnedInstances(instances, introducedAt, scan);
  }

  /**
   * @description Queries the active (non-terminal) instance population for the
   * adoption scan, optionally scoped to one workflow name. Honors the test-only
   * {@link WorkflowPatchAdoption#mockInstancesForAdoption} override when running
   * in a test context.
   * @param workflowName optional workflow name to scope the population to
   * @param queryLimit the row cap enforced on the population
   * @return the active instance rows to scan
   */
  private static List<Workflow_Instance__c> queryAdoptionInstances(
    String workflowName,
    Integer queryLimit
  ) {
    if (Test.isRunningTest() && mockInstancesForAdoption != null) {
      return mockInstancesForAdoption;
    }
    if (String.isNotBlank(workflowName)) {
      return [
        SELECT Id, Workflow_Name__c, CreatedDate
        FROM Workflow_Instance__c
        WHERE
          Status__c IN :WorkflowEngine.ACTIVE_STATUSES
          AND Workflow_Name__c = :workflowName
        WITH SYSTEM_MODE
        LIMIT :queryLimit
      ];
    }
    return [
      SELECT Id, Workflow_Name__c, CreatedDate
      FROM Workflow_Instance__c
      WHERE Status__c IN :WorkflowEngine.ACTIVE_STATUSES
      WITH SYSTEM_MODE
      LIMIT :queryLimit
    ];
  }

  /**
   * @description Counts the instances still pinned to the legacy branch: active
   * runs of a target workflow that either predate the patch introduction date or
   * recorded an explicit `false` decision.
   * @param instances the active instance population
   * @param introducedAt optional patch introduction date; legacy runs created
   *        before it count as pinned
   * @param scan the populated scan accumulator
   * @return the number of instances pinning the old branch
   */
  private static Integer countPinnedInstances(
    List<Workflow_Instance__c> instances,
    DateTime introducedAt,
    AdoptionScan scan
  ) {
    Set<Id> instancesWithFalse = new Set<Id>();
    for (Workflow_Instance__c inst : instances) {
      String wflow = inst.Workflow_Name__c;
      if (!scan.targetWorkflows.contains(wflow)) {
        continue;
      }

      if (introducedAt != null && inst.CreatedDate < introducedAt) {
        // Active instance of a target workflow created before patch introduction
        instancesWithFalse.add(inst.Id);
        continue;
      }

      if (scan.instancesWithExplicitFalse.contains(inst.Id)) {
        instancesWithFalse.add(inst.Id);
      }
    }

    return instancesWithFalse.size();
  }
}
