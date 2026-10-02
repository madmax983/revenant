/**
 * @description Backs the dashboard's operational status panels: the watchdog/scheduler
 * health snapshot, the paused-definition list with parked-instance counts, and the
 * per-workflow concurrency picture. Extracted from WorkflowDashboardController; all SOQL
 * runs WITH SYSTEM_MODE.
 */
public inherited sharing class WorkflowDashboardStatusService {
  // Waiting rows shown per governed workflow on the concurrency panel.
  private static final Integer QUEUE_ROWS_PER_WORKFLOW = 5;
  // SOQL kept free after the queue reads, for the rest of the request.
  private static final Integer QUEUE_QUERY_HEADROOM = 10;
  // Test seam: the most queue reads in one request. Null uses the SOQL limit.
  @TestVisible
  private static Integer maxQueueReadsOverride;
  // Upper bound on groups in the per-priority aggregate. Salesforce allows at
  // most 2,000 groups in an aggregate query that cannot page.
  private static final Integer MAX_PRIORITY_GROUPS = 2000;

  /**
   * @description Returns the watchdog/scheduler health snapshot for the dashboard: recent
   * watchdog jobs, scheduled-job and sleeping-instance counts, pending timeouts, engine
   * config, paused definitions, async-apex limit usage, Platform Event headroom,
   * watchdog liveness, and schedule health.
   * @return A map of the watchdog status fields consumed by the status panel.
   */
  public static Map<String, Object> watchdogStatus() {
    WorkflowDashboardSupport.checkAuthorization();
    try {
      List<Workflow_Instance__c> watchdogInstances = recentWatchdogs();
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
        'pausedDefinitions' => pausedDefs,
        'liveness' => livenessMap(),
        'scheduleHealth' => scheduleHealthMap()
      };
      Map<String, System.OrgLimit> limitsMap = System.OrgLimits.getMap();
      result.putAll(readAsyncLimits(limitsMap));
      result.putAll(readPlatformEventHeadroom(limitsMap));
      return result;
    } catch (Exception ex) {
      throw new AuraHandledException(ex.getMessage());
    }
  }

  /**
   * @description The watchdog health signal of System Doctor. The Readiness panel (#114)
   * uses it too. The caller checks authorization.
   * @return True when the latest watchdog instance is Pending, Running or Suspended.
   */
  public static Boolean watchdogRunning() {
    return isWatchdogRunning(recentWatchdogs());
  }

  // The five newest watchdog instances, newest first.
  private static List<Workflow_Instance__c> recentWatchdogs() {
    return [
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
  }

  // Watchdog liveness (issue #113). Each read calculates the state, so a dead
  // watchdog shows STALE. The read also runs the stall detector, so an org
  // with no traffic gets the alert when an operator opens System Doctor.
  // An error returns UNKNOWN.
  private static Map<String, Object> livenessMap() {
    try {
      WorkflowAlertManager.detectAndAlertWatchdogStall();
      return WatchdogLiveness.evaluateNow().toMap();
    } catch (Exception ignored) {
      return new Map<String, Object>{
        'state' => WatchdogLiveness.STATE_UNKNOWN
      };
    }
  }

  // Schedule health (issue #126). Each read calculates it. The read sends no
  // alert. An error returns error = true.
  private static Map<String, Object> scheduleHealthMap() {
    try {
      return ScheduleHealth.summary();
    } catch (Exception ignored) {
      return new Map<String, Object>{ 'error' => true };
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
  private static Map<String, Object> readAsyncLimits(
    Map<String, System.OrgLimit> limitsMap
  ) {
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

  // Platform Event allocation (issue #120). Reads only the map. If the read
  // fails, it returns the UNAVAILABLE payload. System Doctor continues to load.
  private static Map<String, Object> readPlatformEventHeadroom(
    Map<String, System.OrgLimit> limitsMap
  ) {
    try {
      return PlatformEventHeadroom.fromOrgLimits(limitsMap);
    } catch (Exception ignored) {
      return PlatformEventHeadroom.unavailable();
    }
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
   * Each entry: { workflowName, ceiling, inFlight, parked, waitingTotal,
   * waitingByPriority, waiting, waitingTruncated }. `waiting` lists the next
   * instances in admission order with their priority (issue #132).
   * `waitingTruncated` is true when the request had no SOQL left to read the
   * queue of that workflow (issue #277).
   * @return One concurrency-status map per governed workflow, or an empty list.
   */
  public static List<Map<String, Object>> concurrencyStatus() {
    WorkflowDashboardSupport.checkAuthorization();
    try {
      // Bounded well above any realistic governed-workflow count (one row per durable
      // Concurrency_State__c counter) so the result set is never truncated.
      // The global brake row (issue #136) has its own panel.
      List<Concurrency_State__c> states = [
        SELECT Workflow_Definition__c, In_Flight_Count__c
        FROM Concurrency_State__c
        WHERE Workflow_Definition__c != :GlobalAdmissionGate.COUNTER_KEY
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

      Map<String, Map<String, Object>> classesByDef = waitingByPriority(
        workflowNames
      );
      Map<String, List<Map<String, Object>>> queueByDef = waitingQueue(
        classesByDef.keySet(),
        workflowNames
      );

      List<Map<String, Object>> result = new List<Map<String, Object>>();
      for (Concurrency_State__c s : states) {
        String defKey = s.Workflow_Definition__c.toLowerCase();
        Map<String, Object> classes = classesByDef.containsKey(defKey)
          ? classesByDef.get(defKey)
          : new Map<String, Object>();
        result.add(
          new Map<String, Object>{
            'workflowName' => s.Workflow_Definition__c,
            'ceiling' => ConcurrencyGate.getCeiling(s.Workflow_Definition__c),
            'inFlight' => s.In_Flight_Count__c == null
              ? 0
              : (Integer) s.In_Flight_Count__c,
            'parked' => parkedByDef.containsKey(s.Workflow_Definition__c)
              ? parkedByDef.get(s.Workflow_Definition__c)
              : 0,
            'waitingTotal' => sumCounts(classes),
            'waitingByPriority' => classes,
            'waiting' => queueByDef.containsKey(defKey)
              ? queueByDef.get(defKey)
              : new List<Map<String, Object>>(),
            'waitingTruncated' => !classes.isEmpty() &&
            !queueByDef.containsKey(defKey)
          }
        );
      }
      return result;
    } catch (Exception ex) {
      throw new AuraHandledException(ex.getMessage());
    }
  }

  // Count of waiting instances per priority class, keyed by lower-cased workflow
  // name, then by priority as text. A blank priority (a row from before issue
  // #132) shows as the configured priority.
  private static Map<String, Map<String, Object>> waitingByPriority(
    Set<String> workflowNames
  ) {
    Map<String, Map<String, Object>> byDef = new Map<String, Map<String, Object>>();
    // Admission_Queue__c is set only while a row waits (see
    // ConcurrencyAdmissionOrder.isWaiting), and it is indexed.
    for (AggregateResult ar : [
      SELECT Admission_Queue__c wf, Admission_Priority__c p, COUNT(Id) cnt
      FROM Workflow_Instance__c
      WHERE Admission_Queue__c IN :workflowNames
      WITH SYSTEM_MODE
      GROUP BY Admission_Queue__c, Admission_Priority__c
      LIMIT :MAX_PRIORITY_GROUPS
    ]) {
      String wf = (String) ar.get('wf');
      String defKey = wf.toLowerCase();
      if (!byDef.containsKey(defKey)) {
        byDef.put(defKey, new Map<String, Object>());
      }
      Map<String, Object> classes = byDef.get(defKey);
      String priority = String.valueOf(priorityOf(wf, (Decimal) ar.get('p')));
      Integer prior = classes.containsKey(priority)
        ? (Integer) classes.get(priority)
        : 0;
      classes.put(priority, prior + (Integer) ar.get('cnt'));
    }
    return byDef;
  }

  // The next waiting instances of each workflow, in the gate order (key, then
  // Id). One query per workflow, so that a deep queue cannot hide another
  // queue. Only a workflow that has waiting rows is read. Workflows are read
  // in name order, so the same ones are skipped on each request. Stops before
  // the SOQL limit. Keyed by lower-cased workflow name. A skipped workflow has
  // no key.
  private static Map<String, List<Map<String, Object>>> waitingQueue(
    Set<String> waitingKeys,
    Set<String> workflowNames
  ) {
    List<String> ordered = new List<String>();
    for (String workflowName : workflowNames) {
      if (waitingKeys.contains(workflowName.toLowerCase())) {
        ordered.add(workflowName);
      }
    }
    ordered.sort();
    Map<String, List<Map<String, Object>>> byDef = new Map<String, List<Map<String, Object>>>();
    Integer reads = 0;
    Integer cap = maxQueueReadsOverride != null
      ? maxQueueReadsOverride
      : Limits.getLimitQueries() - Limits.getQueries() - QUEUE_QUERY_HEADROOM;
    for (String workflowName : ordered) {
      if (reads >= cap) {
        break;
      }
      byDef.put(workflowName.toLowerCase(), queueHead(workflowName));
      reads++;
    }
    return byDef;
  }

  // The first waiting instances of one workflow, with position and priority.
  private static List<Map<String, Object>> queueHead(String workflowName) {
    List<Map<String, Object>> queue = new List<Map<String, Object>>();
    for (Workflow_Instance__c inst : [
      SELECT Id, Name, Admission_Priority__c
      FROM Workflow_Instance__c
      WHERE Admission_Queue__c = :workflowName
      WITH SYSTEM_MODE
      ORDER BY Admission_Key__c ASC NULLS FIRST, Id ASC
      LIMIT :QUEUE_ROWS_PER_WORKFLOW
    ]) {
      queue.add(
        new Map<String, Object>{
          'instanceId' => inst.Id,
          'name' => inst.Name,
          'priority' => priorityOf(workflowName, inst.Admission_Priority__c),
          'position' => queue.size() + 1
        }
      );
    }
    return queue;
  }

  // The stored priority, or the priority the gate gives a blank row.
  private static Integer priorityOf(String workflowName, Decimal stored) {
    return stored != null
      ? stored.intValue()
      : ConcurrencyAdmissionOrder.resolvePriority(workflowName, null);
  }

  private static Integer sumCounts(Map<String, Object> classes) {
    Integer total = 0;
    for (Object count : classes.values()) {
      total += (Integer) count;
    }
    return total;
  }
}
