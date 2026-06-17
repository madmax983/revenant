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
   * Returns all schedules with their fields plus a computed dedicatedJobArmed flag.
   * cacheBuster lets the client bypass the Lightning cache on manual refresh.
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
          'dedicatedJobArmed' => armedJobNames.contains('RevenantSched_' + s.Name),
          'nextFireTime' => WorkflowCronEvaluator.nextFireTime(
            s.Cron_Expression__c,
            DateTime.now()
          )
        }
      );
    }
    return result;
  }

  /**
   * Returns one schedule plus its recent fire logs and next/last fire preview.
   */
  @AuraEnabled
  public static Map<String, Object> getScheduleDetail(Id scheduleId) {
    checkAuthorization();

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
      WHERE Schedule_Name__c = :sched.Name
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
   * WorkflowDefinition class names for the editor combobox. Reuses the dashboard's
   * discovery logic.
   */
  @AuraEnabled(cacheable=true)
  public static List<String> getWorkflowDefinitions() {
    checkAuthorization();
    return WorkflowDashboardController.getDefinitionsUnchecked();
  }

  /**
   * Live cron preview for the editor: validity plus last/next fire instants.
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
   * Creates (no Id) or updates (Id present) a schedule. Validates cron and the
   * optional input JSON before committing.
   */
  @AuraEnabled
  public static Id saveSchedule(Map<String, Object> fields) {
    checkAuthorization();

    String cron = (String) fields.get('Cron_Expression__c');
    if (!WorkflowCronEvaluator.isValidCron(cron)) {
      throwAura('Invalid cron expression: ' + cron);
    }

    String inputJson = (String) fields.get('Input_Json__c');
    if (String.isNotBlank(inputJson)) {
      try {
        JSON.deserializeUntyped(inputJson);
      } catch (Exception e) {
        throwAura('Input JSON is not valid JSON: ' + e.getMessage());
      }
    }

    Workflow_Schedule__c sched = new Workflow_Schedule__c();
    if (fields.get('Id') != null && String.isNotBlank((String) fields.get('Id'))) {
      sched.Id = (Id) fields.get('Id');
    }
    sched.Name = (String) fields.get('Name');
    sched.Workflow_Name__c = (String) fields.get('Workflow_Name__c');
    sched.Cron_Expression__c = cron;
    sched.Correlation_Key_Prefix__c = (String) fields.get('Correlation_Key_Prefix__c');
    sched.Input_Json__c = inputJson;
    sched.Enabled__c = toBool(fields.get('Enabled__c'));
    sched.Overlap_Policy__c = (String) fields.get('Overlap_Policy__c');
    sched.Dedicated_Slot__c = toBool(fields.get('Dedicated_Slot__c'));

    try {
      upsert as user sched;
    } catch (Exception e) {
      throwAura('Could not save schedule: ' + e.getMessage());
    }
    return sched.Id;
  }

  @AuraEnabled
  public static void deleteSchedule(Id scheduleId) {
    checkAuthorization();
    // Remove any armed dedicated job first so nothing is orphaned.
    try {
      WorkflowScheduleSweeper.unregisterDedicatedJob(scheduleId);
    } catch (Exception e) {
      System.debug(LoggingLevel.WARN, 'unregister before delete: ' + e.getMessage());
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

  @AuraEnabled
  public static void setEnabled(Id scheduleId, Boolean enabled) {
    checkAuthorization();
    Workflow_Schedule__c sched = [
      SELECT Id, Enabled__c
      FROM Workflow_Schedule__c
      WHERE Id = :scheduleId
      WITH USER_MODE
      LIMIT 1
    ];
    sched.Enabled__c = enabled;
    update as user sched;
  }

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

  @AuraEnabled
  public static void registerDedicatedJob(Id scheduleId) {
    checkAuthorization();
    try {
      WorkflowScheduleSweeper.registerDedicatedJob(scheduleId);
    } catch (Exception e) {
      throwAura('Could not arm dedicated job: ' + e.getMessage());
    }
  }

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
