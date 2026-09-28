/**
 * @description Builds the Fleet Health summary (#111). It makes one row for each definition
 * that has instances in a rolling window. It does no DML, publishes no events and starts no
 * jobs.
 *
 * Cost: three queries for each call. Query rows are at most 2 * COUNT_CAP + SAMPLE_CAP + 2
 * for all instance volumes. This is true if an aggregate query uses one query row for each
 * group or one query row for each record. See ADR 0004.
 */
public inherited sharing class WorkflowFleetHealthService {
  private static final Map<String, Integer> WINDOW_HOURS = new Map<String, Integer>{
    '1h' => 1,
    '24h' => 24,
    '7d' => 168
  };
  private static final String DEFAULT_WINDOW = '24h';

  // The maximum number of started instances that the counts read. Above this number, the
  // counts use the newest COUNT_CAP instances. 2 * 20,000 + 2,000 stays below the
  // 50,000-row limit, also when each aggregated record uses one query row.
  private static final Integer COUNT_CAP = 20000;

  // The maximum number of terminal rows that the duration query reads.
  private static final Integer SAMPLE_CAP = 2000;

  // Tests set these caps. They are null in production.
  @TestVisible
  private static Integer countCapOverride = null;
  @TestVisible
  private static Integer sampleCapOverride = null;

  private static final Set<String> COMPLETED_STATUSES = new Set<String>{
    'Completed',
    'ContinuedAsNew'
  };
  // CompensationFailed is an active status (no Terminal_At__c). Its outcome is a failure.
  private static final Set<String> FAILED_STATUSES = new Set<String>{
    'Failed',
    'CompensationFailed',
    'Compensated',
    'Cancelled'
  };
  // DefinitionChanged is a parked, active status (#89).
  private static final Set<String> IN_FLIGHT_STATUSES = new Set<String>{
    'Running',
    'Suspended',
    'Paused',
    'Compensating',
    'Cancelling',
    'Pending',
    'DefinitionChanged'
  };

  /**
   * @description Returns the Fleet Health summary for a window. The counts use the instances
   * that started in the window. The durations use the instances that got a Terminal_At__c
   * in the window.
   * @param windowKey '1h', '24h' or '7d'. A blank or unknown key gives '24h'.
   * @return A map with windowKey, windowHours, countCap, countsCapped, sampleCap, isSampled
   *         and rows. The rows go from the lowest success rate to the highest. A row with no
   *         rate goes last.
   */
  public static Map<String, Object> fleetHealth(String windowKey) {
    WorkflowDashboardSupport.checkAuthorization();

    String resolvedKey = WINDOW_HOURS.containsKey(windowKey)
      ? windowKey
      : DEFAULT_WINDOW;
    Integer windowHours = WINDOW_HOURS.get(resolvedKey);
    Datetime since = Datetime.now().addHours(-windowHours);

    try {
      Map<String, DefinitionHealth> byName = new Map<String, DefinitionHealth>();
      Boolean countsCapped = addCounts(byName, since);
      Boolean isSampled = addDurations(byName, since);

      List<DefinitionHealth> ordered = byName.values();
      ordered.sort();
      List<Map<String, Object>> rows = new List<Map<String, Object>>();
      for (DefinitionHealth health : ordered) {
        rows.add(health.toRow(isSampled));
      }

      return new Map<String, Object>{
        'windowKey' => resolvedKey,
        'windowHours' => windowHours,
        'countCap' => countCap(),
        'countsCapped' => countsCapped,
        'sampleCap' => sampleCap(),
        'isSampled' => isSampled,
        'rows' => rows
      };
    } catch (Exception ex) {
      throw WorkflowDashboardSupport.auraError(ex.getMessage());
    }
  }

  // Adds the status counts of the instances started in the window. Returns true when the
  // window has more than countCap() instances. Then the counts use the newest countCap().
  private static Boolean addCounts(
    Map<String, DefinitionHealth> byName,
    Datetime since
  ) {
    Integer cap = countCap();
    Integer probeLimit = cap + 1;
    Integer inWindow = [
      SELECT COUNT()
      FROM Workflow_Instance__c
      WHERE CreatedDate >= :since
      WITH SYSTEM_MODE
      LIMIT :probeLimit
    ];

    if (inWindow > cap) {
      // A SOQL for loop reads 200 rows at a time. This keeps the heap small.
      for (Workflow_Instance__c inst : [
        SELECT Workflow_Name__c, Status__c
        FROM Workflow_Instance__c
        WHERE CreatedDate >= :since
        WITH SYSTEM_MODE
        ORDER BY CreatedDate DESC
        LIMIT :cap
      ]) {
        healthFor(byName, inst.Workflow_Name__c).addCount(inst.Status__c, 1);
      }
      return true;
    }

    // Use a list, not a SOQL for loop. An aggregate for loop fails when it has more than
    // 2,000 groups.
    List<AggregateResult> groups = [
      SELECT Workflow_Name__c, Status__c, COUNT(Id) cnt
      FROM Workflow_Instance__c
      WHERE CreatedDate >= :since
      WITH SYSTEM_MODE
      GROUP BY Workflow_Name__c, Status__c
    ];
    for (AggregateResult ar : groups) {
      healthFor(byName, (String) ar.get('Workflow_Name__c'))
        .addCount((String) ar.get('Status__c'), (Integer) ar.get('cnt'));
    }
    return false;
  }

  // Adds the durations of the newest sampleCap() instances that got a Terminal_At__c in the
  // window. Returns true when more instances exist. The query reads one extra row to know.
  private static Boolean addDurations(
    Map<String, DefinitionHealth> byName,
    Datetime since
  ) {
    Integer cap = sampleCap();
    Integer probeLimit = cap + 1;
    List<Workflow_Instance__c> sample = [
      SELECT Workflow_Name__c, CreatedDate, Terminal_At__c
      FROM Workflow_Instance__c
      WHERE Terminal_At__c >= :since
      WITH SYSTEM_MODE
      ORDER BY Terminal_At__c DESC
      LIMIT :probeLimit
    ];
    Integer used = Math.min(sample.size(), cap);
    for (Integer i = 0; i < used; i++) {
      Workflow_Instance__c inst = sample[i];
      healthFor(byName, inst.Workflow_Name__c)
        .addDuration(
          inst.Terminal_At__c.getTime() - inst.CreatedDate.getTime()
        );
    }
    return sample.size() > cap;
  }

  private static Integer countCap() {
    return countCapOverride != null ? countCapOverride : COUNT_CAP;
  }

  private static Integer sampleCap() {
    return sampleCapOverride != null ? sampleCapOverride : SAMPLE_CAP;
  }

  // SOQL GROUP BY ignores case. The lower-case key does the same, so one definition gets
  // one row. The row keeps the first spelling.
  private static DefinitionHealth healthFor(
    Map<String, DefinitionHealth> byName,
    String workflowName
  ) {
    String key = workflowName.toLowerCase();
    DefinitionHealth health = byName.get(key);
    if (health == null) {
      health = new DefinitionHealth(workflowName);
      byName.put(key, health);
    }
    return health;
  }

  /**
   * @description This class holds the counts and durations for one definition. It sorts by
   * success rate, lowest first. A row with no rate goes last. Rows with equal rates sort by
   * name.
   */
  private class DefinitionHealth implements Comparable {
    String workflowName;
    Integer started = 0;
    Integer completed = 0;
    Integer failed = 0;
    Integer inFlight = 0;
    Integer sampleSize = 0;
    Long totalMs = 0;
    Long maxMs = null;

    DefinitionHealth(String workflowName) {
      this.workflowName = workflowName;
    }

    // A status that is not in a bucket adds to started only.
    void addCount(String status, Integer count) {
      started += count;
      if (COMPLETED_STATUSES.contains(status)) {
        completed += count;
      } else if (FAILED_STATUSES.contains(status)) {
        failed += count;
      } else if (IN_FLIGHT_STATUSES.contains(status)) {
        inFlight += count;
      }
    }

    void addDuration(Long durationMs) {
      Long ms = Math.max(durationMs, 0L);
      sampleSize++;
      totalMs += ms;
      maxMs = (maxMs == null) ? ms : Math.max(maxMs, ms);
    }

    Decimal successRate() {
      Integer terminal = completed + failed;
      return terminal == 0
        ? null
        : (Decimal.valueOf(completed) * 100)
            .divide(terminal, 1, System.RoundingMode.HALF_UP);
    }

    Map<String, Object> toRow(Boolean isSampled) {
      return new Map<String, Object>{
        'workflowName' => workflowName,
        'started' => started,
        'completed' => completed,
        'failed' => failed,
        'inFlight' => inFlight,
        'successRate' => successRate(),
        'avgDurationMs' => sampleSize == 0 ? null : totalMs / sampleSize,
        'maxDurationMs' => maxMs,
        'durationSampleSize' => sampleSize,
        'durationSampled' => isSampled
      };
    }

    /**
     * @description Compares by success rate, lowest first. A row with no rate goes last.
     * @param other The other DefinitionHealth.
     * @return A negative, zero or positive value (Comparable contract).
     */
    public Integer compareTo(Object other) {
      DefinitionHealth that = (DefinitionHealth) other;
      Decimal mine = this.successRate();
      Decimal theirs = that.successRate();
      if (mine != theirs) {
        if (mine == null) {
          return 1;
        }
        if (theirs == null) {
          return -1;
        }
        return mine < theirs ? -1 : 1;
      }
      return this.workflowName.compareTo(that.workflowName);
    }
  }
}
