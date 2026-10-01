/**
 * @description Operator API to hold and release one workflow instance
 * (issue #119). It is a public API, the same as `WorkflowPauseGate` for a
 * definition pause.
 *
 * `hold` records the hold on one instance. It does not change the status: the
 * gate in `WorkflowInstanceHoldGate` parks the instance at the next step
 * boundary. If a step runs when the operator holds the instance, the step
 * finishes. `release` clears the hold.
 * When the instance is parked, release sets `Running`, re-arms the step
 * timeouts and enqueues the step (or each open parallel branch). Both calls
 * lock the instance. Expected states return an outcome, not an exception.
 * Neither call reads or writes pause state or schedules a job. All DML and
 * SOQL run in system mode. The caller must check permissions.
 */
public inherited sharing class WorkflowInstanceHold {
  private static final Map<Outcome, String> MESSAGES = new Map<Outcome, String>{
    Outcome.HELD => 'The instance stops at its next step boundary.',
    Outcome.ALREADY_HELD => 'The instance is already held.',
    Outcome.RELEASED => 'The hold is removed. The instance continues.',
    Outcome.NOT_HELD => 'The instance is not held.',
    Outcome.NOT_FOUND => 'The instance does not exist.',
    Outcome.REJECTED_TERMINAL => 'A finished instance cannot be held.',
    Outcome.REJECTED_COMPENSATING => 'A rollback cannot be held.',
    Outcome.REJECTED_ENGINE_WORKFLOW => 'An engine workflow cannot be held.'
  };

  // Length of Workflow_Instance__c.Hold_Reason__c.
  private static final Integer REASON_MAX = 255;

  // Terminal statuses. Hold rejects them.
  private static final Set<String> TERMINAL_STATUSES = new Set<String>{
    'Completed',
    'Failed',
    'Compensated',
    'Cancelled',
    'ContinuedAsNew'
  };

  // Rollback statuses. The gate is on the forward path only, so hold rejects them.
  private static final Set<String> COMPENSATING_STATUSES = new Set<String>{
    'Compensating',
    'Cancelling',
    'CompensationFailed'
  };

  /**
   * @description What a hold or release call did.
   */
  public enum Outcome {
    HELD,
    ALREADY_HELD,
    RELEASED,
    NOT_HELD,
    NOT_FOUND,
    REJECTED_TERMINAL,
    REJECTED_COMPENSATING,
    REJECTED_ENGINE_WORKFLOW
  }

  /**
   * @description Result of a hold or release call.
   */
  public class HoldResult {
    /** @description Id of the target instance. */
    public Id instanceId { get; private set; }
    /** @description What the call did. */
    public Outcome outcome { get; private set; }
    /** @description Instance status after the call. Null when not found. */
    public String status { get; private set; }
    /** @description Short text for the operator. */
    public String message { get; private set; }

    /**
     * @description Builds a result. The message comes from the outcome.
     * @param instanceId Id of the target instance
     * @param outcome what the call did
     * @param status instance status after the call
     */
    public HoldResult(Id instanceId, Outcome outcome, String status) {
      this.instanceId = instanceId;
      this.outcome = outcome;
      this.status = status;
      this.message = MESSAGES.get(outcome);
    }
  }

  /**
   * @description Holds one instance. The instance stops at its next step
   * boundary. If a step runs now, the step finishes. Other instances and the
   * definition pause state do not change. A second hold is a no-op.
   * @param instanceId Id of the instance to hold
   * @param reason operator reason, or blank; truncated to 255 characters
   * @return the outcome; terminal, compensating and engine-workflow instances
   * are rejected without an exception
   * @throws WorkflowEngine.WorkflowException when instanceId is null
   */
  public static HoldResult hold(Id instanceId, String reason) {
    Workflow_Instance__c inst = lock(instanceId);
    if (inst == null) {
      return new HoldResult(instanceId, Outcome.NOT_FOUND, null);
    }
    Outcome rejection = rejection(inst);
    if (rejection != null) {
      return new HoldResult(inst.Id, rejection, inst.Status__c);
    }
    if (isHeld(inst)) {
      return new HoldResult(inst.Id, Outcome.ALREADY_HELD, inst.Status__c);
    }
    inst.Held_At__c = Datetime.now();
    inst.Hold_Reason__c = String.isBlank(reason)
      ? null
      : reason.abbreviate(REASON_MAX);
    Database.update(inst, true, AccessLevel.SYSTEM_MODE);
    WorkflowLog.warn(
      'InstanceHeld',
      'Held by user ' +
        UserInfo.getUserId() +
        '. Reason: ' +
        inst.Hold_Reason__c,
      inst.Id
    );
    return new HoldResult(inst.Id, Outcome.HELD, inst.Status__c);
  }

  /**
   * @description Releases one instance. A parked instance continues from the
   * step where it stopped. A hold that did not park yet is removed, and the
   * live chain continues. A release of an instance that is not held is a no-op.
   * @param instanceId Id of the instance to release
   * @return the outcome
   * @throws WorkflowEngine.WorkflowException when instanceId is null
   */
  public static HoldResult release(Id instanceId) {
    Workflow_Instance__c inst = lock(instanceId);
    if (inst == null) {
      return new HoldResult(instanceId, Outcome.NOT_FOUND, null);
    }
    if (!isHeld(inst)) {
      return new HoldResult(inst.Id, Outcome.NOT_HELD, inst.Status__c);
    }
    Boolean parked = inst.Status__c == WorkflowInstanceHoldGate.STATUS;
    inst.Held_At__c = null;
    inst.Hold_Reason__c = null;
    Boolean waiting = parked && unpark(inst);
    Database.update(inst, true, AccessLevel.SYSTEM_MODE);
    WorkflowLog.warn(
      'InstanceHeld',
      'Released by user ' + UserInfo.getUserId(),
      inst.Id
    );
    if (parked && !waiting) {
      // Re-arm before enqueue so a delayed worker still has a deadline.
      WorkflowTimeoutReArm.reArmTimeoutsForResume(
        new List<Workflow_Instance__c>{ inst }
      );
      enqueue(inst);
    }
    return new HoldResult(inst.Id, Outcome.RELEASED, inst.Status__c);
  }

  /**
   * @description The hold to copy to a Continue-As-New successor. Read it
   * before the terminal update of the predecessor, which clears the hold. A
   * hold placed while the step ran is newer than the loaded record.
   * @param predecessor the instance that continues as new
   * @return a record with Held_At__c and Hold_Reason__c (blank when not held)
   */
  public static Workflow_Instance__c successorHold(
    Workflow_Instance__c predecessor
  ) {
    // Engine workflows are never held, so they skip the query.
    if (WorkflowPauseGate.isEngineWorkflow(predecessor.Workflow_Name__c)) {
      return new Workflow_Instance__c();
    }
    Workflow_Instance__c row = [
      SELECT Held_At__c, Hold_Reason__c
      FROM Workflow_Instance__c
      WHERE Id = :predecessor.Id
      WITH SYSTEM_MODE
    ];
    return new Workflow_Instance__c(
      Held_At__c = row.Held_At__c,
      Hold_Reason__c = row.Hold_Reason__c
    );
  }

  // A run that waits for a concurrency slot must not be Running without one.
  // It goes back to Suspended and the admission gate takes it. Sleep_Until__c
  // lets the watchdog drive it again if the enqueue is lost.
  // A timer from a wait that ended in the park keeps the instance Suspended
  // (issue #240). The sleep sweep wakes it.
  // Returns true when the timer keeps the instance asleep, so no step may run.
  private static Boolean unpark(Workflow_Instance__c inst) {
    if (inst.Concurrency_Parked__c && !inst.Concurrency_Slot_Held__c) {
      inst.Status__c = 'Suspended';
      inst.Sleep_Until__c = Datetime.now();
      return false;
    }
    return WorkflowParkedTimer.settle(inst);
  }

  /**
   * @description Tells if hold accepts the instance: it is on the forward
   * path, it is not a rollback, and it is not an engine workflow. The
   * dashboard shows Hold only when this is true.
   * @param inst the instance, with Id, Status__c, Workflow_Name__c and
   * Compensation_Stack__c
   * @return true when hold can accept the instance
   */
  public static Boolean isHoldable(Workflow_Instance__c inst) {
    return rejection(inst) == null;
  }

  // Locks the instance. Returns null when it does not exist.
  private static Workflow_Instance__c lock(Id instanceId) {
    if (instanceId == null) {
      throw new WorkflowEngine.WorkflowException('instanceId is required.');
    }
    List<Workflow_Instance__c> rows = [
      SELECT
        Id,
        Status__c,
        Workflow_Name__c,
        Current_Step__c,
        Compensation_Stack__c,
        Concurrency_Parked__c,
        Concurrency_Slot_Held__c,
        Held_At__c,
        Hold_Reason__c,
        Sleep_Until__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
      WITH SYSTEM_MODE
      FOR UPDATE
    ];
    return rows.isEmpty() ? null : rows[0];
  }

  // Held: a hold is recorded, or the gate parked the instance.
  private static Boolean isHeld(Workflow_Instance__c inst) {
    return inst.Held_At__c != null ||
      inst.Status__c == WorkflowInstanceHoldGate.STATUS;
  }

  // The reason hold must refuse the instance, or null.
  private static Outcome rejection(Workflow_Instance__c inst) {
    if (TERMINAL_STATUSES.contains(inst.Status__c)) {
      return Outcome.REJECTED_TERMINAL;
    }
    // A compensation step that waits leaves the status Suspended or Running.
    if (
      COMPENSATING_STATUSES.contains(inst.Status__c) ||
      WorkflowStepAdmission.isLiveCompensation(inst)
    ) {
      return Outcome.REJECTED_COMPENSATING;
    }
    if (WorkflowPauseGate.isEngineWorkflow(inst.Workflow_Name__c)) {
      return Outcome.REJECTED_ENGINE_WORKFLOW;
    }
    return null;
  }

  // Serial: one orchestrator for the current step. Parallel: one per open branch.
  private static void enqueue(Workflow_Instance__c inst) {
    if (
      String.isNotBlank(inst.Current_Step__c) &&
      inst.Current_Step__c.contains(',')
    ) {
      WorkflowBranchResume.enqueueResumeBulk(
        new List<Workflow_Instance__c>{ inst }
      );
      return;
    }
    if (!(Test.isRunningTest() && WorkflowEngine.disableQueueableInTest)) {
      WorkflowOrchestratorEnqueue.enqueueOrchestrators(new List<Id>{ inst.Id });
    }
  }
}
