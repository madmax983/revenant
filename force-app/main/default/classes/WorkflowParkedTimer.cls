/**
 * @description Status for an instance that leaves a park (issue #240). A gate
 * park clears `Sleep_Until__c`. A timer on a parked instance therefore came
 * from a wait that finished after the park. Release or resume must not run
 * that step early, and must not skip its timeout route. The instance goes to
 * `Suspended`. The sleep sweep wakes it when the timer ends, or at once when
 * the timer already ended.
 */
public inherited sharing class WorkflowParkedTimer {
  /**
   * @description Sets the status of an instance that leaves a park: `Suspended`
   * when it has a timer, else `Running`.
   * @param instance The parked instance, with Sleep_Until__c loaded.
   * @return True when the instance waits for its timer, so no step may run now.
   */
  public static Boolean settle(Workflow_Instance__c instance) {
    Boolean waiting = instance.Sleep_Until__c != null;
    instance.Status__c = waiting ? 'Suspended' : 'Running';
    return waiting;
  }
}
