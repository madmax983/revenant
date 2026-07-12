/**
 * Test-only advanceability logic for the WorkflowTestHarness: decides whether an
 * instance can be driven forward, and provides the shared branch-parsing / latest
 * step-execution lookups used by both the advanceability check and the parallel
 * step runner.
 */
@IsTest
public inherited sharing class WorkflowHarnessAdvancer {
  // Statuses from which the engine can be driven forward by re-invoking runStep.
  private static final Set<String> ACTIVE_STATUSES = new Set<String>{
    'Pending',
    'Running',
    'Compensating',
    'Cancelling'
  };

  /**
   * @description Decides whether the harness can drive the given instance forward by
   * re-invoking runStep, considering active statuses, unrun sibling branches, and
   * deterministic sleep/retry waits eligible for auto time-skip.
   * @param ctx The harness context supplying auto-time-skip configuration.
   * @param inst The workflow instance to evaluate.
   * @return True if the instance can be advanced, otherwise false.
   */
  public static Boolean isAdvanceable(
    WorkflowHarnessContext ctx,
    Workflow_Instance__c inst
  ) {
    if (ACTIVE_STATUSES.contains(inst.Status__c)) {
      return true;
    }
    // If suspended but there are still branches in Current_Step__c that have not
    // run yet, the instance is still advanceable to let those siblings execute.
    if (hasUnrunSiblingBranch(inst)) {
      return true;
    }
    if (ctx.disableAutoTimeSkip) {
      return false;
    }
    // A sleep/retry wait carries a wake time; resuming it is deterministic, so the
    // harness skips the timer and lets the engine re-run the step (the same resume
    // runStep that WorkflowSleepJob/WorkflowRetryJob enqueue). An external-signal
    // suspend (approval, wait-for-child) has no Sleep_Until__c and is left stable.
    return inst.Status__c == 'Suspended' && inst.Sleep_Until__c != null;
  }

  private static Boolean hasUnrunSiblingBranch(Workflow_Instance__c inst) {
    if (
      String.isBlank(inst.Current_Step__c) ||
      !inst.Current_Step__c.contains(',')
    ) {
      return false;
    }
    List<String> branches = splitBranches(inst.Current_Step__c);
    Map<String, Workflow_Step_Execution__c> latestExecs = latestExecByStep(
      inst.Id,
      branches
    );
    for (String branch : branches) {
      Workflow_Step_Execution__c se = latestExecs.get(branch);
      if (
        se == null ||
        (se.Status__c == 'Pending' &&
        se.SOQL_Query_Count__c == null)
      ) {
        return true; // Sibling branch has not run yet!
      }
    }
    return false;
  }

  /**
   * @description Splits a comma-separated parallel Current_Step__c value into trimmed
   * individual branch step names.
   * @param currentStep The comma-separated current step string to split.
   * @return The list of trimmed branch step names.
   */
  public static List<String> splitBranches(String currentStep) {
    List<String> branches = new List<String>();
    for (String branch : currentStep.split(',')) {
      branches.add(branch.trim());
    }
    return branches;
  }

  /**
   * @description Loads the most recent step execution for each named branch of an
   * instance, keyed by step name, using CreatedDate/Id descending to pick the latest.
   * @param instanceId The Id of the workflow instance whose executions to query.
   * @param branches The branch step names to look up.
   * @return A map from step name to its latest step execution record.
   */
  public static Map<String, Workflow_Step_Execution__c> latestExecByStep(
    Id instanceId,
    List<String> branches
  ) {
    List<Workflow_Step_Execution__c> execs = [
      SELECT Step_Name__c, Status__c, SOQL_Query_Count__c
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c = :instanceId AND Step_Name__c IN :branches
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC, Id DESC
    ];
    Map<String, Workflow_Step_Execution__c> latest = new Map<String, Workflow_Step_Execution__c>();
    for (Workflow_Step_Execution__c se : execs) {
      if (!latest.containsKey(se.Step_Name__c)) {
        latest.put(se.Step_Name__c, se);
      }
    }
    return latest;
  }
}
