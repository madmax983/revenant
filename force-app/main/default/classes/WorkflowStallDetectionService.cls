/**
 * @description Determines whether a workflow instance is genuinely stalled (idle past
 * the threshold with no live job, sleep timer, declared timeout, or pending step), builds
 * the shared display rows for the instance lists, and classifies statuses into the
 * summary-tile buckets. Extracted from WorkflowDashboardController so the instance-list
 * and stalled endpoints share one copy of this pure (non-SOQL) logic.
 */
public inherited sharing class WorkflowStallDetectionService {
  /**
   * @description Per-instance signals feeding computeStalled, bundled so the check takes a
   * single context object instead of a long parameter list. Populated by the caller.
   */
  public class StallSignals {
    public Boolean hasStepTimeout;
    public Boolean hasPendingStep;
    public Long idleMinutes;
    public Integer thresholdMinutes;
  }

  /**
   * @description Evaluates whether an instance is genuinely stalled: Suspended, not waiting
   * on a live job, with no sleep timer, no declared step timeout, no pending step, and idle
   * beyond the threshold.
   * @param inst The instance to evaluate.
   * @param waitingOn The instance's resolved waiting-on hint.
   * @param sig The pre-computed stall signals for the instance.
   * @return True when the instance is genuinely stalled.
   */
  public static Boolean computeStalled(
    Workflow_Instance__c inst,
    String waitingOn,
    StallSignals sig
  ) {
    if (inst.Status__c != 'Suspended') {
      return false;
    }
    if (waitingOn == 'Scheduled Job' || waitingOn == 'Delayed Queueable') {
      return false;
    }
    if (inst.Sleep_Until__c != null) {
      return false;
    }
    if (sig.hasStepTimeout) {
      return false;
    }
    // Signal/approval/child-completion waits park a Pending step-exec row;
    // exclude them so only true orphans (no resume mechanism at all) are flagged.
    if (sig.hasPendingStep) {
      return false;
    }
    return sig.idleMinutes > sig.thresholdMinutes;
  }

  /**
   * @description Builds the display row shared by the filtered and stalled instance
   * lists. The caller adds the 'stalled' flag (and the filtered list also adds
   * Failure_Category__c, which the stalled query does not select), so neither is included
   * here.
   * @param inst The instance whose row is built.
   * @param waitingOn The instance's resolved waiting-on hint.
   * @param idleMinutes The instance's idle minutes.
   * @return The display-field map for the instance.
   */
  public static Map<String, Object> buildInstanceRow(
    Workflow_Instance__c inst,
    String waitingOn,
    Long idleMinutes
  ) {
    return new Map<String, Object>{
      'Id' => inst.Id,
      'Name' => inst.Name,
      'Workflow_Name__c' => inst.Workflow_Name__c,
      'Status__c' => inst.Status__c,
      'Correlation_Key__c' => inst.Correlation_Key__c,
      'CreatedDate' => inst.CreatedDate,
      'LastModifiedDate' => inst.LastModifiedDate,
      'Error_Message__c' => inst.Error_Message__c,
      'Async_Job_Id__c' => inst.Async_Job_Id__c,
      'Sleep_Until__c' => inst.Sleep_Until__c,
      'Deadline_At__c' => inst.Deadline_At__c,
      'waitingOn' => waitingOn,
      'idleMinutes' => idleMinutes
    };
  }

  // A candidate that passed the in-memory stalled check, carrying the derived display
  // values so callers can build rows without recomputing (and re-querying) job liveness.
  private class StalledCandidate {
    Workflow_Instance__c inst;
    String waitingOn;
    Long idleMinutes;

    StalledCandidate(
      Workflow_Instance__c inst,
      String waitingOn,
      Long idleMinutes
    ) {
      this.inst = inst;
      this.waitingOn = waitingOn;
      this.idleMinutes = idleMinutes;
    }
  }

  // Shared stalled-detection for the stalled list and count: resolves job liveness once
  // for the candidate set, then returns those genuinely stalled. Step-timeout and
  // pending-step instances are already excluded by the stalled WHERE-clause anti-joins,
  // so those signals are false here.
  private static List<StalledCandidate> filterStalledCandidates(
    List<Workflow_Instance__c> candidates,
    Integer threshold
  ) {
    Set<Id> activeCronIds = new Set<Id>();
    Set<Id> activeAsyncIds = new Set<Id>();
    WorkflowJobLivenessService.loadActiveJobIds(
      candidates,
      activeCronIds,
      activeAsyncIds
    );

    Long nowMs = Datetime.now().getTime();
    List<StalledCandidate> stalled = new List<StalledCandidate>();
    for (Workflow_Instance__c inst : candidates) {
      String waitingOn = WorkflowJobLivenessService.computeWaitingOn(
        inst,
        activeCronIds,
        activeAsyncIds
      );
      Long idleMinutes = Math.max(
        0L,
        (nowMs - inst.LastModifiedDate.getTime()) / 60000L
      );
      StallSignals sig = new StallSignals();
      sig.hasStepTimeout = false;
      sig.hasPendingStep = false;
      sig.idleMinutes = idleMinutes;
      sig.thresholdMinutes = threshold;
      if (computeStalled(inst, waitingOn, sig)) {
        stalled.add(new StalledCandidate(inst, waitingOn, idleMinutes));
      }
    }
    return stalled;
  }

  /**
   * @description Filters the candidate set to genuinely stalled instances and renders
   * their display rows (each flagged stalled=true), before the caller paginates.
   * @param candidates The candidate instances scanned by the stalled query.
   * @param threshold The stale threshold in minutes.
   * @return The stalled display rows, in candidate (LastModifiedDate ASC) order.
   */
  public static List<Map<String, Object>> buildStalledRows(
    List<Workflow_Instance__c> candidates,
    Integer threshold
  ) {
    List<StalledCandidate> stalled = filterStalledCandidates(
      candidates,
      threshold
    );
    List<Map<String, Object>> stalledRows = new List<Map<String, Object>>();
    for (StalledCandidate sc : stalled) {
      Map<String, Object> row = buildInstanceRow(
        sc.inst,
        sc.waitingOn,
        sc.idleMinutes
      );
      row.put('stalled', true);
      stalledRows.add(row);
    }
    return stalledRows;
  }

  /**
   * @description Counts the genuinely stalled instances in the candidate set.
   * @param candidates The candidate instances scanned by the stalled query.
   * @param threshold The stale threshold in minutes.
   * @return The number of stalled instances.
   */
  public static Integer countStalledCandidates(
    List<Workflow_Instance__c> candidates,
    Integer threshold
  ) {
    return filterStalledCandidates(candidates, threshold).size();
  }

  /**
   * @description Adds a per-status aggregate count into the total plus its
   * active/completed/failed bucket (statuses outside the three buckets still count toward
   * total only).
   * @param results The running totals map to mutate.
   * @param stat The status being bucketed.
   * @param count The aggregate count for the status.
   */
  public static void bucketWorkflowStat(
    Map<String, Integer> results,
    String stat,
    Integer count
  ) {
    results.put('total', results.get('total') + count);
    if (isActiveStat(stat)) {
      results.put('active', results.get('active') + count);
    } else if (stat == 'Completed' || stat == 'ContinuedAsNew') {
      results.put('completed', results.get('completed') + count);
    } else if (isFailedStat(stat)) {
      results.put('failed', results.get('failed') + count);
    }
  }

  private static Boolean isActiveStat(String stat) {
    return stat == 'Pending' ||
      stat == 'Running' ||
      stat == 'Suspended' ||
      stat == 'Compensating' ||
      stat == 'Cancelling' ||
      stat == 'Paused';
  }

  private static Boolean isFailedStat(String stat) {
    return stat == 'Failed' ||
      stat == 'CompensationFailed' ||
      stat == 'Compensated' ||
      stat == 'Cancelled';
  }
}
