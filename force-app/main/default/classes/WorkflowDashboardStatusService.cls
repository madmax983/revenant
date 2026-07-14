/**
 * @description Backs the dashboard's operational status panels: the watchdog/scheduler
 * health snapshot, the paused-definition list with parked-instance counts, and the
 * per-workflow concurrency picture. Extracted from WorkflowDashboardController; all SOQL
 * runs WITH SYSTEM_MODE.
 */
public inherited sharing class WorkflowDashboardStatusService {
  /**
   * @description Returns the watchdog/scheduler health snapshot for the dashboard: recent
   * watchdog jobs, scheduled-job and sleeping-instance counts, pending timeouts, engine
   * config, paused definitions, and async-apex limit usage.
   * @return A map of the watchdog status fields consumed by the status panel.
   */
  public static Map<String, Object> watchdogStatus() {
    WorkflowDashboardSupport.checkAuthorization();
    try {
      List<Workflow_Instance__c> watchdogInstances = [
        SELECT
          Id,
          Name,
          Status__c,
          Current_Step__c,
          Error_Message__c,
          CreatedDate,
          LastModifiedDate
        FROM Workflow_Instance__c
        WHERE
          Correlation_Key__c = 'SystemWatchdog'
          OR Correlation_Key__c LIKE 'SystemWatchdog_run%'
        WITH SYSTEM_MODE
        ORDER BY CreatedDate DESC
        LIMIT 5
      ];
      Workflow_Instance__c latestWatchdog = watchdogInstances.isEmpty()
        ? null
        : watchdogInstances[0];

      // Total scheduled jobs. The bound is well above the platform ceiling on CronTrigger
      // rows (scheduled Apex is capped at 100), so it never truncates the real count; it
      // only satisfies the "queries must be bounded" rule.
      Integer scheduledJobsCount = [
        SELECT COUNT()
        FROM CronTrigger
        WITH SYSTEM_MODE
        LIMIT 50000
      ];

      Integer sleepingInstances = [
        SELECT COUNT()
        FROM Workflow_Instance__c
        WHERE Sleep_Until__c != NULL AND Status__c = 'Suspended'
        WITH SYSTEM_MODE
      ];

      Integer pendingTimeouts = [
        SELECT COUNT()
        FROM Workflow_Step_Execution__c
        WHERE Timeout_At__c != NULL AND Status__c = 'Pending'
        WITH SYSTEM_MODE
      ];

      Map<String, Object> config = new Map<String, Object>{
        'Use_Dynamic_Scheduling__c' => WorkflowEngine.useDynamicScheduling,
        'Watchdog_Delay_Minutes__c' => WorkflowEngine.watchdogDelayMinutes
      };

      List<Map<String, Object>> pausedDefs = new List<Map<String, Object>>();
      try {
        pausedDefs = pausedDefinitions();
      } catch (Exception ignored) {
      }

      Map<String, Object> result = new Map<String, Object>{
        'isRunning' => isWatchdogRunning(watchdogInstances),
        'latestJob' => latestWatchdog,
        'recentJobs' => watchdogInstances,
        'scheduledJobsCount' => scheduledJobsCount,
        'sleepingInstances' => sleepingInstances,
        'pendingTimeouts' => pendingTimeouts,
        'config' => config,
        'pausedDefinitions' => pausedDefs
      };
      result.putAll(readAsyncLimits());
      return result;
    } catch (Exception ex) {
      throw new AuraHandledException(ex.getMessage());
    }
  }

  private static Boolean isWatchdogRunning(
    List<Workflow_Instance__c> watchdogInstances
  ) {
    if (watchdogInstances.isEmpty()) {
      return false;
    }
    String status = watchdogInstances[0].Status__c;
    return status == 'Pending' || status == 'Running' || status == 'Suspended';
  }

  // Reads the async-apex org limits into the dashboard's status keys. Missing limits
  // (e.g. no elastic-executions limit on this org) leave their defaults in place.
  private static Map<String, Object> readAsyncLimits() {
    Map<String, System.OrgLimit> limitsMap = System.OrgLimits.getMap();
    Map<String, Object> result = new Map<String, Object>{
      'dailyAsyncValue' => 0,
      'dailyAsyncLimit' => 0,
      'hasElasticLimit' => false,
      'elasticAsyncValue' => 0,
      'elasticAsyncLimit' => 0
    };
    if (limitsMap.containsKey('DailyAsyncApexExecutions')) {
      System.OrgLimit limitObj = limitsMap.get('DailyAsyncApexExecutions');
      result.put('dailyAsyncValue', limitObj.getValue());
      result.put('dailyAsyncLimit', limitObj.getLimit());
    }
    if (limitsMap.containsKey('DailyAsyncApexElasticExecutions')) {
      System.OrgLimit limitObj = limitsMap.get(
        'DailyAsyncApexElasticExecutions'
      );
      result.put('hasElasticLimit', true);
      result.put('elasticAsyncValue', limitObj.getValue());
      result.put('elasticAsyncLimit', limitObj.getLimit());
    }
    return result;
  }

  /**
   * @description Returns a list of currently paused definitions with parked-instance
   * counts. Each entry: { workflowName, reason, pausedAt (CreatedDate), parkedCount }.
   * @return One map per paused definition, or an empty list when none are paused.
   */
  public static List<Map<String, Object>> pausedDefinitions() {
    WorkflowDashboardSupport.checkAuthorization();
    try {
      // Bound the scan well above any realistic paused-definition count (one row per
      // paused definition) so the result is never truncated; satisfies the bounded-query
      // rule without altering the set the dashboard shows.
      List<Workflow_Pause_State__c> pauseRecords = [
        SELECT Workflow_Name__c, Reason__c, CreatedById, CreatedDate
        FROM Workflow_Pause_State__c
        WITH SYSTEM_MODE
        ORDER BY CreatedDate ASC
        LIMIT 50000
      ];

      if (pauseRecords.isEmpty()) {
        return new List<Map<String, Object>>();
      }

      ParkedCounts parked = countParkedByDefinition(pauseRecords);

      List<Map<String, Object>> result = new List<Map<String, Object>>();
      for (Workflow_Pause_State__c r : pauseRecords) {
        result.add(
          new Map<String, Object>{
            'workflowName' => r.Workflow_Name__c,
            'reason' => r.Reason__c,
            'pausedAt' => r.CreatedDate,
            'parkedCount' => parked.forRecord(r)
          }
        );
      }
      return result;
    } catch (Exception ex) {
      throw new AuraHandledException(ex.getMessage());
    }
  }

  // Parked (Paused-status) instance counts per definition, plus the org-wide total used
  // when a wildcard ('*') pause is present.
  private class ParkedCounts {
    Map<String, Integer> countByDef = new Map<String, Integer>();
    Integer totalParked = 0;

    Integer forRecord(Workflow_Pause_State__c r) {
      if (r.Workflow_Name__c == '*') {
        return totalParked;
      }
      // Workflow_Name__c is a case-insensitive external id but an Apex Map key is
      // case-sensitive, so look up by the same lower-cased key used when building the map.
      String key = r.Workflow_Name__c == null
        ? null
        : r.Workflow_Name__c.toLowerCase();
      return countByDef.containsKey(key) ? countByDef.get(key) : 0;
    }
  }

  private static ParkedCounts countParkedByDefinition(
    List<Workflow_Pause_State__c> pauseRecords
  ) {
    Set<String> pausedNames = new Set<String>();
    Boolean wildcardPaused = false;
    for (Workflow_Pause_State__c r : pauseRecords) {
      pausedNames.add(r.Workflow_Name__c);
      if (r.Workflow_Name__c == '*') {
        wildcardPaused = true;
      }
    }

    List<AggregateResult> counts = wildcardPaused
      ? queryParkedCountsAll()
      : queryParkedCountsFor(pausedNames);

    ParkedCounts parked = new ParkedCounts();
    for (AggregateResult ar : counts) {
      String name = (String) ar.get('Workflow_Name__c');
      // Grouped COUNT(Id) is returned as Integer in this org; a Decimal cast throws
      // TypeException as soon as a definition has parked rows.
      Integer cnt = (Integer) ar.get('cnt');
      // Normalize the key to lower case (mirrored in ParkedCounts.forRecord) so a pause
      // record created with different casing than its instances still resolves its count.
      parked.countByDef.put(name == null ? null : name.toLowerCase(), cnt);
      parked.totalParked += cnt;
    }
    return parked;
  }

  private static List<AggregateResult> queryParkedCountsAll() {
    return [
      SELECT Workflow_Name__c, COUNT(Id) cnt
      FROM Workflow_Instance__c
      WHERE Status__c = 'Paused'
      WITH SYSTEM_MODE
      GROUP BY Workflow_Name__c
    ];
  }

  private static List<AggregateResult> queryParkedCountsFor(
    Set<String> pausedNames
  ) {
    return [
      SELECT Workflow_Name__c, COUNT(Id) cnt
      FROM Workflow_Instance__c
      WHERE Status__c = 'Paused' AND Workflow_Name__c IN :pausedNames
      WITH SYSTEM_MODE
      GROUP BY Workflow_Name__c
    ];
  }

  /**
   * @description Returns the concurrency-limit picture for each governed workflow: current
   * in-flight count vs. its configured ceiling, and the number of parked/throttled
   * instances awaiting admission. One row per durable counter (Concurrency_State__c).
   * Each entry: { workflowName, ceiling, inFlight, parked }.
   * @return One concurrency-status map per governed workflow, or an empty list.
   */
  public static List<Map<String, Object>> concurrencyStatus() {
    WorkflowDashboardSupport.checkAuthorization();
    try {
      // Bounded well above any realistic governed-workflow count (one row per durable
      // Concurrency_State__c counter) so the result set is never truncated.
      List<Concurrency_State__c> states = [
        SELECT Workflow_Definition__c, In_Flight_Count__c
        FROM Concurrency_State__c
        WITH SYSTEM_MODE
        ORDER BY Workflow_Definition__c ASC
        LIMIT 50000
      ];
      if (states.isEmpty()) {
        return new List<Map<String, Object>>();
      }

      Set<String> workflowNames = new Set<String>();
      for (Concurrency_State__c s : states) {
        workflowNames.add(s.Workflow_Definition__c);
      }

      // Parked = Suspended specifically awaiting a concurrency slot (distinct from
      // ordinary sleep/signal waits), grouped per definition.
      Map<String, Integer> parkedByDef = new Map<String, Integer>();
      for (AggregateResult ar : [
        SELECT Workflow_Name__c wf, COUNT(Id) cnt
        FROM Workflow_Instance__c
        WHERE
          Workflow_Name__c IN :workflowNames
          AND Status__c = 'Suspended'
          AND Concurrency_Parked__c = TRUE
        WITH SYSTEM_MODE
        GROUP BY Workflow_Name__c
      ]) {
        parkedByDef.put((String) ar.get('wf'), (Integer) ar.get('cnt'));
      }

      List<Map<String, Object>> result = new List<Map<String, Object>>();
      for (Concurrency_State__c s : states) {
        result.add(
          new Map<String, Object>{
            'workflowName' => s.Workflow_Definition__c,
            'ceiling' => ConcurrencyGate.getCeiling(s.Workflow_Definition__c),
            'inFlight' => s.In_Flight_Count__c == null
              ? 0
              : (Integer) s.In_Flight_Count__c,
            'parked' => parkedByDef.containsKey(s.Workflow_Definition__c)
              ? parkedByDef.get(s.Workflow_Definition__c)
              : 0
          }
        );
      }
      return result;
    } catch (Exception ex) {
      throw new AuraHandledException(ex.getMessage());
    }
  }
}
