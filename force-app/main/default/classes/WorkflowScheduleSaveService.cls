/**
 * Service for the create/update (save) path of WorkflowScheduleController. Holds the
 * mutation orchestration lifted out of the controller — validation, existing-Id
 * resolution, prior-cron capture, prefix-uniqueness enforcement, record building,
 * dedicated-job synchronization, and fire-cursor reseeding — so the controller stays
 * under the PMD complexity thresholds.
 *
 * The controller's @AuraEnabled saveSchedule delegates to save() after performing its
 * authorization check; enableSchedule delegates to reseedCursor(). Behavior, SOQL/DML
 * (and their modes), and AuraHandledException messages are preserved exactly.
 */
public inherited sharing class WorkflowScheduleSaveService {
  /**
   * @description Creates (no Id) or updates (Id present) a schedule. Validates cron
   * and the optional input JSON before committing, reseeds the fire cursor when the
   * cron changes, and keeps any armed dedicated job in sync.
   * @param fields The schedule field values from the editor.
   * @return The Id of the created or updated schedule.
   */
  public static Id save(Map<String, Object> fields) {
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
   * @description (Re)computes the engine-managed Next_Fire_Window__c cursor for a
   * schedule from its cron. Written in SYSTEM mode since the cursor field is
   * read-only to admins.
   * @param scheduleId The schedule whose cursor is reseeded.
   * @param cron The cron expression used to compute the next window.
   * @param logSource The caller label recorded in any error log.
   */
  public static void reseedCursor(
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
   * @description Coerces a loosely-typed field-map value into a Boolean, treating
   * null as false.
   * @param val The raw value from the incoming field map.
   * @return The coerced Boolean value.
   */
  private static Boolean toBool(Object val) {
    if (val == null) {
      return false;
    }
    if (val instanceof Boolean) {
      return (Boolean) val;
    }
    return Boolean.valueOf(String.valueOf(val));
  }

  /**
   * @description Throws an AuraHandledException whose user-facing message matches the
   * supplied text (setMessage keeps the message visible to the LWC client).
   * @param message The message to surface to the client.
   */
  private static void throwAura(String message) {
    AuraHandledException ex = new AuraHandledException(message);
    ex.setMessage(message);
    throw ex;
  }
}
