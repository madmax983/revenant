/**
 * @description Builds the Fleet Health summary (#111). One row for each definition with
 * instances started in a rolling window. Read-only: no DML, no events, no jobs.
 *
 * Cost: two queries for each call. The count query uses COUNT only, so it uses one query
 * row for each group. The duration sample has a fixed LIMIT. See ADR 0004.
 */
public inherited sharing class WorkflowFleetHealthService {
  private static final Map<String, Integer> WINDOW_HOURS = new Map<String, Integer>{
    '1h' => 1,
    '24h' => 24,
    '7d' => 168
  };
  private static final String DEFAULT_WINDOW = '24h';

  // Maximum terminal rows read for the durations.
  private static final Integer SAMPLE_CAP = 2000;

  // Test-only cap. Null in production.
  @TestVisible
  private static Integer sampleCapOverride = null;

  private static final Set<String> COMPLETED_STATUSES = new Set<String>{
    'Completed',
    'ContinuedAsNew'
  };
  // CompensationFailed is active (no Terminal_At__c), but its outcome is a failure.
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
  // Statuses that set Terminal_At__c. Only these rows can be in the duration sample.
  private static final Set<String> TIMED_STATUSES = new Set<String>{
    'Completed',
    'ContinuedAsNew',
    'Failed',
    'Compensated',
    'Cancelled'
  };

  /**
   * @description Returns the Fleet Health summary for a window. The cohort is the set of
   * instances with CreatedDate in the window.
   * @param windowKey '1h', '24h' or '7d'. A blank or unknown key gives '24h'.
   * @return A map with windowKey, windowHours, sampleCap, isSampled and rows. The rows go
   *         from the lowest success rate to the highest. Rows with no rate go last.
   */
  public static Map<String, Object> fleetHealth(String windowKey) {
    WorkflowDashboardSupport.checkAuthorization();

    String resolvedKey = WINDOW_HOURS.containsKey(windowKey)
      ? windowKey
      : DEFAULT_WINDOW;
    Integer windowHours = WINDOW_HOURS.get(resolvedKey);
    Datetime since = Datetime.now().addHours(-windowHours);
    Integer cap = sampleCap();

    Map<String, DefinitionHealth> byName = new Map<String, DefinitionHealth>();
    // A list, not a SOQL for loop: an aggregate for loop fails above 2,000 groups.
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

    List<Workflow_Instance__c> sample = [
      SELECT Workflow_Name__c, CreatedDate, Terminal_At__c
      FROM Workflow_Instance__c
      WHERE CreatedDate >= :since AND Terminal_At__c != NULL
      WITH SYSTEM_MODE
      ORDER BY Terminal_At__c DESC
      LIMIT :cap
    ];
    for (Workflow_Instance__c inst : sample) {
      healthFor(byName, inst.Workflow_Name__c)
        .addDuration(
          inst.Terminal_At__c.getTime() - inst.CreatedDate.getTime()
        );
    }

    List<DefinitionHealth> ordered = byName.values();
    ordered.sort();
    List<Map<String, Object>> rows = new List<Map<String, Object>>();
    for (DefinitionHealth health : ordered) {
      rows.add(health.toRow());
    }

    return new Map<String, Object>{
      'windowKey' => resolvedKey,
      'windowHours' => windowHours,
      'sampleCap' => cap,
      'isSampled' => sample.size() >= cap,
      'rows' => rows
    };
  }

  private static Integer sampleCap() {
    return sampleCapOverride != null ? sampleCapOverride : SAMPLE_CAP;
  }

  private static DefinitionHealth healthFor(
    Map<String, DefinitionHealth> byName,
    String workflowName
  ) {
    DefinitionHealth health = byName.get(workflowName);
    if (health == null) {
      health = new DefinitionHealth(workflowName);
      byName.put(workflowName, health);
    }
    return health;
  }

  /**
   * @description Counts and durations for one definition. Sorts by success rate, lowest
   * first. Rows with no rate go last. Equal rates sort by name.
   */
  private class DefinitionHealth implements Comparable {
    String workflowName;
    Integer started = 0;
    Integer completed = 0;
    Integer failed = 0;
    Integer inFlight = 0;
    Integer timedTerminal = 0;
    Integer sampleSize = 0;
    Long totalMs = 0;
    Long maxMs = null;

    DefinitionHealth(String workflowName) {
      this.workflowName = workflowName;
    }

    void addCount(String status, Integer count) {
      started += count;
      if (COMPLETED_STATUSES.contains(status)) {
        completed += count;
      } else if (FAILED_STATUSES.contains(status)) {
        failed += count;
      } else if (IN_FLIGHT_STATUSES.contains(status)) {
        inFlight += count;
      }
      if (TIMED_STATUSES.contains(status)) {
        timedTerminal += count;
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

    Map<String, Object> toRow() {
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
        'durationSampled' => sampleSize < timedTerminal
      };
    }

    /**
     * @description Compares by success rate, lowest first. No rate goes last.
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
