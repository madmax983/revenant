/**
 * @description Async-job liveness helpers for the orphan-reclaim sweep (§6).
 * Resolves which of an instance's referenced CronTrigger/AsyncApexJob ids are
 * still alive and decides whether an instance is orphaned (no job, a malformed
 * id, or a well-formed id that is no longer running).
 *
 * Extracted from WorkflowEngine as part of the watchdog decomposition; used by
 * WorkflowOrphanReclaimSweep. All SOQL runs in system mode so the engine can
 * drive workflows regardless of the invoking user's object permissions.
 */
public inherited sharing class WorkflowJobLiveness {
  /**
   * @description Collect the well-formed CronTrigger/AsyncApexJob ids referenced
   * by the given instances' Async_Job_Id__c.
   * @param insts the candidate instances whose job ids are collected
   * @return the set of well-formed job ids to check for liveness
   */
  public static Set<Id> collectValidJobIds(List<Workflow_Instance__c> insts) {
    Set<Id> jobIds = new Set<Id>();
    for (Workflow_Instance__c inst : insts) {
      if (String.isBlank(inst.Async_Job_Id__c)) {
        continue;
      }
      String jobIdStr = inst.Async_Job_Id__c;
      if (
        !((jobIdStr.length() == 15 || jobIdStr.length() == 18) &&
        (jobIdStr.startsWith('08e') || jobIdStr.startsWith('707')))
      ) {
        continue;
      }
      try {
        jobIds.add((Id) jobIdStr);
      } catch (Exception ignored) {
        // Malformed Async_Job_Id__c; skip the liveness check for this instance.
      }
    }
    return jobIds;
  }

  /**
   * @description Resolve which of the given job ids are still alive
   * (WAITING/ACQUIRED/QUEUED/EXECUTING crons or Queued/Holding/Preparing/
   * Processing async jobs).
   * @param jobIds the well-formed job ids to check
   * @return the subset of job ids that are still alive
   */
  public static Set<Id> resolveActiveJobIds(Set<Id> jobIds) {
    Set<Id> cronIds = new Set<Id>();
    Set<Id> asyncIds = new Set<Id>();
    for (Id jobId : jobIds) {
      if (jobId.getSobjectType() == CronTrigger.SObjectType) {
        cronIds.add(jobId);
      } else if (jobId.getSobjectType() == AsyncApexJob.SObjectType) {
        asyncIds.add(jobId);
      }
    }

    Set<Id> activeIds = new Set<Id>();
    if (!cronIds.isEmpty()) {
      for (CronTrigger ct : [
        SELECT Id
        FROM CronTrigger
        WHERE
          Id IN :cronIds
          AND State IN ('WAITING', 'ACQUIRED', 'QUEUED', 'EXECUTING')
        WITH SYSTEM_MODE
      ]) {
        activeIds.add(ct.Id);
      }
    }
    if (!asyncIds.isEmpty()) {
      for (AsyncApexJob aaj : [
        SELECT Id
        FROM AsyncApexJob
        WHERE
          Id IN :asyncIds
          AND Status IN ('Queued', 'Holding', 'Preparing', 'Processing')
        WITH SYSTEM_MODE
      ]) {
        activeIds.add(aaj.Id);
      }
    }
    return activeIds;
  }

  /**
   * @description An instance is orphaned when it has no async job id, a malformed
   * one, or a well-formed id that is not in the set of currently-alive jobs.
   * @param inst the instance to test
   * @param activeJobIds the set of currently-alive job ids
   * @return true when the instance's async job is no longer alive
   */
  public static Boolean isInstanceOrphaned(
    Workflow_Instance__c inst,
    Set<Id> activeJobIds
  ) {
    if (String.isBlank(inst.Async_Job_Id__c)) {
      return true;
    }
    String jobIdStr = inst.Async_Job_Id__c;
    if (
      !((jobIdStr.length() == 15 || jobIdStr.length() == 18) &&
      (jobIdStr.startsWith('08e') || jobIdStr.startsWith('707')))
    ) {
      return true;
    }
    try {
      Id jobId = (Id) jobIdStr;
      return !activeJobIds.contains(jobId);
    } catch (Exception ex) {
      return true;
    }
  }
}
