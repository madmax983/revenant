/**
 * @description Insert-and-wake phase for the durable-execution engine's
 * `signal(List)` path (INV-E all-or-none savepoint). Inserts the staged signal
 * rows under one savepoint (unkeyed rows via a plain insert; keyed rows via
 * allOrNone=false so a concurrent-duplicate loser is a no-op while a genuine
 * error rolls back and surfaces), then wakes and enqueues the instances that
 * received a fresh signal sharing that SAME savepoint: the status flip,
 * enqueueOrchestrators and enqueueResumeBulk can still throw after the rows are
 * committed, so on any failure the inserted rows are rolled back and the enqueue
 * guards cleared before rethrowing. The savepoint is created and rolled back in
 * this one class so the whole bulk stays all-or-none. Join readiness is delegated
 * to `WorkflowSignalGating`; the resume/enqueue core and enqueue guards stay
 * resident on `WorkflowEngine`. All DML/SOQL runs in system mode.
 */
public inherited sharing class WorkflowSignalBatchWake {
  /** The instances to flip to Running and the set to wake/enqueue this call. */
  private class WakeSelection {
    List<Workflow_Instance__c> instancesToUpdate = new List<Workflow_Instance__c>();
    List<Workflow_Instance__c> activeInstances = new List<Workflow_Instance__c>();
  }

  /**
   * @description Inserts the staged signal rows under one savepoint so the bulk
   * call is all-or-none: unkeyed rows use a plain insert; keyed rows use
   * allOrNone=false so a concurrent-duplicate loser is a no-op while a genuine
   * error rolls back and surfaces. The savepoint is shared with the wake phase,
   * so it is returned for that phase's rollback.
   * @param part the partition holding the rows to insert (fresh-keyed set mutated)
   * @return the savepoint, or null when there were no rows to insert
   */
  public static System.Savepoint insertSignalRows(
    WorkflowSignalBatchPartition.ForwardSignalPartition part
  ) {
    if (part.unkeyedSignals.isEmpty() && part.keyedSignals.isEmpty()) {
      return null;
    }
    System.Savepoint sp = Database.setSavepoint();

    // Insert unkeyed signals (plain insert, unchanged at-least-once behavior).
    if (!part.unkeyedSignals.isEmpty()) {
      Database.insert(part.unkeyedSignals, true, AccessLevel.SYSTEM_MODE);
    }

    if (!part.keyedSignals.isEmpty()) {
      insertKeyedSignals(part, sp);
    }
    return sp;
  }

  /**
   * @description Inserts the keyed signal rows with allOrNone=false, recording
   * the instances whose insert won the race; swallows per-row DUPLICATE_VALUE
   * (another transaction won) but rolls back and rethrows on a genuine
   * non-duplicate error. Guard-clause flattened.
   * @param part the partition holding the keyed rows (fresh-keyed set mutated)
   * @param sp the savepoint to roll back on a genuine failure
   */
  private static void insertKeyedSignals(
    WorkflowSignalBatchPartition.ForwardSignalPartition part,
    System.Savepoint sp
  ) {
    Database.SaveResult[] srs = Database.insert(
      part.keyedSignals,
      false,
      AccessLevel.SYSTEM_MODE
    );
    String genuineError = null;
    for (Integer i = 0; i < srs.size(); i++) {
      Database.SaveResult sr = srs[i];
      if (sr.isSuccess()) {
        part.instancesWithFreshKeyedSignal.add(part.keyedSignalInstIds[i]);
        continue;
      }
      if (WorkflowStartService.isDuplicateSaveError(sr)) {
        continue;
      }
      if (genuineError == null) {
        genuineError = sr.getErrors()[0].getMessage();
      }
    }
    if (genuineError != null) {
      Database.rollback(sp);
      throw new WorkflowEngine.WorkflowException(
        'Failed to insert signal: ' + genuineError
      );
    }
  }

  /**
   * @description Wakes and enqueues the instances that received a fresh signal,
   * sharing the insert savepoint so the whole bulk call is all-or-none: the
   * status flip, enqueueOrchestrators, and enqueueResumeBulk can still throw
   * after the rows are committed, so on any failure the inserted rows are rolled
   * back and the enqueue guards cleared before rethrowing.
   * @param part the forward-signal partition
   * @param sp the shared insert savepoint (null when nothing was inserted)
   */
  public static void wakeAndEnqueueInstances(
    WorkflowSignalBatchPartition.ForwardSignalPartition part,
    System.Savepoint sp
  ) {
    try {
      // JOIN-READINESS BARRIER PRE-COMPUTATION
      Set<Id> gatedNonReadyParents = WorkflowSignalGating.getGatedNonReadyParents(
        part.activeInstById.values(),
        part.signalsByInstanceId
      );
      WakeSelection sel = selectInstancesToWake(part, gatedNonReadyParents);
      if (!sel.instancesToUpdate.isEmpty()) {
        Database.update(sel.instancesToUpdate, true, AccessLevel.SYSTEM_MODE);
      }
      dispatchWakeEnqueues(sel.activeInstances);
    } catch (Exception e) {
      if (sp != null) {
        Database.rollback(sp);
      }
      WorkflowEngine.clearEnqueueGuards(part.activeInstById.keySet());
      throw e;
    }
  }

  /**
   * @description Selects, once per instance, those that received at least one
   * fresh signal this call (unkeyed always qualifies; keyed only if the insert
   * won the race) and applies the per-instance wake decision.
   * @param part the forward-signal partition
   * @param gatedNonReadyParents parents still gated behind a non-ready join
   * @return the instances to flip to Running plus the instances to enqueue
   */
  private static WakeSelection selectInstancesToWake(
    WorkflowSignalBatchPartition.ForwardSignalPartition part,
    Set<Id> gatedNonReadyParents
  ) {
    WakeSelection sel = new WakeSelection();
    // Deduplicate: only process each active instance once.
    Set<Id> processedActiveIds = new Set<Id>();
    for (Workflow_Instance__c inst : part.activeInstById.values()) {
      if (processedActiveIds.contains(inst.Id)) {
        continue;
      }
      Boolean freshSignalLanded =
        part.instancesWithUnkeyedSignal.contains(inst.Id) ||
        part.instancesWithFreshKeyedSignal.contains(inst.Id);
      if (!freshSignalLanded) {
        continue;
      }
      processedActiveIds.add(inst.Id);
      applyWakeDecision(inst, gatedNonReadyParents, sel);
    }
    return sel;
  }

  /**
   * @description Applies the wake decision for one fresh-signalled instance. A
   * Suspended instance resumes to Running (its wait deadline disarmed) unless it
   * is concurrency-parked without a slot or gated behind a non-ready join, in
   * which case it is left alone and not enqueued. Compensating/Cancelling and
   * Running instances are enqueued (unless gated) without a status flip; a Paused
   * instance keeps its status and observes the held signal on resume.
   * @param inst the instance to decide on (status/Sleep_Until mutated on wake)
   * @param gatedNonReadyParents parents still gated behind a non-ready join
   * @param sel the wake selection to append to (mutated)
   */
  private static void applyWakeDecision(
    Workflow_Instance__c inst,
    Set<Id> gatedNonReadyParents,
    WakeSelection sel
  ) {
    if (inst.Status__c == 'Suspended') {
      // A concurrency-parked row has not won a slot. Waking it to Running would
      // leave a Running instance holding no slot (violating the no-running-without-
      // slot invariant) and hide it from the parked count. Like Paused, leave it
      // alone: the signal is already captured (Received) and is observed once
      // admission drives the step. Skip the wake and the enqueue entirely.
      if (
        inst.Concurrency_Parked__c == true &&
        inst.Concurrency_Slot_Held__c != true
      ) {
        return;
      }
      if (gatedNonReadyParents.contains(inst.Id)) {
        return;
      }
      inst.Status__c = 'Running';
      // Disarm the wait deadline (issue #35): a signal-wake ends the current
      // wait, so any armed Sleep_Until__c (timed-wait timeout, or a plain
      // sleeper's deadline) must be cleared or the watchdog would later
      // re-select this instance and mis-route/double-wake it. The resumed
      // step re-arms its own deadline if it suspends or sleeps again.
      inst.Sleep_Until__c = null;
      sel.instancesToUpdate.add(inst);
    }
    if (!gatedNonReadyParents.contains(inst.Id)) {
      sel.activeInstances.add(inst);
    }
  }

  /**
   * @description Enqueues the woken instances: a Compensating/Cancelling instance
   * rolls back serially and gets exactly one compensation wake (never per-branch
   * fan-out off a stale parallel step list); a forward parallel instance is
   * collected for a single bulk resume (one step-execution query for all, not one
   * per instance); everything else is enqueued once via the orchestrator.
   * @param activeInstances the instances to enqueue this call
   */
  private static void dispatchWakeEnqueues(
    List<Workflow_Instance__c> activeInstances
  ) {
    List<Id> instanceIdsToEnqueue = new List<Id>();
    List<Workflow_Instance__c> parallelInstances = new List<Workflow_Instance__c>();
    for (Workflow_Instance__c inst : activeInstances) {
      Boolean isCompensatingInst =
        inst.Status__c == 'Compensating' ||
        inst.Status__c == 'Cancelling';
      if (
        !isCompensatingInst &&
        String.isNotBlank(inst.Current_Step__c) &&
        inst.Current_Step__c.contains(',')
      ) {
        parallelInstances.add(inst);
        continue;
      }
      if (!WorkflowEngine.enqueuedInstanceIds.contains(inst.Id)) {
        WorkflowEngine.enqueuedInstanceIds.add(inst.Id);
        instanceIdsToEnqueue.add(inst.Id);
      }
    }
    WorkflowOrchestratorEnqueue.enqueueOrchestrators(instanceIdsToEnqueue);
    WorkflowEngine.enqueueResumeBulk(parallelInstances);
  }
}
