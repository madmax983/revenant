/**
 * Service for the read/detail path of WorkflowScheduleController. Holds the query and
 * projection logic behind the controller's cacheable list, single-schedule detail,
 * workflow-definition discovery, and cron-preview endpoints, lifted out of the
 * controller to keep it under the PMD complexity thresholds.
 *
 * The controller's @AuraEnabled reads delegate here after performing their
 * authorization check. SOQL (and its modes/ordering) and AuraHandledException
 * messages are preserved exactly. Method names intentionally differ from the
 * controller's @AuraEnabled method names: PMD's Apex cognitive-complexity metric
 * counts a call to a method whose simple name matches the caller's method as
 * recursion, which inflates the controller's class-level score, so these entry
 * points use distinct verbs.
 */
public inherited sharing class WorkflowScheduleReadService {
  /**
   * @description Returns all schedules with their fields plus a computed
   * dedicatedJobArmed flag.
   * @return One map of display fields per schedule, ordered by name.
   */
  public static List<Map<String, Object>> listSchedules() {
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
        Time_Zone__c,
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
          'Time_Zone__c' => s.Time_Zone__c,
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
  public static Map<String, Object> loadScheduleDetail(Id scheduleId) {
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
        Time_Zone__c,
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
        DateTime.now(),
        sched.Time_Zone__c
      ),
      'lastFireTime' => WorkflowCronEvaluator.previousFireTime(
        sched.Cron_Expression__c,
        DateTime.now(),
        sched.Time_Zone__c
      )
    };
  }

  /**
   * @description WorkflowDefinition class names for the editor combobox. Reuses the
   * dashboard's discovery logic.
   * @return The discoverable WorkflowDefinition class names.
   */
  public static List<String> listWorkflowDefinitions() {
    return WorkflowDashboardController.getDefinitionsUnchecked();
  }

  /**
   * @description Supported IANA time-zone ids for the editor's time-zone picker.
   * A blank selection stored on the schedule means UTC (the pre-existing behavior).
   * @return The sorted list of supported IANA time-zone ids.
   */
  public static List<String> listTimeZones() {
    return WorkflowCronEvaluator.supportedZones();
  }

  /**
   * @description Live cron preview for the editor: validity plus last/next fire
   * instants, evaluated in the given IANA time zone (blank = UTC). The preview is
   * marked invalid when the cron is unparseable or the zone is unsupported.
   * @param cron The cron expression to preview.
   * @param zoneId The IANA time zone the cron is interpreted in (blank = UTC).
   * @return A map with the valid flag and, when valid, last/next fire times.
   */
  public static Map<String, Object> buildCronPreview(
    String cron,
    String zoneId
  ) {
    Boolean valid =
      WorkflowCronEvaluator.isValidCron(cron) &&
      WorkflowCronEvaluator.isValidZone(zoneId);
    return new Map<String, Object>{
      'valid' => valid,
      'lastFire' => valid
        ? WorkflowCronEvaluator.previousFireTime(cron, DateTime.now(), zoneId)
        : null,
      'nextFire' => valid
        ? WorkflowCronEvaluator.nextFireTime(cron, DateTime.now(), zoneId)
        : null
    };
  }
}
