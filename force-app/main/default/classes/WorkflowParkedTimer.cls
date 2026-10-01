/**
 * @description Status for an instance that leaves a park (issue #240). A gate
 * park clears `Sleep_Until__c`. A timer on a parked instance therefore came
 * from a wait that finished after the park. Release or resume must not run
 * that step early, and must not skip its timeout route. A signal that arrived
 * in the park is the exception: the step runs and reads it. The instance goes to
 * `Suspended`. The sleep sweep wakes it when the timer ends, or at once when
 * the timer already ended.
 */
public inherited sharing class WorkflowParkedTimer {
  /**
   * @description Sets the status of an instance that leaves a park: `Suspended`
   * when it has a timer and no buffered signal, else `Running`.
   * @param instance The parked instance, with Sleep_Until__c loaded.
   * @return True when the instance waits for its timer, so no step may run now.
   */
  public static Boolean settle(Workflow_Instance__c instance) {
    return settleAll(new List<Workflow_Instance__c>{ instance })
      .contains(instance.Id);
  }

  /**
   * @description Sets the status of each instance that leaves a park. A signal
   * that arrived in the park stays `Received`, so the step must run and read
   * it. Costs one SOQL for all instances.
   * @param instances The parked instances, with Sleep_Until__c loaded.
   * @return The Ids of the instances that wait for their timer.
   */
  public static Set<Id> settleAll(List<Workflow_Instance__c> instances) {
    Set<Id> timed = new Set<Id>();
    for (Workflow_Instance__c inst : instances) {
      if (inst.Sleep_Until__c != null) {
        timed.add(inst.Id);
      }
    }
    if (!timed.isEmpty()) {
      // One grouped row per instance, so a signal backlog cannot reach the row
      // limit.
      for (AggregateResult row : [
        SELECT Workflow_Instance__c instId
        FROM Workflow_Signal__c
        WHERE Workflow_Instance__c IN :timed AND Status__c = 'Received'
        WITH SYSTEM_MODE
        GROUP BY Workflow_Instance__c
      ]) {
        timed.remove((Id) row.get('instId'));
      }
    }
    for (Workflow_Instance__c inst : instances) {
      inst.Status__c = timed.contains(inst.Id) ? 'Suspended' : 'Running';
    }
    return timed;
  }
}
