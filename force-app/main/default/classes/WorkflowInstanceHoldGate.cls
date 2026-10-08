/**
 * @description Hot-path gate that parks an operator-held instance at the next
 * step boundary (issue #119).
 *
 * `WorkflowStepRunner` calls it after the definition-change gate and before
 * the pause gate. It reads the formula `Held__c` from the loaded instance, so
 * an instance that is not held costs no SOQL and no DML. On a held instance it
 * locks the row, checks the hold again, aborts the scheduled jobs, and sets
 * status `Held`. It writes no step row and does not change the current step,
 * the compensation stack or the signals. It never reads pause state. All DML
 * and SOQL run in system mode.
 */
public inherited sharing class WorkflowInstanceHoldGate {
  /** @description Instance status of a parked, held instance. */
  public static final String STATUS = 'Held';

  // Statuses a delivery can park from. Any other status is owned by another path.
  private static final Set<String> PARKABLE_STATUSES = new Set<String>{
    'Pending',
    'Running',
    'Suspended'
  };

  /**
   * @description Parks the instance when it is held. Returns true when the
   * caller must stop the delivery.
   * @param instance The instance that the runner drives (loaded without a
   * lock, with Status__c, Workflow_Name__c and Held__c).
   * @return True when the instance is parked (now or before).
   */
  public static Boolean parkIfHeld(Workflow_Instance__c instance) {
    if (instance.Status__c == STATUS) {
      return true; // Stale delivery. Only release moves a parked instance.
    }
    if (instance.Held__c != true) {
      return false;
    }
    // Hold rejects engine workflows. A hold set by direct DML must not park the
    // watchdog either.
    if (WorkflowPauseGate.isEngineWorkflow(instance.Workflow_Name__c)) {
      return false;
    }
    return park(instance);
  }

  /**
   * @description The status for a step that waits (suspend, sleep, retry,
   * child, approval). A park stays (`DefinitionChanged`, `Held`, `Paused`): an
   * outcome that ran before the park must not undo it, else release does not
   * drive the step that the park stopped.
   * @param instance The re-locked instance of the step outcome.
   * @return The park status when the instance is parked, else `Suspended`.
   */
  public static String waitStatus(Workflow_Instance__c instance) {
    return WorkflowOutcomePrepare.isParkedStatus(instance.Status__c)
      ? instance.Status__c
      : 'Suspended';
  }

  // Re-read the instance FOR UPDATE (instance lock first, matching admission
  // lock order), then park it once. A release that ran after the load wins.
  private static Boolean park(Workflow_Instance__c instance) {
    Workflow_Instance__c locked = [
      SELECT Id, Status__c, Held_At__c, Current_Step__c
      FROM Workflow_Instance__c
      WHERE Id = :instance.Id
      WITH SYSTEM_MODE
      FOR UPDATE
    ];
    if (locked.Held_At__c == null) {
      return false; // Released after the load. This delivery is the live chain.
    }
    if (!PARKABLE_STATUSES.contains(locked.Status__c)) {
      return true; // Parked, finished or compensating by another thread.
    }
    // A scheduled sleep, retry or timeout job must not fire into the park.
    // Release re-arms the step timeouts.
    WorkflowOrchestratorEnqueue.abortScheduledJobs(locked.Id);
    locked.Status__c = STATUS;
    locked.Parked_At__c = Datetime.now();
    locked.Sleep_Until__c = null;
    locked.Async_Job_Id__c = null;
    Database.update(locked, true, AccessLevel.SYSTEM_MODE);
    WorkflowLog.warn(
      'InstanceHeld',
      'Parked at step ' + locked.Current_Step__c + '. Release to continue.',
      locked.Id
    );
    instance.Status__c = STATUS;
    return true;
  }
}
