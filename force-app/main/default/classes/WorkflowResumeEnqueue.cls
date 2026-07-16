/**
 * @description Resume/wake enqueue subsystem for the workflow engine. Owns the
 * per-transaction enqueue-dedup guards and the resume fan-out that wakes a
 * suspended instance — serially, or per parallel branch via a single batched
 * EventBus publish — plus the signal-arrival wake and the guard-clearing used to
 * unwind a rolled-back wake. Extracted from `WorkflowEngine` so the engine sheds
 * this cross-called cluster toward a thin facade; callers invoke every entry
 * qualified. All DML and SOQL run in system mode. The `WorkflowEngine.WorkflowException`
 * type is referenced fully qualified.
 */
public inherited sharing class WorkflowResumeEnqueue {
  // Public so the extracted signal-routing and signal-or-start services can
  // apply the same instance-level enqueue dedup as the resident resume path.
  @TestVisible
  public static Set<Id> enqueuedInstanceIds = new Set<Id>();
  // Per-(instance, branch) enqueue dedup so resuming a parallel instance can
  // wake each branch by name without the instance-level dedup blocking siblings.
  // Public so the split-out branch fan-out ({@link WorkflowBranchResume}) shares
  // the same per-branch guard while the guard-clearing stays with the owner here.
  @TestVisible
  public static Set<String> enqueuedBranchKeys = new Set<String>();

  /**
   * Removes the given instances (and their parallel branch keys) from the static
   * enqueue guards. Called after a wake-up failure is rolled back so a caller
   * that catches the exception and retries in the same transaction can re-enqueue
   * the resume — otherwise the guard would suppress the retry's wake and leave
   * the workflow unwoken despite the re-inserted signal.
   * @param instanceIds instances whose enqueue guards (and branch keys) are cleared
   */
  public static void clearEnqueueGuards(Set<Id> instanceIds) {
    if (instanceIds == null || instanceIds.isEmpty()) {
      return;
    }
    enqueuedInstanceIds.removeAll(instanceIds);
    if (!enqueuedBranchKeys.isEmpty()) {
      Set<String> toRemove = new Set<String>();
      for (String branchKey : enqueuedBranchKeys) {
        for (Id instanceId : instanceIds) {
          if (branchKey.startsWith(instanceId + '::')) {
            toRemove.add(branchKey);
            break;
          }
        }
      }
      enqueuedBranchKeys.removeAll(toRemove);
    }
  }

  /**
   * Wakes an instance after a routed signal lands. A Suspended instance flips to
   * Running; a Running/Compensating/Cancelling instance is re-driven in place (a
   * compensation step can depend on inbound signals, so it is woken rather than
   * rejected). A Paused instance keeps its status — the held signal is observed
   * when resume re-drives the wait step.
   * @param instance the routed target instance to wake in place
   */
  public static void wakeInstanceForSignal(Workflow_Instance__c instance) {
    // A concurrency-parked row is stored as an ordinary Suspended instance but has
    // not yet won an admission slot. Waking it to Running would leave a Running
    // instance holding no slot (violating the no-running-without-slot invariant) and
    // hide it from the parked count. The signal is already captured (Received) and is
    // observed once admission drives the step, so skip the wake and the enqueue
    // entirely — mirroring the guard in the bulk signal(List<SignalRequest>) path.
    if (
      instance.Status__c == 'Suspended' &&
      instance.Concurrency_Parked__c == true &&
      instance.Concurrency_Slot_Held__c != true
    ) {
      return;
    }
    if (
      instance.Status__c == 'Suspended' ||
      instance.Status__c == 'Running' ||
      instance.Status__c == 'Compensating' ||
      instance.Status__c == 'Cancelling'
    ) {
      if (instance.Status__c == 'Suspended') {
        instance.Status__c = 'Running';
        // Disarm the wait deadline (issue #35): a signal-wake ends the current
        // wait, so any armed Sleep_Until__c (timed-wait timeout, or a plain
        // sleeper's deadline) must be cleared or the watchdog would later
        // re-select this instance and mis-route/double-wake it. The resumed step
        // re-arms its own deadline if it suspends or sleeps again.
        instance.Sleep_Until__c = null;
        Database.update(instance, true, AccessLevel.SYSTEM_MODE);
      }
      enqueueResume(instance.Id);
    }
  }

  /**
   * @description Wakes a (possibly parallel) instance to resume execution. When
   * Current_Step__c is a parallel branch list, each still-incomplete branch is
   * enqueued by its own step name: runStep returns early for a comma-separated
   * Current_Step__c with a blank stepName, so a single blank enqueue would never
   * resume a branch suspended on a signal. A serial instance is enqueued once
   * with a null stepName. Public so the extracted `WorkflowStepRunner` admission
   * gate can re-drive an instance after clearing concurrency-park markers.
   * @param instanceId Id of the instance to wake and enqueue for resume
   */
  public static void enqueueResume(Id instanceId) {
    List<Workflow_Instance__c> rows = [
      SELECT Id, Current_Step__c, Status__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
      WITH SYSTEM_MODE
      LIMIT 1
    ];
    String currentStep = rows.isEmpty() ? null : rows[0].Current_Step__c;
    // A Compensating/Cancelling instance rolls back serially off the LIFO stack,
    // so it needs a single compensation wake, never per-branch fan-out -- even if
    // Current_Step__c still holds a stale comma-separated parallel branch list from
    // the forward phase. Only forward parallel instances fan out per branch.
    Boolean isCompensatingInst =
      !rows.isEmpty() &&
      (rows[0].Status__c == 'Compensating' ||
      rows[0].Status__c == 'Cancelling');

    if (
      !isCompensatingInst &&
      String.isNotBlank(currentStep) &&
      currentStep.contains(',')
    ) {
      // Delegate to the batched bulk path (single-element list) so a parallel
      // instance with many unfinished branches publishes one EventBus call
      // rather than one publish per branch (which could exceed the 150
      // publish/DML-statement limit).
      WorkflowBranchResume.enqueueResumeBulk(rows);
      return;
    }

    // Serial resume.
    enqueueSerialResume(instanceId);
  }

  /**
   * Serial resume enqueue: dedups per instance, then enqueues the orchestrator
   * directly under test, or via queueable (falling back to the platform-event
   * path when the queueable budget is exhausted or the enqueue throws).
   * @param instanceId the instance to resume
   */
  private static void enqueueSerialResume(Id instanceId) {
    if (enqueuedInstanceIds.contains(instanceId)) {
      return;
    }
    enqueuedInstanceIds.add(instanceId);
    if (Test.isRunningTest()) {
      if (!WorkflowEngine.disableQueueableInTest) {
        System.enqueueJob(new WorkflowOrchestrator(instanceId));
      }
      return;
    }
    try {
      if (Limits.getQueueableJobs() < Limits.getLimitQueueableJobs()) {
        System.enqueueJob(new WorkflowOrchestrator(instanceId));
      } else {
        WorkflowOrchestratorEnqueue.enqueueOrchestrator(instanceId, null);
      }
    } catch (Exception ignored) {
      // Queueable enqueue failed; fall back to the Platform Event path.
      WorkflowOrchestratorEnqueue.enqueueOrchestrator(instanceId, null);
    }
  }
}
