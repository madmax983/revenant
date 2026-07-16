/**
 * @description Orphan-rescue and reclaim sweeps for the watchdog heartbeat (§5,
 * §6). Rescues transient-lock retry branches orphaned under a non-Suspended
 * parallel parent, and auto-reclaims instances stuck in a self-driving status
 * whose referenced async job is no longer alive (query candidates → FOR UPDATE
 * lock → re-confirm liveness → reclaim).
 *
 * Extracted from WorkflowEngine as part of the watchdog decomposition; driven by
 * WorkflowHeartbeatService. All DML and SOQL run in system mode so the engine can
 * drive workflows regardless of the invoking user's object permissions.
 */
public inherited sharing class WorkflowOrphanReclaimSweep {
  /**
   * @description §5. Rescue transient-lock retry branches orphaned when a
   * parallel sibling that completed during the backoff flipped the parent out of
   * Suspended (e.g. a CompensatableStep persisting the parent as Running). The
   * sleep-resume section only selects Suspended parents, so such a retry branch
   * would otherwise never be re-driven and the workflow would hang.
   * Sleep_Until__c survives on the instance, so re-drive any due retry-marked
   * branch under a non-terminal, non-Suspended (Running) parallel parent.
   * Best-effort like the sweeps above: a publish hiccup retries on the next
   * heartbeat (Sleep_Until__c is left intact) instead of aborting the core
   * wake/timeout work. Self-resolving — once re-driven the branch either succeeds
   * (counter resets to 0) or re-crashes back to Suspended (handled above).
   * @param now the heartbeat evaluation instant
   */
  public static void rescueOrphanedTransientRetryBranches(Datetime now) {
    try {
      if (WorkflowPauseGate.wildcardPaused()) {
        return;
      }
      Set<String> orphanPausedDefs = WorkflowPauseGate.pausedNames();
      Integer resumeLimit = WorkflowSleepResumeSweep.resumeBatchSize();
      WorkflowTimeoutReArm.reDriveTransientRetryBranches(
        [
          SELECT
            Id,
            Workflow_Instance__c,
            Step_Name__c,
            Workflow_Instance__r.Workflow_Name__c
          FROM Workflow_Step_Execution__c
          WHERE
            Transient_Retry_Count__c > 0
            AND Status__c IN ('Pending', 'Running')
            AND Workflow_Instance__r.Status__c = 'Running'
            AND Workflow_Instance__r.Sleep_Until__c != NULL
            AND Workflow_Instance__r.Sleep_Until__c <= :now
            AND Workflow_Instance__r.Current_Step__c LIKE '%,%'
            AND Workflow_Instance__r.Workflow_Name__c NOT IN :orphanPausedDefs
          WITH SYSTEM_MODE
          LIMIT :resumeLimit
        ]
      );
    } catch (Exception ignored) {
      // Best-effort re-drive; Sleep_Until__c is left intact so the next heartbeat retries.
    }
  }

  /**
   * @description §6. Auto-reclaim orphaned instances. Sweeps for instances stuck
   * in a self-driving status (Pending/Running/Compensating/Cancelling) whose
   * referenced async job is no longer alive, and re-enqueues them at their last
   * durable step.
   * @param now the heartbeat evaluation instant
   */
  public static void autoReclaimOrphanedInstances(Datetime now) {
    try {
      if (
        WorkflowEngine.reclaimThresholdMinutes == null ||
        WorkflowEngine.reclaimThresholdMinutes <= 0 ||
        WorkflowPauseGate.wildcardPaused()
      ) {
        return;
      }
      Set<String> pausedDefNames = WorkflowPauseGate.pausedNames();
      List<Workflow_Instance__c> candidates = [
        SELECT
          Id,
          Name,
          Status__c,
          Current_Step__c,
          Compensation_Stack__c,
          Async_Job_Id__c,
          Workflow_Name__c,
          Correlation_Key__c
        FROM Workflow_Instance__c
        WHERE
          Status__c IN ('Pending', 'Running', 'Compensating', 'Cancelling')
          AND LastModifiedDate <= :now.addMinutes(
            -WorkflowEngine.reclaimThresholdMinutes
          )
          AND Workflow_Name__c NOT IN :pausedDefNames
        WITH SYSTEM_MODE
        ORDER BY LastModifiedDate ASC, Id ASC
        LIMIT 50
      ];

      if (candidates.isEmpty()) {
        return;
      }

      Set<Id> orphanIds = findOrphanCandidateIds(candidates);
      if (orphanIds.isEmpty()) {
        return;
      }

      List<Workflow_Instance__c> lockedOrphans = [
        SELECT
          Id,
          Name,
          Status__c,
          Current_Step__c,
          Compensation_Stack__c,
          Async_Job_Id__c,
          Workflow_Name__c,
          Correlation_Key__c,
          LastModifiedDate
        FROM Workflow_Instance__c
        WHERE
          Id IN :orphanIds
          AND Status__c IN ('Pending', 'Running', 'Compensating', 'Cancelling')
        WITH SYSTEM_MODE
        FOR UPDATE
      ];

      if (lockedOrphans.isEmpty()) {
        return;
      }

      // Re-check liveness of the locked candidates to make sure they didn't
      // progress in the race window.
      List<Workflow_Instance__c> confirmedOrphans = confirmLockedOrphans(
        lockedOrphans,
        now
      );

      if (!confirmedOrphans.isEmpty()) {
        WorkflowReclaim.reclaimOrphanedInstances(confirmedOrphans);
      }
    } catch (Exception ignored) {
      // Best-effort sweep; a failure here must not abort the watchdog heartbeat.
    }
  }

  // First-pass orphan detection: return the ids of candidate instances whose
  // referenced async job is no longer alive.
  private static Set<Id> findOrphanCandidateIds(
    List<Workflow_Instance__c> candidates
  ) {
    Set<Id> activeJobIds = WorkflowJobLiveness.resolveActiveJobIds(
      WorkflowJobLiveness.collectValidJobIds(candidates)
    );
    Set<Id> orphanIds = new Set<Id>();
    for (Workflow_Instance__c inst : candidates) {
      if (WorkflowJobLiveness.isInstanceOrphaned(inst, activeJobIds)) {
        orphanIds.add(inst.Id);
      }
    }
    return orphanIds;
  }

  // Second-pass confirmation under the FOR UPDATE lock: drop any instance that
  // progressed recently and re-check liveness of the rest.
  private static List<Workflow_Instance__c> confirmLockedOrphans(
    List<Workflow_Instance__c> lockedOrphans,
    Datetime now
  ) {
    Set<Id> lockedActiveJobIds = WorkflowJobLiveness.resolveActiveJobIds(
      WorkflowJobLiveness.collectValidJobIds(lockedOrphans)
    );
    List<Workflow_Instance__c> confirmedOrphans = new List<Workflow_Instance__c>();
    for (Workflow_Instance__c inst : lockedOrphans) {
      if (
        inst.LastModifiedDate >
        now.addMinutes(-WorkflowEngine.reclaimThresholdMinutes)
      ) {
        continue; // legitimately progressed/touched recently
      }
      if (WorkflowJobLiveness.isInstanceOrphaned(inst, lockedActiveJobIds)) {
        confirmedOrphans.add(inst);
      }
    }
    return confirmedOrphans;
  }
}
