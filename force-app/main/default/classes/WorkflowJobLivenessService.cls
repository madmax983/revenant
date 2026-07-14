/**
 * @description Resolves the liveness of the CronTrigger / AsyncApexJob jobs referenced by
 * a set of workflow instances, and classifies what a Suspended instance is waiting on.
 * Extracted from WorkflowDashboardController so the instance-list and stalled endpoints
 * share one copy of the (SOQL-heavy) job-liveness logic. All SOQL runs WITH SYSTEM_MODE.
 */
public inherited sharing class WorkflowJobLivenessService {
  private static void collectJobId(
    String jobIdStr,
    Set<Id> cronIds,
    Set<Id> asyncIds
  ) {
    if (String.isBlank(jobIdStr)) {
      return;
    }
    if (
      (jobIdStr.length() == 15 || jobIdStr.length() == 18) &&
      (jobIdStr.startsWith('08e') || jobIdStr.startsWith('707'))
    ) {
      try {
        Id jobId = (Id) jobIdStr;
        if (jobId.getSobjectType() == CronTrigger.SObjectType) {
          cronIds.add(jobId);
        } else if (jobId.getSobjectType() == AsyncApexJob.SObjectType) {
          asyncIds.add(jobId);
        }
      } catch (Exception ignored) {
      }
    }
  }

  private static Set<Id> queryActiveCronIds(Set<Id> cronIds) {
    Set<Id> result = new Set<Id>();
    if (cronIds.isEmpty()) {
      return result;
    }
    for (CronTrigger ct : [
      SELECT Id
      FROM CronTrigger
      WHERE
        Id IN :cronIds
        AND State IN ('WAITING', 'ACQUIRED', 'QUEUED', 'EXECUTING')
      WITH SYSTEM_MODE
    ]) {
      result.add(ct.Id);
    }
    return result;
  }

  private static Set<Id> queryActiveAsyncIds(Set<Id> asyncIds) {
    Set<Id> result = new Set<Id>();
    if (asyncIds.isEmpty()) {
      return result;
    }
    for (AsyncApexJob aaj : [
      SELECT Id
      FROM AsyncApexJob
      WHERE
        Id IN :asyncIds
        AND Status IN ('Queued', 'Holding', 'Preparing', 'Processing')
      WITH SYSTEM_MODE
    ]) {
      result.add(aaj.Id);
    }
    return result;
  }

  /**
   * @description Returns the ids of the given instances that have a step execution with a
   * declared timeout.
   * @param instanceIds The instance ids to inspect.
   * @return The subset of ids with a timeout-bearing step execution.
   */
  public static Set<Id> queryInstancesWithStepTimeout(Set<Id> instanceIds) {
    Set<Id> result = new Set<Id>();
    if (instanceIds.isEmpty()) {
      return result;
    }
    for (Workflow_Step_Execution__c se : [
      SELECT Workflow_Instance__c
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c IN :instanceIds AND Timeout_At__c != NULL
      WITH SYSTEM_MODE
    ]) {
      result.add(se.Workflow_Instance__c);
    }
    return result;
  }

  /**
   * @description Returns the ids of the given instances that have a Pending step
   * execution (a parked signal/approval/child wait).
   * @param instanceIds The instance ids to inspect.
   * @return The subset of ids with a Pending step execution.
   */
  public static Set<Id> queryInstancesWithPendingStep(Set<Id> instanceIds) {
    Set<Id> result = new Set<Id>();
    if (instanceIds.isEmpty()) {
      return result;
    }
    for (Workflow_Step_Execution__c se : [
      SELECT Workflow_Instance__c
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c IN :instanceIds AND Status__c = 'Pending'
      WITH SYSTEM_MODE
    ]) {
      result.add(se.Workflow_Instance__c);
    }
    return result;
  }

  /**
   * @description Collects the active cron/async job ids referenced by the given instances
   * into the supplied (initially empty) sets. Shared by the filtered/stalled list and
   * count paths.
   * @param instances The instances whose Async_Job_Id__c values are inspected.
   * @param activeCronIds Output set receiving the live CronTrigger ids.
   * @param activeAsyncIds Output set receiving the live AsyncApexJob ids.
   */
  public static void loadActiveJobIds(
    List<Workflow_Instance__c> instances,
    Set<Id> activeCronIds,
    Set<Id> activeAsyncIds
  ) {
    Set<Id> cronIds = new Set<Id>();
    Set<Id> asyncIds = new Set<Id>();
    for (Workflow_Instance__c inst : instances) {
      collectJobId(inst.Async_Job_Id__c, cronIds, asyncIds);
    }
    activeCronIds.addAll(queryActiveCronIds(cronIds));
    activeAsyncIds.addAll(queryActiveAsyncIds(asyncIds));
  }

  /**
   * @description Resolves what a single instance is waiting on, using the pre-queried
   * active-job id sets. Non-Suspended instances wait on nothing.
   * @param inst The instance to classify.
   * @param activeCronIds The pre-queried live CronTrigger ids.
   * @param activeAsyncIds The pre-queried live AsyncApexJob ids.
   * @return The waiting-on hint, or null.
   */
  public static String computeWaitingOn(
    Workflow_Instance__c inst,
    Set<Id> activeCronIds,
    Set<Id> activeAsyncIds
  ) {
    if (inst.Status__c != 'Suspended') {
      return null;
    }
    if (String.isNotBlank(inst.Async_Job_Id__c)) {
      return classifyActiveJobWait(
        inst.Async_Job_Id__c,
        activeCronIds,
        activeAsyncIds
      );
    }
    if (inst.Sleep_Until__c != null) {
      return 'Watchdog';
    }
    return null;
  }

  // Maps a Suspended instance's job id to what it is waiting on, using the pre-queried
  // active-job id sets. A live scheduled cron → 'Scheduled Job', a live queueable →
  // 'Delayed Queueable'; anything else (dead job, non-job id, cast failure) → 'Watchdog'.
  private static String classifyActiveJobWait(
    String jobIdStr,
    Set<Id> activeCronIds,
    Set<Id> activeAsyncIds
  ) {
    if (!WorkflowDashboardSupport.isJobIdShaped(jobIdStr)) {
      return 'Watchdog';
    }
    try {
      Id jobId = (Id) jobIdStr;
      if (
        jobId.getSobjectType() == CronTrigger.SObjectType &&
        activeCronIds.contains(jobId)
      ) {
        return 'Scheduled Job';
      }
      if (
        jobId.getSobjectType() == AsyncApexJob.SObjectType &&
        activeAsyncIds.contains(jobId)
      ) {
        return 'Delayed Queueable';
      }
      return 'Watchdog';
    } catch (Exception ex) {
      return 'Watchdog';
    }
  }
}
