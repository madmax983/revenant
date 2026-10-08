/**
 * @description Timer of each parallel branch (issue #311). A sleep or a timed
 * wait stores its deadline in `Wake_At__c` on the step row. A park clears
 * `Sleep_Until__c`, which is one field for all branches. The row timer
 * stays. Release, resume, hold release and the sleep sweep read it here. All
 * SOQL runs in system mode.
 */
public inherited sharing class WorkflowBranchTimer {
  /** @description The branches of one parallel instance. */
  public class Branches {
    /** @description Branches that wait: the latest row is Pending and has a timer. */
    public Map<String, Datetime> wakes = new Map<String, Datetime>();
    /** @description Branches that are not finished. */
    public Integer open = 0;

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

  /**
   * @description Reads the branch timers of parallel instances. Costs one SOQL
   * for all instances.
   * @param multi The instances, with Current_Step__c loaded.
   * @return The branches by instance Id.
   */
  public static Map<Id, Branches> load(List<Workflow_Instance__c> multi) {
    Map<Id, Branches> result = new Map<Id, Branches>();
    Map<Id, Set<String>> namesById = new Map<Id, Set<String>>();
    Set<String> allNames = new Set<String>();
    for (Workflow_Instance__c inst : multi) {
      Set<String> names = new Set<String>();
      for (String name : inst.Current_Step__c.split(',')) {
        names.add(name.trim());
      }
      namesById.put(inst.Id, names);
      allNames.addAll(names);
      result.put(inst.Id, new Branches());
    }
    if (multi.isEmpty()) {
      return result;
    }
    Set<String> seen = new Set<String>();
    // Newest first, so the first row of a branch is its latest.
    for (Workflow_Step_Execution__c row : [
      SELECT Workflow_Instance__c, Step_Name__c, Status__c, Wake_At__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c IN :namesById.keySet()
        AND Step_Name__c IN :allNames
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC, Id DESC
    ]) {
      String key = row.Workflow_Instance__c + '::' + row.Step_Name__c;
      if (
        !seen.add(key) ||
        !namesById.get(row.Workflow_Instance__c).contains(row.Step_Name__c)
      ) {
        continue;
      }
      Branches branches = result.get(row.Workflow_Instance__c);
      if (isFinished(row.Status__c)) {
        namesById.get(row.Workflow_Instance__c).remove(row.Step_Name__c);
      } else if (row.Status__c == 'Pending' && row.Wake_At__c != null) {
        branches.wakes.put(row.Step_Name__c, row.Wake_At__c);
      }
    }
    for (Id instId : result.keySet()) {
      // A branch with no row yet is open.
      result.get(instId).open = namesById.get(instId).size();
    }
    return result;
  }

  /**
   * @description Finds the branches that still sleep on the instances that
   * {@link WorkflowParkedTimer} set to `Suspended`. A `Running` instance has
   * none: it runs every open branch.
   * @param instances The parallel instances that left a park.
   * @param separator The text between the instance Id and the step name.
   * @return The keys "instanceId" + separator + "stepName".
   */
  public static Set<String> sleepingKeys(
    List<Workflow_Instance__c> instances,
    String separator
  ) {
    List<Workflow_Instance__c> asleep = new List<Workflow_Instance__c>();
    for (Workflow_Instance__c inst : instances) {
      if (inst.Status__c == 'Suspended') {
        asleep.add(inst);
      }
    }
    Set<String> keys = new Set<String>();
    Datetime now = Datetime.now();
    Map<Id, Branches> branches = load(asleep);
    for (Id instId : branches.keySet()) {
      for (String step : branches.get(instId).sleeping(now).keySet()) {
        keys.add(instId + separator + step);
      }
    }
    return keys;
  }

  /**
   * @description Picks the `Sleep_Until__c` for an instance after a wait. A
   * parallel instance keeps an earlier future deadline of a sibling branch.
   * Else the sweep would not wake that sibling.
   * @param existing The `Sleep_Until__c` now on the instance.
   * @param own The deadline of this wait, or null when it has no timer.
   * @param isParallel True when the step is a parallel branch.
   * @return The value to store.
   */
  public static Datetime keepEarlier(
    Datetime existing,
    Datetime own,
    Boolean isParallel
  ) {
    if (
      isParallel != true ||
      existing == null ||
      existing <= Datetime.now() ||
      (own != null &&
      own <= existing)
    ) {
      return own;
    }
    return existing;
  }

  private static Boolean isFinished(String status) {
    return status == 'Completed' || status == 'OperatorSkipped';
  }
}
