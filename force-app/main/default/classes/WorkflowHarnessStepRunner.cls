/**
 * Test-only single-hop step executor for the WorkflowTestHarness. Advances one
 * instance by one logical step — running each not-yet-complete parallel branch (up
 * to the remaining hop budget) or the lone current step — through the engine's own
 * runStep path, clearing sleep/retry markers exactly as the engine's wake path does.
 * Instance-bound to a WorkflowHarnessContext so the per-branch helpers stay concise.
 */
@IsTest
public inherited sharing class WorkflowHarnessStepRunner {
  private final WorkflowHarnessContext ctx;

  /**
   * @description Binds the single-hop runner to a harness run context.
   * @param ctx The per-run harness context this runner advances.
   */
  public WorkflowHarnessStepRunner(WorkflowHarnessContext ctx) {
    this.ctx = ctx;
  }

  /**
   * Advances a single instance by one logical step, consuming at most `remaining`
   * hops, and returns the hop count actually consumed. Parallel instances run each
   * not-yet-complete branch (the engine no-ops already-completed branches and
   * auto-inserts the rejoin once the last branch finishes), but never more branches
   * than the remaining budget allows — any leftover branches resume on the next hop.
   *
   * @param inst The workflow instance to advance by one logical step.
   * @param remaining The remaining hop budget for this drive.
   * @return The number of hops actually consumed.
   */
  public Integer advanceOneStep(Workflow_Instance__c inst, Integer remaining) {
    String currentStep = inst.Current_Step__c;
    if (String.isNotBlank(currentStep) && currentStep.contains(',')) {
      return advanceParallel(inst, remaining);
    }
    return advanceSingle(inst);
  }

  private Integer advanceParallel(
    Workflow_Instance__c inst,
    Integer remaining
  ) {
    List<String> branches = WorkflowHarnessAdvancer.splitBranches(
      inst.Current_Step__c
    );
    Map<String, Workflow_Step_Execution__c> latest = WorkflowHarnessAdvancer.latestExecByStep(
      inst.Id,
      branches
    );

    Integer used = 0;
    for (String branch : branches) {
      Workflow_Step_Execution__c se = latest.get(branch);
      if (shouldSkipBranch(inst, se)) {
        continue;
      }
      if (used >= remaining) {
        break;
      }
      runBranch(inst, branch, se);
      used++;
    }
    return used;
  }

  private Boolean shouldSkipBranch(
    Workflow_Instance__c inst,
    Workflow_Step_Execution__c se
  ) {
    if (se == null) {
      return false;
    }
    if (se.Status__c == 'Completed') {
      return true;
    }
    if (inst.Status__c != 'Suspended') {
      return false;
    }
    if (se.Status__c == 'Retrying' && ctx.disableAutoTimeSkip) {
      return true;
    }
    // Already ran and suspended/sleeping/waiting.
    return se.Status__c == 'Pending' &&
      se.SOQL_Query_Count__c != null &&
      ctx.disableAutoTimeSkip;
  }

  private void runBranch(
    Workflow_Instance__c inst,
    String branch,
    Workflow_Step_Execution__c se
  ) {
    Boolean isCallout = WorkflowHarnessCore.isCalloutStep(branch);
    if (
      !isCallout &&
      inst.Status__c == 'Suspended' &&
      isSleepingOrRetrying(se)
    ) {
      WorkflowHarnessSleep.clearSleepMarkers(inst.Id);
    }
    WorkflowHarnessCore.runStepSafely(ctx, inst.Id, branch);
    if (isCallout) {
      WorkflowHarnessSleep.clearStaleSleepMarkers(inst.Id);
    }
  }

  private Boolean isSleepingOrRetrying(Workflow_Step_Execution__c se) {
    return se != null &&
      (se.Status__c == 'Retrying' ||
      (se.Status__c == 'Pending' &&
      se.SOQL_Query_Count__c != null));
  }

  private Integer advanceSingle(Workflow_Instance__c inst) {
    Boolean isCallout = WorkflowHarnessCore.isCalloutStep(inst.Current_Step__c);
    if (!isCallout && inst.Status__c == 'Suspended') {
      WorkflowHarnessSleep.clearSleepMarkers(inst.Id);
    }
    WorkflowHarnessCore.runStepSafely(ctx, inst.Id, null);
    if (isCallout) {
      WorkflowHarnessSleep.clearStaleSleepMarkers(inst.Id);
    }
    return 1;
  }
}
