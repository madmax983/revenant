/**
 * @description Status for an instance that leaves a park (issues #240, #311). A
 * gate park clears `Sleep_Until__c`. A timer on a parked instance therefore
 * came from a wait that finished after the park. Release or resume must not
 * run that step early, and must not skip its timeout route. A signal that
 * arrived in the park is the exception: the step runs and reads it. A signal
 * from before the park is not. `Parked_At__c` tells them apart.
 *
 * A serial instance goes to `Suspended`. The sleep sweep wakes it when the
 * timer ends, or at once when the timer already ended.
 *
 * A parallel instance keeps the timer of each branch in `Wake_At__c`. A branch
 * that still sleeps is not run. The instance goes to `Suspended` with the
 * first deadline in `Sleep_Until__c`. The sleep sweep starts each branch.
 */
public inherited sharing class WorkflowParkedTimer {
  /**
   * @description Sets the status of an instance that leaves a park. See
   * {@link WorkflowParkedTimer#settleAll}.
   * @param instance The parked instance, with Sleep_Until__c, Current_Step__c
   * and Parked_At__c loaded.
   * @return True when the instance waits for its timer, so no step may run now.
   */
  public static Boolean settle(Workflow_Instance__c instance) {
    return settleAll(new List<Workflow_Instance__c>{ instance })
      .contains(instance.Id);
  }

  /**
   * @description Sets the status of each instance that leaves a park, and
   * clears its park time. A signal that arrived in the park stays `Received`,
   * so the step must run and read it. Costs one SOQL for the branches of the
   * parallel instances and one for the signals.
   *
   * A serial instance with a timer is `Suspended`. A parallel instance with a
   * branch that still sleeps is `Suspended`, and `Sleep_Until__c` is the first
   * deadline. Any other instance is `Running`. A parallel instance that is
   * `Suspended` needs workers for its other branches. Use
   * {@link WorkflowBranchResume#enqueueUnlessSleeping}.
   * @param instances The parked instances, with Sleep_Until__c, Current_Step__c
   * and Parked_At__c loaded.
   * @return The Ids of the instances that need no worker: they wait for a timer.
   */
  public static Set<Id> settleAll(List<Workflow_Instance__c> instances) {
    Datetime now = Datetime.now();
    Set<Id> timed = new Set<Id>();
    List<Workflow_Instance__c> multi = new List<Workflow_Instance__c>();
    for (Workflow_Instance__c inst : instances) {
      if (isParallel(inst)) {
        multi.add(inst);
      } else if (inst.Sleep_Until__c != null) {
        timed.add(inst.Id);
      }
    }
    Map<Id, WorkflowBranchTimer.Branches> branches = WorkflowBranchTimer.load(
      multi
    );
    for (Workflow_Instance__c inst : multi) {
      if (branches.get(inst.Id).firstWake(now) != null) {
        timed.add(inst.Id);
      }
    }
    timed.removeAll(signalledInPark(instances, timed));

    Set<Id> waiting = new Set<Id>();
    for (Workflow_Instance__c inst : instances) {
      WorkflowBranchTimer.Branches b = branches.get(inst.Id);
      if (!timed.contains(inst.Id)) {
        inst.Status__c = 'Running';
      } else if (b == null) {
        inst.Status__c = 'Suspended';
        waiting.add(inst.Id);
      } else {
        inst.Status__c = 'Suspended';
        inst.Sleep_Until__c = b.firstWake(now);
        if (b.sleeping(now).size() >= b.open) {
          waiting.add(inst.Id); // Every open branch sleeps.
        }
      }
      inst.Parked_At__c = null;
    }
    return waiting;
  }

  // The Ids of the instances that have a signal from the park. A signal that
  // arrived before the park is old. A blank park time counts every signal, as
  // for a park from before the field existed. One grouped row for each
  // instance, so a signal backlog cannot reach the row limit.
  private static Set<Id> signalledInPark(
    List<Workflow_Instance__c> instances,
    Set<Id> timed
  ) {
    Set<Id> signalled = new Set<Id>();
    if (timed.isEmpty()) {
      return signalled;
    }
    Map<Id, Datetime> parkedAt = new Map<Id, Datetime>();
    for (Workflow_Instance__c inst : instances) {
      parkedAt.put(inst.Id, inst.Parked_At__c);
    }
    for (AggregateResult row : [
      SELECT Workflow_Instance__c instId, MAX(CreatedDate) lastAt
      FROM Workflow_Signal__c
      WHERE Workflow_Instance__c IN :timed AND Status__c = 'Received'
      WITH SYSTEM_MODE
      GROUP BY Workflow_Instance__c
    ]) {
      Id instId = (Id) row.get('instId');
      Datetime parked = parkedAt.get(instId);
      if (parked == null || (Datetime) row.get('lastAt') >= parked) {
        signalled.add(instId);
      }
    }
    return signalled;
  }

  private static Boolean isParallel(Workflow_Instance__c inst) {
    return String.isNotBlank(inst.Current_Step__c) &&
      inst.Current_Step__c.contains(',');
  }
}
