/**
 * @description Timer of each parallel branch (issues #311, #335). A sleep or a
 * timed wait stores its deadline in `Wake_At__c` on the step row. A park clears
 * `Sleep_Until__c`, which is one field for all branches. The row timer stays.
 * Release, resume, hold release, signal wake and the sleep sweep read it here.
 * The read is bounded: it does not grow with the step history. A run that
 * starts a branch claims the timer in the same transaction. All SOQL and DML
 * run in system mode.
 */
public inherited sharing class WorkflowBranchTimer {
  /** @description The branches of one parallel instance. */
  public class Branches {
    /** @description Branches that wait: the latest row is Pending and has a timer. */
    public Map<String, Datetime> wakes = new Map<String, Datetime>();
    /** @description Step row Id of each branch in `wakes`. */
    public Map<String, Id> rowIds = new Map<String, Id>();
    /**
     * @description Branches whose Pending row has no timer, no wait type and no
     * retry mark. A sleep from before the row timers looks like this (issue #335).
     */
    public List<String> untimedPending = new List<String>();
    /** @description Branches that are not finished, in `Current_Step__c` order. */
    public List<String> openNames = new List<String>();

    /**
     * @description Returns the branches whose deadline is after a time.
     * @param now The time to compare with.
     * @return Branch name to deadline.
     */
    public Map<String, Datetime> sleeping(Datetime now) {
      Map<String, Datetime> result = new Map<String, Datetime>();
      for (String step : wakes.keySet()) {
        if (wakes.get(step) > now) {
          result.put(step, wakes.get(step));
        }
      }
      return result;
    }

    /**
     * @description Returns the earliest deadline of the other branches, due or
     * not. The sweep starts a branch that is due.
     * @param step The branch to leave out.
     * @return The earliest deadline, or null when no other branch has one.
     */
    public Datetime firstWakeExcept(String step) {
      Datetime first = null;
      for (String other : wakes.keySet()) {
        if (other != step && (first == null || wakes.get(other) < first)) {
          first = wakes.get(other);
        }
      }
      return first;
    }

    /**
     * @description Returns the earliest deadline that is after a time.
     * @param now The time to compare with.
     * @return The first deadline, or null when no branch sleeps.
     */
    public Datetime firstWake(Datetime now) {
      Datetime first = null;
      for (Datetime wake : sleeping(now).values()) {
        if (first == null || wake < first) {
          first = wake;
        }
      }
      return first;
    }
  }

  // The last release read of each instance. Taken one time.
  private static Map<Id, Branches> loaded = new Map<Id, Branches>();

  /**
   * @description Reads the branch timers of parallel instances. Costs two SOQL
   * for all instances, and one row for each active step and for each finished
   * branch. It does not read the older visits of a step.
   * @param multi The instances, with Current_Step__c loaded.
   * @return The branches by instance Id.
   */
  public static Map<Id, Branches> load(List<Workflow_Instance__c> multi) {
    Map<Id, Branches> result = new Map<Id, Branches>();
    if (multi.isEmpty()) {
      return result;
    }
    Map<Id, List<String>> namesById = new Map<Id, List<String>>();
    Set<String> allNames = new Set<String>();
    for (Workflow_Instance__c inst : multi) {
      List<String> names = new List<String>();
      for (String name : inst.Current_Step__c.split(',')) {
        if (!names.contains(name.trim())) {
          names.add(name.trim());
        }
      }
      namesById.put(inst.Id, names);
      allNames.addAll(names);
      result.put(inst.Id, new Branches());
    }
    Set<String> active = readActive(result, namesById, allNames);
    Set<String> finished = readFinished(namesById, active);
    for (Id instId : result.keySet()) {
      // A branch with no row yet is open.
      for (String name : namesById.get(instId)) {
        String key = instId + '::' + name;
        if (active.contains(key) || !finished.contains(key)) {
          result.get(instId).openNames.add(name);
        }
      }
    }
    return result;
  }

  /**
   * @description Reads the branches like {@link #load} and keeps the read for
   * one {@link #take} in this transaction. A release reads once to set the
   * status and takes the same read to choose the branches to start.
   * @param multi The instances, with Current_Step__c loaded.
   * @return The branches by instance Id.
   */
  public static Map<Id, Branches> loadForRelease(
    List<Workflow_Instance__c> multi
  ) {
    Map<Id, Branches> result = load(multi);
    loaded.putAll(result);
    return result;
  }

  // The branches with a Pending, Running or Retrying row. A Pending row with a timer
  // sleeps. Few rows: one for each branch that runs or waits.
  private static Set<String> readActive(
    Map<Id, Branches> result,
    Map<Id, List<String>> namesById,
    Set<String> allNames
  ) {
    Set<String> active = new Set<String>();
    for (Workflow_Step_Execution__c row : [
      SELECT
        Id,
        Workflow_Instance__c,
        Step_Name__c,
        Status__c,
        Wake_At__c,
        Wait_Type__c,
        Transient_Retry_Count__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c IN :namesById.keySet()
        AND Step_Name__c IN :allNames
        AND Status__c IN ('Pending', 'Running', 'Retrying')
      WITH SYSTEM_MODE
    ]) {
      if (!namesById.get(row.Workflow_Instance__c).contains(row.Step_Name__c)) {
        continue;
      }
      active.add(row.Workflow_Instance__c + '::' + row.Step_Name__c);
      if (row.Status__c != 'Pending') {
        continue;
      }
      Branches branches = result.get(row.Workflow_Instance__c);
      if (row.Wake_At__c != null) {
        branches.wakes.put(row.Step_Name__c, row.Wake_At__c);
        branches.rowIds.put(row.Step_Name__c, row.Id);
      } else if (
        row.Wait_Type__c == null &&
        (row.Transient_Retry_Count__c == null ||
        row.Transient_Retry_Count__c == 0)
      ) {
        branches.untimedPending.add(row.Step_Name__c);
      }
    }
    return active;
  }

  // The branches that finished at least one visit. One grouped row for each
  // branch, so a long history cannot reach the row limit. Only branches with
  // no active row need it.
  private static Set<String> readFinished(
    Map<Id, List<String>> namesById,
    Set<String> active
  ) {
    Set<Id> askIds = new Set<Id>();
    Set<String> askNames = new Set<String>();
    for (Id instId : namesById.keySet()) {
      for (String name : namesById.get(instId)) {
        if (!active.contains(instId + '::' + name)) {
          askIds.add(instId);
          askNames.add(name);
        }
      }
    }
    Set<String> finished = new Set<String>();
    if (askIds.isEmpty()) {
      return finished;
    }
    for (AggregateResult row : [
      SELECT
        Workflow_Instance__c instId,
        Step_Name__c stepName,
        COUNT(Id) visits
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c IN :askIds
        AND Step_Name__c IN :askNames
        AND Status__c IN ('Completed', 'OperatorSkipped')
      WITH SYSTEM_MODE
      GROUP BY Workflow_Instance__c, Step_Name__c
    ]) {
      finished.add(
        (Id) row.get('instId') + '::' + (String) row.get('stepName')
      );
    }
    return finished;
  }

  /**
   * @description Finds the branches that still sleep on the instances that
   * {@link WorkflowParkedTimer} set to `Suspended`. A `Running` instance has
   * none: it runs every open branch.
   * @param instances The parallel instances that left a park.
   * @param branches The branches of those instances, from {@link #take}.
   * @param separator The text between the instance Id and the step name.
   * @return The keys "instanceId" + separator + "stepName".
   */
  public static Set<String> sleepingKeys(
    List<Workflow_Instance__c> instances,
    Map<Id, Branches> branches,
    String separator
  ) {
    Set<String> keys = new Set<String>();
    Datetime now = Datetime.now();
    for (Workflow_Instance__c inst : instances) {
      if (inst.Status__c == 'Suspended' && branches.containsKey(inst.Id)) {
        for (String step : branches.get(inst.Id).sleeping(now).keySet()) {
          keys.add(inst.Id + separator + step);
        }
      }
    }
    return keys;
  }

  /**
   * @description Builds the update that claims a branch timer. The run that
   * starts the branch clears the timer in the same transaction. Else a park
   * that stops the worker leaves a timer that holds a later release.
   * @param rowId The Id of the step row.
   * @return The row to update.
   */
  public static Workflow_Step_Execution__c claimRow(Id rowId) {
    return new Workflow_Step_Execution__c(Id = rowId, Wake_At__c = null);
  }

  /**
   * @description Builds the update for a branch that its own timer wakes. It
   * clears the timer and arms the step timeout. A release does not arm a
   * sleeping branch, so the timeout starts when the timer ends (issue #335).
   * @param rowId The Id of the step row.
   * @param stepName The branch step name.
   * @param workflowName The workflow of the instance.
   * @return The row to update.
   */
  public static Workflow_Step_Execution__c wokenRow(
    Id rowId,
    String stepName,
    String workflowName
  ) {
    Workflow_Step_Execution__c row = claimRow(rowId);
    Integer timeout = WorkflowStepTimeoutConfig.getStepTimeoutSeconds(
      stepName,
      WorkflowTypeResolver.extractNamespace(workflowName)
    );
    if (timeout != null && timeout > 0) {
      row.Timeout_At__c = Datetime.now().addSeconds(timeout);
    }
    return row;
  }

  /**
   * @description Saves the claimed rows. Call it before the run is published.
   * @param rows The rows from {@link #claimRow} or {@link #wokenRow}.
   */
  public static void claim(List<Workflow_Step_Execution__c> rows) {
    if (!rows.isEmpty()) {
      Database.update(rows, true, AccessLevel.SYSTEM_MODE);
    }
  }

  /**
   * @description Picks the `Sleep_Until__c` for an instance after a wait. A
   * parallel instance keeps an earlier future deadline of a sibling branch.
   * Else the sweep would not wake that sibling.
   * @param instance The instance. A serial wait does not read its timer.
   * @param own The deadline of this wait, or null when it has no timer.
   * @param isParallel True when the step is a parallel branch.
   * @return The value to store.
   */
  public static Datetime keepEarlier(
    Workflow_Instance__c instance,
    Datetime own,
    Boolean isParallel
  ) {
    if (isParallel != true) {
      return own;
    }
    Datetime existing = instance.Sleep_Until__c;
    if (
      existing == null ||
      existing <= Datetime.now() ||
      (own != null &&
      own <= existing)
    ) {
      return own;
    }
    return existing;
  }

  /**
   * @description Returns the branches. It uses the read that settleAll made in
   * this transaction, else reads again.
   * @param instances The parallel instances.
   * @return The branches by instance Id.
   */
  public static Map<Id, Branches> take(List<Workflow_Instance__c> instances) {
    Map<Id, Branches> result = new Map<Id, Branches>();
    List<Workflow_Instance__c> missing = new List<Workflow_Instance__c>();
    for (Workflow_Instance__c inst : instances) {
      if (loaded.containsKey(inst.Id)) {
        result.put(inst.Id, loaded.remove(inst.Id));
      } else {
        missing.add(inst);
      }
    }
    result.putAll(load(missing));
    return result;
  }

  private static Boolean isFinished(String status) {
    return status == 'Completed' || status == 'OperatorSkipped';
  }
}
