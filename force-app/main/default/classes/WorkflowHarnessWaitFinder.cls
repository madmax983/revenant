/**
 * Test-only lookup that locates the instance in the tree currently parked on a
 * given step for a sleep wait (checkSleep = true) or a retry wait (checkSleep =
 * false). Job existence is resolved via a single up-front CronTrigger lookup matched
 * in memory, so no SOQL runs inside the per-instance scan.
 */
@IsTest
public inherited sharing class WorkflowHarnessWaitFinder {
  /** Locates the instance currently parked on a sleep wait for the given step. */
  public static Workflow_Instance__c findSleeping(
    WorkflowHarnessContext ctx,
    String stepName
  ) {
    return find(ctx, stepName, true);
  }

  /** Locates the instance currently parked on a retry wait for the given step. */
  public static Workflow_Instance__c findRetrying(
    WorkflowHarnessContext ctx,
    String stepName
  ) {
    return find(ctx, stepName, false);
  }

  private static Workflow_Instance__c find(
    WorkflowHarnessContext ctx,
    String stepName,
    Boolean checkSleep
  ) {
    if (String.isBlank(stepName)) {
      return null;
    }
    List<Workflow_Instance__c> tree = WorkflowHarnessCore.collectTree(ctx);
    List<Id> candidateIds = candidateInstanceIds(tree, stepName);
    if (candidateIds.isEmpty()) {
      return null;
    }
    Map<Id, Workflow_Step_Execution__c> latest = latestExecByInstance(
      candidateIds,
      stepName
    );
    // Hoisted out of the loop: fetch all workflow jobs once, then match each
    // per-instance prefix in memory (no SOQL inside the loop).
    List<String> jobNames = WorkflowEngine.useDynamicScheduling
      ? WorkflowHarnessCron.namesLike('Workflow%')
      : new List<String>();
    WaitMatcher matcher = new WaitMatcher(checkSleep, jobNames);
    for (Workflow_Instance__c inst : tree) {
      if (matcher.matches(inst, latest.get(inst.Id), stepName)) {
        return inst;
      }
    }
    return null;
  }

  private static List<Id> candidateInstanceIds(
    List<Workflow_Instance__c> tree,
    String stepName
  ) {
    String checkName = stepName.toLowerCase();
    String forwardName = checkName.endsWith('_compensate')
      ? checkName.substring(0, checkName.length() - 11)
      : checkName;

    List<Id> ids = new List<Id>();
    for (Workflow_Instance__c inst : tree) {
      if (String.isBlank(inst.Current_Step__c)) {
        continue;
      }
      List<String> activeSteps = new List<String>();
      for (String s : inst.Current_Step__c.split(',')) {
        activeSteps.add(s.trim().toLowerCase());
      }
      if (
        activeSteps.contains(checkName) || activeSteps.contains(forwardName)
      ) {
        ids.add(inst.Id);
      }
    }
    return ids;
  }

  private static Map<Id, Workflow_Step_Execution__c> latestExecByInstance(
    List<Id> candidateIds,
    String stepName
  ) {
    List<Workflow_Step_Execution__c> execs = [
      SELECT Workflow_Instance__c, Status__c, SOQL_Query_Count__c, Output__c
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c IN :candidateIds AND Step_Name__c = :stepName
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC, Id DESC
    ];
    Map<Id, Workflow_Step_Execution__c> latest = new Map<Id, Workflow_Step_Execution__c>();
    for (Workflow_Step_Execution__c se : execs) {
      if (!latest.containsKey(se.Workflow_Instance__c)) {
        latest.put(se.Workflow_Instance__c, se);
      }
    }
    return latest;
  }

  /**
   * Decides whether a suspended instance is genuinely parked on the target step for
   * the requested wait kind, holding the wait kind and up-front job lookup so the
   * per-instance test stays a three-argument call.
   */
  private class WaitMatcher {
    private final Boolean checkSleep;
    private final List<String> jobNames;

    WaitMatcher(Boolean checkSleep, List<String> jobNames) {
      this.checkSleep = checkSleep;
      this.jobNames = jobNames;
    }

    Boolean matches(
      Workflow_Instance__c inst,
      Workflow_Step_Execution__c se,
      String stepName
    ) {
      if (se == null || inst.Status__c != 'Suspended') {
        return false;
      }
      if (
        checkSleep &&
        se.Status__c == 'Pending' &&
        se.SOQL_Query_Count__c != null
      ) {
        return isSleepMatch(inst, se, stepName);
      }
      if (!checkSleep && se.Status__c == 'Retrying') {
        return isRetryMatch(inst);
      }
      return false;
    }

    private Boolean isSleepMatch(
      Workflow_Instance__c inst,
      Workflow_Step_Execution__c se,
      String stepName
    ) {
      if (WorkflowHarnessSleep.isFrameworkWaitState(se.Output__c)) {
        return false;
      }
      return hasWakeSignal(
        inst,
        WorkflowEngine.getSleepJobPrefix(inst.Id, stepName)
      );
    }

    private Boolean isRetryMatch(Workflow_Instance__c inst) {
      return hasWakeSignal(inst, 'WorkflowRetry_' + inst.Id + '_');
    }

    private Boolean hasWakeSignal(Workflow_Instance__c inst, String jobPrefix) {
      if (!WorkflowEngine.useDynamicScheduling) {
        return inst.Sleep_Until__c != null;
      }
      if (WorkflowHarnessCron.anyStartsWith(jobNames, jobPrefix)) {
        return true;
      }
      return inst.Sleep_Until__c != null;
    }
  }
}
