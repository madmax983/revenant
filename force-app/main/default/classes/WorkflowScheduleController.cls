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

    List<Workflow_Schedule__c> schedules = [
      SELECT
        Id,
        Name,
        Workflow_Name__c,
        Cron_Expression__c,
        Correlation_Key_Prefix__c,
        Input_Json__c,
        Enabled__c,
        Overlap_Policy__c,
        Dedicated_Slot__c,
        Last_Fired_Window__c,
        Last_Outcome__c,
        Next_Fire_Window__c,
        LastModifiedDate
      FROM Workflow_Schedule__c
      WITH USER_MODE
      ORDER BY Name ASC
      LIMIT 2000
    ];

    // Resolve which dedicated jobs are currently armed (single CronTrigger query).
    Set<String> armedJobNames = new Set<String>();
    for (CronTrigger ct : [
      SELECT CronJobDetail.Name
      FROM CronTrigger
      WHERE CronJobDetail.Name LIKE 'RevenantSched_%'
      WITH SYSTEM_MODE
    ]) {
      armedJobNames.add(ct.CronJobDetail.Name);
    }

    List<Map<String, Object>> result = new List<Map<String, Object>>();
    for (Workflow_Schedule__c s : schedules) {
      result.add(
        new Map<String, Object>{
          'Id' => s.Id,
          'Name' => s.Name,
          'Workflow_Name__c' => s.Workflow_Name__c,
          'Cron_Expression__c' => s.Cron_Expression__c,
          'Correlation_Key_Prefix__c' => s.Correlation_Key_Prefix__c,
          'Input_Json__c' => s.Input_Json__c,
          'Enabled__c' => s.Enabled__c,
          'Overlap_Policy__c' => s.Overlap_Policy__c,
          'Dedicated_Slot__c' => s.Dedicated_Slot__c,
          'Last_Fired_Window__c' => s.Last_Fired_Window__c,
          'Last_Outcome__c' => s.Last_Outcome__c,
          'LastModifiedDate' => s.LastModifiedDate,
          'dedicatedJobArmed' => armedJobNames.contains(
            WorkflowScheduleSweeper.dedicatedJobName(s.Id)
          ),
          // Read the persisted, engine-managed cursor rather than recomputing the
          // cron per row. Walking the evaluator for up to 2000 rows (each up to a
          // ~4-year lookahead for low-frequency or impossible crons) could burn the
          // Apex CPU limit and fail the whole list load. The cursor is populated at
          // save time and advanced by each sweep; the detail view still computes the
          // exact next/last fire lazily for a single schedule.
          'nextFireTime' => s.Next_Fire_Window__c
        }
      );
    }
    return result;
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
    if (scheduleId == null) {
      throw new AuraHandledException('scheduleId is required.');
    }

    Workflow_Schedule__c sched = [
      SELECT
        Id,
        Name,
        Workflow_Name__c,
        Cron_Expression__c,
        Correlation_Key_Prefix__c,
        Input_Json__c,
        Enabled__c,
        Overlap_Policy__c,
        Dedicated_Slot__c,
        Last_Fired_Window__c,
        Last_Outcome__c
      FROM Workflow_Schedule__c
      WHERE Id = :scheduleId
      WITH USER_MODE
      LIMIT 1
    ];

    List<Map<String, Object>> logs = new List<Map<String, Object>>();
    for (Workflow_Log__c log : [
      SELECT
        Id,
        Outcome__c,
        Correlation_Key__c,
        Fire_Time__c,
        Workflow_Instance__c,
        Message__c,
        CreatedDate
      FROM Workflow_Log__c
      WHERE Schedule__c = :scheduleId
      WITH USER_MODE
      ORDER BY CreatedDate DESC
      LIMIT 50
    ]) {
      logs.add(
        new Map<String, Object>{
          'Id' => log.Id,
          'Outcome__c' => log.Outcome__c,
          'Correlation_Key__c' => log.Correlation_Key__c,
          'Fire_Time__c' => log.Fire_Time__c,
          'Workflow_Instance__c' => log.Workflow_Instance__c,
          'Message__c' => log.Message__c,
          'CreatedDate' => log.CreatedDate
        }
      );
    }

    return new Map<String, Object>{
      'schedule' => sched,
      'logs' => logs,
      'nextFireTime' => WorkflowCronEvaluator.nextFireTime(
        sched.Cron_Expression__c,
        DateTime.now()
      ),
      'lastFireTime' => WorkflowCronEvaluator.previousFireTime(
        sched.Cron_Expression__c,
        DateTime.now()
      )
    };
  }

  /**
   * @description WorkflowDefinition class names for the editor combobox. Reuses the
   * dashboard's discovery logic.
   * @return The discoverable WorkflowDefinition class names.
   */
  @AuraEnabled(cacheable=true)
  public static List<String> getWorkflowDefinitions() {
    checkAuthorization();
    return WorkflowDashboardController.getDefinitionsUnchecked();
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
    Boolean valid = WorkflowCronEvaluator.isValidCron(cron);
    return new Map<String, Object>{
      'valid' => valid,
      'lastFire' => valid
        ? WorkflowCronEvaluator.previousFireTime(cron, DateTime.now())
        : null,
      'nextFire' => valid
        ? WorkflowCronEvaluator.nextFireTime(cron, DateTime.now())
        : null
    };
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

    String cron = (String) fields.get('Cron_Expression__c');
    String prefix = (String) fields.get('Correlation_Key_Prefix__c');
    validateScheduleInput(cron, (String) fields.get('Input_Json__c'), prefix);

    Id existingId = resolveExistingId(fields);
    // Capture the prior cron so we can re-arm an already-armed dedicated job if the
    // cadence changes (System.schedule can't be updated in place).
    String oldCron = loadOldCron(existingId);
    assertUniquePrefix(prefix, existingId);

    Workflow_Schedule__c sched = buildScheduleRecord(fields, existingId);
    try {
      upsert as user sched;
    } catch (Exception e) {
      throwAura('Could not save schedule: ' + e.getMessage());
    }

    // Recompute the engine-managed cursor on create or whenever the cron changes.
    // sweep() only selects rows whose Next_Fire_Window__c is null or <= now, so a
    // stale cursor from the prior cron (e.g. next month for a monthly schedule)
    // would keep an edited every-minute schedule filtered out until that old date.
    // Pointing the cursor at the new cron's next window both fixes that and gives
    // the list view an immediate "next run" without a per-row evaluator scan.
    if (existingId == null || oldCron != cron) {
      reseedCursor(sched.Id, cron, 'ScheduleSave');
    }

    // Keep any armed dedicated CronTrigger consistent with the saved record.
    if (
      existingId != null &&
      WorkflowScheduleSweeper.isDedicatedJobArmed(sched.Id)
    ) {
      syncDedicatedJob(sched, oldCron, cron);
    }
    return sched.Id;
  }

  /**
   * @description Validates the cron, optional input JSON, and correlation-key prefix;
   * throws an AuraHandledException on any invalid value.
   * @param cron The cron expression to validate.
   * @param inputJson The optional input JSON to validate, or blank.
   * @param prefix The correlation-key prefix to validate.
   */
  private static void validateScheduleInput(
    String cron,
    String inputJson,
    String prefix
  ) {
    if (!WorkflowCronEvaluator.isValidCron(cron)) {
      throwAura('Invalid cron expression: ' + cron);
    }
    if (String.isNotBlank(inputJson)) {
      try {
        JSON.deserializeUntyped(inputJson);
      } catch (Exception e) {
        throwAura('Input JSON is not valid JSON: ' + e.getMessage());
      }
    }
    if (String.isBlank(prefix)) {
      throwAura('Correlation Key Prefix is required.');
    }
    // 80-char cap keeps the generated key (prefix + "_manual_" + 14-digit stamp)
    // within WorkflowEngine's 200-character correlation-key limit.
    if (prefix.length() > 80) {
      throwAura('Correlation Key Prefix must be 80 characters or fewer.');
    }
  }

  /**
   * @description Extracts the update-target Id from the incoming field map.
   * @param fields The incoming schedule field map.
   * @return The existing schedule Id, or null on create.
   */
  private static Id resolveExistingId(Map<String, Object> fields) {
    if (
      fields.get('Id') != null && String.isNotBlank((String) fields.get('Id'))
    ) {
      return (Id) fields.get('Id');
    }
    return null;
  }

  /**
   * @description Reads the currently-persisted cron for an edit.
   * @param existingId The schedule being edited, or null on create.
   * @return The stored cron expression, or null on create or a missing row.
   */
  private static String loadOldCron(Id existingId) {
    if (existingId == null) {
      return null;
    }
    List<Workflow_Schedule__c> existing = [
      SELECT Cron_Expression__c
      FROM Workflow_Schedule__c
      WHERE Id = :existingId
      WITH SYSTEM_MODE
      LIMIT 1
    ];
    return existing.isEmpty() ? null : existing[0].Cron_Expression__c;
  }

  /**
   * @description Enforces correlation-key-prefix uniqueness with a friendly message
   * (the field is also unique at the database level as a backstop); throws on a
   * collision.
   * @param prefix The correlation-key prefix to check.
   * @param existingId The schedule being edited (excluded from the check), or null.
   */
  private static void assertUniquePrefix(String prefix, Id existingId) {
    List<Workflow_Schedule__c> dupes;
    if (existingId == null) {
      dupes = [
        SELECT Id
        FROM Workflow_Schedule__c
        WHERE Correlation_Key_Prefix__c = :prefix
        WITH SYSTEM_MODE
        LIMIT 1
      ];
    } else {
      dupes = [
        SELECT Id
        FROM Workflow_Schedule__c
        WHERE Correlation_Key_Prefix__c = :prefix AND Id != :existingId
        WITH SYSTEM_MODE
        LIMIT 1
      ];
    }
    if (!dupes.isEmpty()) {
      throwAura(
        'Another schedule already uses the correlation key prefix "' +
          prefix +
          '". Prefixes must be unique.'
      );
    }
  }

  /**
   * @description Maps the incoming field map onto a Workflow_Schedule__c for upsert.
   * @param fields The incoming schedule field map.
   * @param existingId The Id to set for an update, or null for an insert.
   * @return The populated schedule record ready to upsert.
   */
  private static Workflow_Schedule__c buildScheduleRecord(
    Map<String, Object> fields,
    Id existingId
  ) {
    Workflow_Schedule__c sched = new Workflow_Schedule__c();
    if (existingId != null) {
      sched.Id = existingId;
    }
    sched.Name = (String) fields.get('Name');
    sched.Workflow_Name__c = (String) fields.get('Workflow_Name__c');
    sched.Cron_Expression__c = (String) fields.get('Cron_Expression__c');
    sched.Correlation_Key_Prefix__c = (String) fields.get(
      'Correlation_Key_Prefix__c'
    );
    sched.Input_Json__c = (String) fields.get('Input_Json__c');
    sched.Enabled__c = toBool(fields.get('Enabled__c'));
    sched.Overlap_Policy__c = (String) fields.get('Overlap_Policy__c');
    sched.Dedicated_Slot__c = toBool(fields.get('Dedicated_Slot__c'));
    return sched;
  }

  /**
   * @description Keeps an armed dedicated CronTrigger consistent with the just-saved
   * record: tears it down if the edit turned off Enabled or Dedicated mode, or
   * re-arms it (abort + register) if still dedicated/enabled but the cadence changed.
   * @param sched The just-saved schedule record.
   * @param oldCron The cron before the save.
   * @param cron The cron after the save.
   */
  private static void syncDedicatedJob(
    Workflow_Schedule__c sched,
    String oldCron,
    String cron
  ) {
    if (!sched.Enabled__c || !sched.Dedicated_Slot__c) {
      // Edit turned off Enabled or Dedicated mode → tear down the orphaned job
      // (otherwise it keeps a scheduled-job slot and the abort action vanishes
      // from the row once Dedicated_Slot__c is false).
      try {
        WorkflowScheduleSweeper.unregisterDedicatedJob(sched.Id);
      } catch (Exception ex) {
        WorkflowLog.error(
          'ScheduleSave',
          'Failed to abort dedicated job: ' + ex.getMessage()
        );
      }
    } else if (oldCron != cron) {
      // Still dedicated + enabled but the cadence changed → re-arm, since the
      // live CronTrigger would otherwise keep firing on the old cron behind a
      // UI that still shows the schedule as armed.
      try {
        WorkflowScheduleSweeper.unregisterDedicatedJob(sched.Id);
        WorkflowScheduleSweeper.registerDedicatedJob(sched.Id);
      } catch (Exception e) {
        throwAura(
          'Schedule saved, but its dedicated job could not be re-armed with the ' +
            'new cron (' +
            e.getMessage() +
            '). Abort and re-arm it manually.'
        );
      }
    }
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
      reseedCursor(scheduleId, sched.Cron_Expression__c, 'ScheduleToggle');
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
   * @description (Re)computes the engine-managed Next_Fire_Window__c cursor for a
   * schedule from its cron. Written in SYSTEM mode since the cursor field is
   * read-only to admins.
   * @param scheduleId The schedule whose cursor is reseeded.
   * @param cron The cron expression used to compute the next window.
   * @param logSource The caller label recorded in any error log.
   */
  private static void reseedCursor(
    Id scheduleId,
    String cron,
    String logSource
  ) {
    try {
      update as system new Workflow_Schedule__c(
        Id = scheduleId,
        Next_Fire_Window__c = WorkflowCronEvaluator.nextFireTime(
          cron,
          DateTime.now()
        )
      );
    } catch (Exception ex) {
      WorkflowLog.error(
        logSource,
        'Failed to recompute cursor: ' + ex.getMessage()
      );
    }
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

  private static Boolean toBool(Object val) {
    if (val == null) {
      return false;
    }
    if (val instanceof Boolean) {
      return (Boolean) val;
    }
    return Boolean.valueOf(String.valueOf(val));
  }

  private static void throwAura(String message) {
    AuraHandledException ex = new AuraHandledException(message);
    ex.setMessage(message);
    throw ex;
  }
}
