/**
 * @description Verdict classification for an incomplete parallel branch set in
 * the Revenant step outcome. Categorizes each not-all-done branch's latest
 * execution (running, failed, pending or none) and derives the overall verdict:
 * SUSPEND when only pending work remains, FAIL when the only non-done branches
 * failed, otherwise NONE. Extracted from `WorkflowEngine`;
 * {@link WorkflowParallelVerdict#classifyIncompleteParallel} is invoked by the
 * parallel fan-in when not all branches are done.
 */
public inherited sharing class WorkflowParallelVerdict {
  /**
   * @description Classifies a not-all-done parallel branch set as SUSPEND, FAIL
   * or NONE, by categorizing each branch's latest execution and deriving the
   * overall verdict. Public so the parallel fan-in can apply the incomplete
   * verdict to the instance.
   * @param activeParallelSteps the active parallel branch step names
   * @param latestExecByStep the latest execution per active branch
   * @return the verdict: SUSPEND, FAIL or NONE
   */
  public static String classifyIncompleteParallel(
    List<String> activeParallelSteps,
    Map<String, Workflow_Step_Execution__c> latestExecByStep
  ) {
    Boolean hasPending = false;
    Boolean hasRunning = false;
    Boolean hasFailed = false;
    for (String ps : activeParallelSteps) {
      String cat = parallelBranchCategory(latestExecByStep.get(ps));
      if (cat == 'RUNNING') {
        hasRunning = true;
      } else if (cat == 'FAILED') {
        hasFailed = true;
      } else if (cat == 'PENDING') {
        hasPending = true;
      }
    }
    return parallelVerdict(hasPending, hasRunning, hasFailed);
  }

  // Category of a single parallel branch's latest execution.
  private static String parallelBranchCategory(Workflow_Step_Execution__c pe) {
    if (pe == null) {
      return 'RUNNING';
    }
    if (pe.Status__c == 'Running') {
      return 'RUNNING';
    }
    if (pe.Status__c == 'Failed') {
      return 'FAILED';
    }
    if (pe.Status__c == 'Retrying') {
      return 'PENDING';
    }
    if (pe.Status__c == 'Pending') {
      return pe.CPU_Time_Ms__c != null ? 'PENDING' : 'RUNNING';
    }
    return 'NONE';
  }

  // Overall verdict for a not-all-done parallel branch set.
  private static String parallelVerdict(
    Boolean hasPending,
    Boolean hasRunning,
    Boolean hasFailed
  ) {
    if (hasPending && !hasRunning) {
      return 'SUSPEND';
    }
    if (!hasPending && !hasRunning && hasFailed) {
      return 'FAIL';
    }
    return 'NONE';
  }
}
