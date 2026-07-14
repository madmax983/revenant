/**
 * Parked-instance resume/drain machinery lifted out of WorkflowPauseGate.
 *
 * When a definition (or the org-wide wildcard) is resumed, every instance that
 * was parked (Status__c = 'Paused') must be flipped back to Running and re-driven.
 * A long-lived or org-wide pause can park more rows than a single transaction can
 * safely update, so the backlog is drained in bounded chunks: the first chunk runs
 * synchronously on the operator's resume action and any remainder is drained by a
 * chained Queueable (off the synchronous path, governor-safe).
 *
 * ENTRY POINT
 *   WorkflowPauseGate.resumeDefinition calls resumeParkedChunk once the pause
 *   record(s) are deleted. Each chunk re-queries only still-Paused rows and
 *   enqueues its own continuation when a full chunk was processed, so completed
 *   instances are naturally excluded with no offset paging.
 *
 * ORDERING (behavior-sensitive — drives parked-workflow resumption)
 *   Within a chunk: (1) flip rows to Running via a single update, (2) reserve the
 *   queueable slot for the next drain continuation BEFORE re-arming timeouts,
 *   (3) re-arm step timeouts, (4) enqueue the resumed workers (serial via the
 *   engine bulk orchestrator enqueue, parallel via per-branch platform-event
 *   fan-out). This order is preserved exactly from the original gate.
 */
