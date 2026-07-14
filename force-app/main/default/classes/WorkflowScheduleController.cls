/**
 * Apex controller for the workflowScheduleManager LWC. Provides full CRUD plus
 * quick actions (enable/disable, run-now, dedicated-slot register/abort) and a
 * cron preview, over Workflow_Schedule__c records.
 *
 * Authorization mirrors WorkflowDashboardController: access is granted to holders
 * of the Workflow_Schedule_Admin OR Workflow_Admin custom permission, or any user
 * with Modify All Data.
 */
public with sharing class WorkflowScheduleController {
  // ── Authorization ───────────────────────────────────────────────────────────

  private static void checkAuthorization() {
    if (
      FeatureManagement.checkPermission('Workflow_Schedule_Admin') ||
      FeatureManagement.checkPermission('Workflow_Admin')
    ) {
      return;
    }
    if (currentUserHasModifyAllData()) {
      return;
    }
    AuraHandledException ex = new AuraHandledException(
      'Unauthorized: Access to Workflow Schedules is restricted.'
    );
    ex.setMessage('Unauthorized: Access to Workflow Schedules is restricted.');
    throw ex;
  }

  private static Boolean currentUserHasModifyAllData() {
    return ![
        SELECT Id
        FROM PermissionSetAssignment
        WHERE
          AssigneeId = :UserInfo.getUserId()
          AND PermissionSet.PermissionsModifyAllData = TRUE
        WITH SYSTEM_MODE
        LIMIT 1
      ]
      .isEmpty();
  }

  // ── Reads ─────────────────────────────────────────────────────────────────

  /**
   * @description Returns all schedules with their fields plus a computed
   * dedicatedJobArmed flag. cacheBuster lets the client bypass the Lightning cache
   * on manual refresh.
   * @param cacheBuster An arbitrary value the client varies to bypass the LDS cache.
   * @return One map of display fields per schedule, ordered by name.
   */
  @AuraEnabled(cacheable=true)
  public static List<Map<String, Object>> getSchedules(String cacheBuster) {
    checkAuthorization();
    return WorkflowScheduleReadService.listSchedules();
  }

  /**
   * @description Returns one schedule plus its recent fire logs and next/last fire
   * preview.
   * @param scheduleId The schedule to load.
   * @return A map with the schedule, its recent logs, and next/last fire times.
   */
  @AuraEnabled
  public static Map<String, Object> getScheduleDetail(Id scheduleId) {
    checkAuthorization();
    return WorkflowScheduleReadService.loadScheduleDetail(scheduleId);
  }

  /**
   * @description WorkflowDefinition class names for the editor combobox. Reuses the
   * dashboard's discovery logic.
   * @return The discoverable WorkflowDefinition class names.
   */
  @AuraEnabled(cacheable=true)
  public static List<String> getWorkflowDefinitions() {
    checkAuthorization();
    return WorkflowScheduleReadService.listWorkflowDefinitions();
  }

  /**
   * @description Live cron preview for the editor: validity plus last/next fire
   * instants.
   * @param cron The cron expression to preview.
   * @return A map with the valid flag and, when valid, last/next fire times.
   */
  @AuraEnabled
  public static Map<String, Object> previewCron(String cron) {
    checkAuthorization();
    return WorkflowScheduleReadService.buildCronPreview(cron);
  }

  // ── Writes ──────────────────────────────────────────────────────────────────

  /**
   * @description Creates (no Id) or updates (Id present) a schedule. Validates cron
   * and the optional input JSON before committing, reseeds the fire cursor when the
   * cron changes, and keeps any armed dedicated job in sync.
   * @param fields The schedule field values from the editor.
   * @return The Id of the created or updated schedule.
   */
  @AuraEnabled
  public static Id saveSchedule(Map<String, Object> fields) {
    checkAuthorization();
    return WorkflowScheduleSaveService.save(fields);
  }

  /**
   * @description Deletes a schedule, first tearing down any armed dedicated job so
   * nothing is left orphaned.
   * @param scheduleId The schedule to delete.
   */
  @AuraEnabled
  public static void deleteSchedule(Id scheduleId) {
    checkAuthorization();
    if (scheduleId == null) {
      throw new AuraHandledException('scheduleId is required.');
    }
    // Remove any armed dedicated job first so nothing is orphaned.
    try {
      WorkflowScheduleSweeper.unregisterDedicatedJob(scheduleId);
    } catch (Exception ex) {
      WorkflowLog.error(
        'ScheduleDelete',
        'Failed to unregister dedicated job before delete: ' + ex.getMessage()
      );
    }
    Workflow_Schedule__c sched = [
      SELECT Id
      FROM Workflow_Schedule__c
      WHERE Id = :scheduleId
      WITH USER_MODE
      LIMIT 1
    ];
    delete as user sched;
  }

  /**
   * @description Enables a schedule and, when re-enabling a previously disabled one,
   * reseeds the fire cursor so the next sweep waits for the next future window.
   * @param scheduleId The schedule to enable.
   */
  @AuraEnabled
  public static void enableSchedule(Id scheduleId) {
    checkAuthorization();
    Workflow_Schedule__c sched = loadScheduleForToggle(scheduleId);
    Boolean wasEnabled = sched.Enabled__c;
    sched.Enabled__c = true;
    update as user sched;

    // Re-enabling after a pause: recompute the cursor so the next sweep waits for
    // the next FUTURE window instead of immediately firing a stale window that
    // elapsed while the schedule was disabled (e.g. a nightly schedule re-enabled
    // at 10:00 should not fire that day's 02:00 run). Written in system mode since
    // the cursor field is read-only to admins.
    if (!wasEnabled) {
      WorkflowScheduleSaveService.reseedCursor(
        scheduleId,
        sched.Cron_Expression__c,
        'ScheduleToggle'
      );
    }
  }

  /**
   * @description Disables a schedule and, if it was dedicated, also tears down its
   * CronTrigger so it stops firing immediately.
   * @param scheduleId The schedule to disable.
   */
  @AuraEnabled
  public static void disableSchedule(Id scheduleId) {
    checkAuthorization();
    Workflow_Schedule__c sched = loadScheduleForToggle(scheduleId);
    sched.Enabled__c = false;
    update as user sched;

    // Disabling a dedicated schedule must also tear down its CronTrigger so it
    // stops firing immediately (the job re-checks Enabled__c too, but this avoids
    // a lingering scheduled job entirely).
    if (sched.Dedicated_Slot__c) {
      try {
        WorkflowScheduleSweeper.unregisterDedicatedJob(scheduleId);
      } catch (Exception ex) {
        WorkflowLog.error(
          'ScheduleToggle',
          'Failed to abort dedicated job: ' + ex.getMessage()
        );
      }
    }
  }

  private static Workflow_Schedule__c loadScheduleForToggle(Id scheduleId) {
    if (scheduleId == null) {
      throw new AuraHandledException('scheduleId is required.');
    }
    return [
      SELECT Id, Enabled__c, Dedicated_Slot__c, Cron_Expression__c
      FROM Workflow_Schedule__c
      WHERE Id = :scheduleId
      WITH USER_MODE
      LIMIT 1
    ];
  }

  /**
   * @description Fires a schedule immediately, out of band from its cron cadence.
   * @param scheduleId The schedule to run now.
   * @return The Id of the started workflow instance, or null on failure.
   */
  @AuraEnabled
  public static Id runNow(Id scheduleId) {
    checkAuthorization();
    try {
      return WorkflowScheduleSweeper.runNow(scheduleId);
    } catch (Exception e) {
      throwAura('Run now failed: ' + e.getMessage());
      return null;
    }
  }

  /**
   * @description Arms a dedicated CronTrigger job for a schedule (its own scheduled
   * slot rather than the shared sweeper).
   * @param scheduleId The schedule to arm a dedicated job for.
   */
  @AuraEnabled
  public static void registerDedicatedJob(Id scheduleId) {
    checkAuthorization();
    try {
      WorkflowScheduleSweeper.registerDedicatedJob(scheduleId);
    } catch (Exception e) {
      throwAura('Could not arm dedicated job: ' + e.getMessage());
    }
  }

  /**
   * @description Aborts and removes a schedule's dedicated CronTrigger job.
   * @param scheduleId The schedule whose dedicated job is removed.
   */
  @AuraEnabled
  public static void unregisterDedicatedJob(Id scheduleId) {
    checkAuthorization();
    try {
      WorkflowScheduleSweeper.unregisterDedicatedJob(scheduleId);
    } catch (Exception e) {
      throwAura('Could not abort dedicated job: ' + e.getMessage());
    }
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  private static void throwAura(String message) {
    AuraHandledException ex = new AuraHandledException(message);
    ex.setMessage(message);
    throw ex;
  }
}