public inherited sharing class WorkflowPauseResumeDrainer {
  // Max parked instances flipped back to Running per transaction on resume; the
  // remainder is drained by a chained Queueable. @TestVisible so tests can lower
  // it to exercise the chunk boundary without inserting hundreds of rows.
  @TestVisible
  private static Integer resumeChunkSize = 200;

  // Flips up to resumeChunkSize parked instances for the scope back to Running
  // and re-enqueues them (serial via bulk publish, parallel via branch fan-out).
  // Returns true if a full chunk was processed, meaning more may remain to drain.
  // Each call re-queries only still-Paused rows, so already-resumed instances
  // (now Running) are naturally excluded — no offset paging needed.
  /**
   * @description Flips up to one chunk of parked instances for the scope back to
   * Running, re-arms their timeouts, and enqueues the resumed workers; enqueues
   * its own drain continuation when a full chunk was processed.
   * @param workflowName The definition scope to drain, or '*' for org-wide.
   * @return True when a full chunk was processed, meaning more may remain to drain.
   */
  public static Boolean resumeParkedChunk(String workflowName) {
    List<Workflow_Instance__c> parked = loadParkedChunk(workflowName);
    if (parked.isEmpty()) {
      return false;
    }

    List<Workflow_Instance__c> toUpdate = new List<Workflow_Instance__c>();
    List<Id> serialIds = new List<Id>();
    List<Workflow_Instance__c> parallelInsts = new List<Workflow_Instance__c>();

    for (Workflow_Instance__c inst : parked) {
      inst.Status__c = 'Running';
      toUpdate.add(inst);

      if (
        String.isNotBlank(inst.Current_Step__c) &&
        inst.Current_Step__c.contains(',')
      ) {
        parallelInsts.add(inst);
      } else {
        serialIds.add(inst.Id);
      }
    }
    update as system toUpdate;

    Boolean moreRemain = parked.size() == resumeChunkSize;
    enqueueDrainContinuation(workflowName, moreRemain);

    // Re-arm step timeouts BEFORE enqueueing the resumed workers, so a delayed worker
    // (or a step that defers its pre-exec DML) still has an enforced watchdog deadline.
    WorkflowEngine.reArmTimeoutsForResume(toUpdate);

    enqueueResumedWorkers(serialIds, parallelInsts);

    return moreRemain;
  }

  // Selects up to resumeChunkSize still-Paused instances for the scope, locking them so
  // concurrent drains don't double-resume.
  /**
   * @description Selects up to one chunk of still-Paused instances for the scope,
   * locking them FOR UPDATE so concurrent drains do not double-resume.
   * @param workflowName The definition scope to load, or '*' for org-wide.
   * @return The locked parked instances to flip back to Running.
   */
  private static List<Workflow_Instance__c> loadParkedChunk(
    String workflowName
  ) {
    if (workflowName == '*') {
      return [
        SELECT Id, Current_Step__c, Status__c, Compensation_Stack__c
        FROM Workflow_Instance__c
        WHERE Status__c = 'Paused'
        WITH SYSTEM_MODE
        LIMIT :resumeChunkSize
        FOR UPDATE
      ];
    }
    return [
      SELECT Id, Current_Step__c, Status__c, Compensation_Stack__c
      FROM Workflow_Instance__c
      WHERE Status__c = 'Paused' AND Workflow_Name__c = :workflowName
      WITH SYSTEM_MODE
      LIMIT :resumeChunkSize
      FOR UPDATE
    ];
  }

  // Reserve the queueable slot for the next drain chunk BEFORE re-arming timeouts.
  // reArmTimeoutsForResume enqueues best-effort timeout queueables that can consume
  // every available slot; the drain is load-bearing (skipping it strands the parked
  // backlog), so it must claim its slot first. The timeout jobs that follow fall back
  // to System.schedule when no slot remains and retain their watchdog Timeout_At__c
  // safety net. Both callers (resumeDefinition and ResumeChunkQueueable) route the
  // continuation through here so the reservation is applied uniformly and guarded.
  /**
   * @description Reserves the queueable slot for the next drain chunk before
   * timeouts are re-armed, enqueueing the drain continuation only when more
   * chunks remain, outside tests, and a queueable slot is available.
   * @param workflowName The definition scope to continue draining, or '*'.
   * @param moreRemain Whether a full chunk was processed, so more may remain.
   */
  private static void enqueueDrainContinuation(
    String workflowName,
    Boolean moreRemain
  ) {
    if (
      moreRemain &&
      !Test.isRunningTest() &&
      Limits.getQueueableJobs() < Limits.getLimitQueueableJobs()
    ) {
      System.enqueueJob(new ResumeChunkQueueable(workflowName));
    }
  }

  // Enqueues the resumed workers: serial instances via the engine's bulk orchestrator
  // enqueue, parallel (multi-branch) instances via per-branch fan-out.
  /**
   * @description Enqueues the resumed workers: serial instances via the engine's
   * bulk orchestrator enqueue and parallel (multi-branch) instances via per-branch
   * fan-out.
   * @param serialIds Ids of single-branch instances to enqueue serially.
   * @param parallelInsts Multi-branch instances to fan out per branch.
   */
  private static void enqueueResumedWorkers(
    List<Id> serialIds,
    List<Workflow_Instance__c> parallelInsts
  ) {
    // Honor the engine's test opt-out so a suite asserting only the
    // Paused -> Running resume transition is not carried to completion by a
    // worker draining at Test.stopTest() (mirrors the watchdog enqueue guards).
    if (
      !serialIds.isEmpty() &&
      !(Test.isRunningTest() && WorkflowEngine.disableQueueableInTest)
    ) {
      WorkflowEngine.enqueueOrchestrators(serialIds);
    }
    if (!parallelInsts.isEmpty()) {
      enqueueResumeBulkParallel(parallelInsts);
    }
  }

  // Drains the remaining parked-instance backlog for a resumed scope in chunks,
  // re-chaining until none remain. Kept off the synchronous resume path so a
  // large backlog cannot exceed governor limits in a single transaction.
  /**
   * @description Queueable that drains the remaining parked-instance backlog for
   * a resumed scope in governor-safe chunks, re-chaining until none remain.
   */
  public class ResumeChunkQueueable implements Queueable {
    /** @description The definition scope to drain, or '*' for org-wide. */
    private final String workflowName;
    /**
     * @description Constructs the drain job for a resumed scope.
     * @param workflowName The definition scope to drain, or '*' for org-wide.
     */
    public ResumeChunkQueueable(String workflowName) {
      this.workflowName = workflowName;
    }
    /**
     * @description Drains one chunk of parked instances, attaching a finalizer
     * to surface any mid-drain failure; the chunk chains its own continuation.
     * @param ctx The Queueable execution context.
     */
    public void execute(QueueableContext ctx) {
      // Attach a finalizer so an unhandled failure mid-drain is surfaced to the log
      // sink rather than vanishing. The finalizer runs even if execute() throws.
      System.attachFinalizer(new ResumeChunkFinalizer(this.workflowName));
      // resumeParkedChunk chains the next continuation itself (reserving the single
      // queueable slot allowed in this context for the drain ahead of best-effort
      // timeout jobs), so no re-chain is needed here.
      resumeParkedChunk(this.workflowName);
    }
  }

  // Best-effort failure sink for the parked-instance drain. On an unhandled exception in
  // ResumeChunkQueueable the drain chain would otherwise stop silently, stranding the
  // remaining Paused backlog; this records the failure so operators can see it. The
  // success path is untouched (it only acts on UNHANDLED_EXCEPTION).
  /**
   * @description Best-effort failure sink for the parked-instance drain; on an
   * unhandled exception it logs the failure so a stalled drain chain is visible
   * to operators rather than stranding the Paused backlog silently.
   */
  public class ResumeChunkFinalizer implements Finalizer {
    /** @description The definition scope being drained, or '*'. */
    private final String workflowName;
    /**
     * @description Constructs the finalizer for a resumed scope.
     * @param workflowName The definition scope being drained, or '*'.
     */
    public ResumeChunkFinalizer(String workflowName) {
      this.workflowName = workflowName;
    }
    /**
     * @description Logs the drain failure when the job ended in an unhandled
     * exception; otherwise does nothing.
     * @param ctx The finalizer context carrying the parent job result.
     */
    public void execute(FinalizerContext ctx) {
      if (
        ctx == null ||
        ctx.getResult() != ParentJobResult.UNHANDLED_EXCEPTION
      ) {
        return;
      }
      Exception ex = ctx.getException();
      String detail = (ex == null) ? 'unknown error' : ex.getMessage();
      // WorkflowLog.error swallows its own DML failures, so this stays best-effort.
      WorkflowLog.error(
        new WorkflowLog.ErrorEntry(
            'WorkflowPauseGate.ResumeChunkQueueable',
            'Parked-instance resume drain failed for scope "' +
              workflowName +
              '": ' +
              detail
          )
          .withWorkflowName(workflowName)
      );
    }
  }

  // Fan-out a resume enqueue per unfinished parallel branch (mirrors the logic
  // in WorkflowEngine.enqueueResumeBulk but called from outside the engine). The
  // production path collects one RUN_STEP event per branch and publishes them in a
  // single EventBus.publish; the test path dispatches per branch directly.
  /**
   * @description Fans out a resume enqueue per unfinished parallel branch, mirroring
   * WorkflowEngine.enqueueResumeBulk: resolve per-branch status, collect the
   * RUN_STEP events for unfinished branches, then publish them in one call.
   * @param instances The resumed multi-branch instances to fan out.
   */
  private static void enqueueResumeBulkParallel(
    List<Workflow_Instance__c> instances
  ) {
    Map<String, String> latestStatusByKey = resolveLatestBranchStatus(
      instances
    );
    List<Workflow_Event__e> events = collectResumeBranchEvents(
      instances,
      latestStatusByKey
    );
    publishResumeEvents(events);
  }

  // Current_Step__c retains every branch name until the join, including ones
  // whose step row is already Completed. Resolve the latest status per
  // (instance, branch) so completed branches can be skipped — driving a no-op
  // worker per finished branch would waste the resume publish/DML budget and
  // could roll back the resume (mirrors WorkflowEngine.enqueueResumeBulk).
  /**
   * @description Resolves the latest status per (instance, branch) so already
   * Completed branches can be skipped, keyed by "instanceId|stepName".
   * @param instances The resumed multi-branch instances whose branches to resolve.
   * @return The latest status per (instance, branch) key.
   */
  private static Map<String, String> resolveLatestBranchStatus(
    List<Workflow_Instance__c> instances
  ) {
    Set<Id> instanceIds = new Set<Id>();
    Set<String> branchNames = new Set<String>();
    for (Workflow_Instance__c inst : instances) {
      instanceIds.add(inst.Id);
      for (String branch : inst.Current_Step__c.split(',')) {
        branchNames.add(branch.trim());
      }
    }

    Map<String, String> latestStatusByKey = new Map<String, String>();
    for (Workflow_Step_Execution__c se : [
      SELECT Workflow_Instance__c, Step_Name__c, Status__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c IN :instanceIds
        AND Step_Name__c IN :branchNames
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC, Id DESC
    ]) {
      String statusKey = se.Workflow_Instance__c + '|' + se.Step_Name__c;
      if (!latestStatusByKey.containsKey(statusKey)) {
        latestStatusByKey.put(statusKey, se.Status__c);
      }
    }
    return latestStatusByKey;
  }

  // Walks each instance's branches once, skipping completed and duplicate branches, and
  // dispatches a worker for each unfinished branch. Returns the RUN_STEP events to be
  // published (empty in test context, where dispatchBranch enqueues directly instead).
  /**
   * @description Walks each instance's branches once, skipping Completed and
   * duplicate branches, and dispatches a worker per unfinished branch.
   * @param instances The resumed multi-branch instances to walk.
   * @param latestStatusByKey The latest status per (instance, branch) key.
   * @return The RUN_STEP events to publish (empty in test context, where
   * dispatchBranch enqueues directly instead).
   */
  private static List<Workflow_Event__e> collectResumeBranchEvents(
    List<Workflow_Instance__c> instances,
    Map<String, String> latestStatusByKey
  ) {
    List<Workflow_Event__e> events = new List<Workflow_Event__e>();
    Set<String> branchKeys = new Set<String>();
    for (Workflow_Instance__c inst : instances) {
      for (String branch : inst.Current_Step__c.split(',')) {
        String trimmed = branch.trim();
        String key = inst.Id + '|' + trimmed;
        if (latestStatusByKey.get(key) == 'Completed') {
          continue; // branch already finished — no worker needed
        }
        if (branchKeys.contains(key)) {
          continue; // already dispatched this (instance, branch)
        }
        branchKeys.add(key);
        dispatchBranch(inst.Id, trimmed, events);
      }
    }
    return events;
  }

  // Dispatches a single resumed branch. In production it accumulates a RUN_STEP event
  // for the caller's bulk publish; in test context platform events don't deliver
  // synchronously, so it enqueues the orchestrator directly (there is no bulk enqueue
  // API — jobs are inherently one-per-call). Isolating one branch's dispatch keeps the
  // caller a clean collect-loop.
  /**
   * @description Dispatches a single resumed branch: in production it accumulates a
   * RUN_STEP event for the caller's bulk publish; in test context it enqueues the
   * orchestrator directly since platform events do not deliver synchronously.
   * @param instanceId The resumed instance's Id.
   * @param branch The branch (step) name being resumed.
   * @param events The accumulator the production path appends the RUN_STEP event to.
   */
  private static void dispatchBranch(
    Id instanceId,
    String branch,
    List<Workflow_Event__e> events
  ) {
    if (!Test.isRunningTest()) {
      events.add(
        new Workflow_Event__e(
          Workflow_Instance_Id__c = instanceId,
          Event_Type__c = 'RUN_STEP',
          Payload__c = branch
        )
      );
      return;
    }
    if (Limits.getQueueableJobs() < Limits.getLimitQueueableJobs()) {
      System.enqueueJob(new WorkflowOrchestrator(instanceId, branch));
    }
  }

  // Publishes the collected resume events in one call and fails the transaction if any
  // branch event is rejected — a rejected event would leave that branch Running with no
  // worker to drive it, so surfacing it rolls back the resume rather than stranding it.
  /**
   * @description Publishes the collected resume events in one call and fails the
   * transaction if any branch event is rejected, rolling back the resume rather
   * than leaving a branch Running with no worker to drive it.
   * @param events The RUN_STEP events to publish (a no-op when empty).
   */
  private static void publishResumeEvents(List<Workflow_Event__e> events) {
    if (events.isEmpty()) {
      return;
    }
    for (Database.SaveResult sr : EventBus.publish(events)) {
      if (sr.isSuccess()) {
        continue;
      }
      String msg = (sr.getErrors() != null && !sr.getErrors().isEmpty())
        ? sr.getErrors()[0].getMessage()
        : 'unknown error';
      throw new WorkflowPauseGate.PauseException(
        'Failed to publish resume event for a parallel branch: ' + msg
      );
    }
  }
}
