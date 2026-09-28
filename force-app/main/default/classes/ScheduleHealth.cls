/**
 * @description Schedule health (issue #126). Finds an enabled schedule that
 * did not fire in its window (overdue) or whose last fire failed. assess()
 * does no SOQL and no DML. The dashboard, the schedule manager and
 * ScheduleHealthAlerter use the same rules.
 *
 * Overdue: enabled, not dedicated, and now − reference > one sweep
 * interval, and Last_Fired_Window__c is before Next_Fire_Window__c.
 * Reference = the later of Next_Fire_Window__c and LastModifiedDate. The
 * rule compares UTC instants, so DST and zone offsets have no effect.
 * Dedicated schedules are not checked for overdue: their CronTrigger uses
 * the time zone of the user who armed it, not Time_Zone__c.
 *
 * Last fire failed: enabled, and Last_Outcome__c is a failure outcome.
 */
public inherited sharing class ScheduleHealth {
  /** @description Enabled, no problem found. */
  public static final String STATUS_OK = 'OK';
  /** @description Disabled. Never reported. */
  public static final String STATUS_DISABLED = 'DISABLED';
  /** @description The window is past and the schedule did not fire. */
  public static final String STATUS_OVERDUE = 'OVERDUE';
  /** @description The last fire recorded a failure outcome. */
  public static final String STATUS_FAILED = 'FAILED';

  /** @description Last_Outcome__c values that are failures. */
  public static final Set<String> FAILED_OUTCOMES = new Set<String>{
    'Error',
    'Invalid cron',
    'Invalid time zone'
  };

  /** @description Maximum rows that findUnhealthy() reads. */
  public static final Integer MAX_ROWS = 200;

  /** @description Maximum rows that summary() returns for display. */
  public static final Integer MAX_DISPLAY_ROWS = 50;

  /**
   * @description Health of one schedule at one point in time.
   */
  public class Assessment {
    /** @description The assessed schedule. */
    public Workflow_Schedule__c schedule;
    /** @description OK, PAUSED, OVERDUE or FAILED. OVERDUE has priority over FAILED. */
    public String status = STATUS_OK;
    /** @description True when the schedule is overdue. */
    public Boolean overdue = false;
    /** @description True when the last fire failed. */
    public Boolean lastFireFailed = false;
    /** @description The instant the overdue rule measures from, or null. */
    public Datetime reference;
    /** @description Minutes after the reference, or null when not overdue. */
    public Integer lapsedMinutes;

    /**
     * @description Returns the assessment as a dashboard map.
     * @return Map of display fields.
     */
    public Map<String, Object> toMap() {
      return new Map<String, Object>{
        'id' => schedule.Id,
        'name' => schedule.Name,
        'workflowName' => schedule.Workflow_Name__c,
        'status' => status,
        'overdue' => overdue,
        'lastFireFailed' => lastFireFailed,
        'lastOutcome' => schedule.Last_Outcome__c,
        'nextFireWindow' => schedule.Next_Fire_Window__c,
        'lastFiredWindow' => schedule.Last_Fired_Window__c,
        'lapsedMinutes' => lapsedMinutes
      };
    }
  }

  /**
   * @description Returns the current time. Uses WorkflowEngine.mockNow when a
   * test sets it.
   * @return The evaluation time.
   */
  public static Datetime now() {
    return WorkflowEngine.mockNow != null
      ? WorkflowEngine.mockNow
      : System.now();
  }

  /**
   * @description Returns one sweep interval in minutes: the larger of the
   * recorded and the configured watchdog cadence. Costs 0 SOQL.
   * @return The grace period in minutes.
   */
  public static Integer graceMinutes() {
    return WatchdogLiveness.evaluateNow().cadenceMinutes;
  }

  /**
   * @description Assesses one schedule. Does no SOQL and no DML.
   * @param sched The schedule. Needs Enabled__c, Dedicated_Slot__c,
   * Next_Fire_Window__c, Last_Fired_Window__c, Last_Outcome__c and
   * LastModifiedDate.
   * @param now The evaluation time.
   * @param graceMinutes One sweep interval in minutes.
   * @return The assessment.
   */
  public static Assessment assess(
    Workflow_Schedule__c sched,
    Datetime now,
    Integer graceMinutes
  ) {
    Assessment a = new Assessment();
    a.schedule = sched;
    if (sched.Enabled__c != true) {
      a.status = STATUS_DISABLED;
      return a;
    }
    a.lastFireFailed = FAILED_OUTCOMES.contains(sched.Last_Outcome__c);
    a.reference = reference(sched);
    if (isOverdue(a, now, graceMinutes)) {
      a.overdue = true;
      a.lapsedMinutes = ((now.getTime() - a.reference.getTime()) / 60000L)
        .intValue();
    }
    if (a.overdue) {
      a.status = STATUS_OVERDUE;
    } else if (a.lastFireFailed) {
      a.status = STATUS_FAILED;
    }
    return a;
  }

  // The later of the cursor and the last edit. A blank cursor uses the edit.
  private static Datetime reference(Workflow_Schedule__c sched) {
    Datetime cursor = sched.Next_Fire_Window__c;
    Datetime edited = sched.LastModifiedDate;
    if (cursor == null) {
      return edited;
    }
    if (edited == null || cursor > edited) {
      return cursor;
    }
    return edited;
  }

  private static Boolean isOverdue(
    Assessment a,
    Datetime now,
    Integer graceMinutes
  ) {
    Workflow_Schedule__c sched = a.schedule;
    if (sched.Dedicated_Slot__c == true || a.reference == null || now == null) {
      return false;
    }
    Datetime cursor = sched.Next_Fire_Window__c;
    Datetime fired = sched.Last_Fired_Window__c;
    if (cursor != null && fired != null && fired >= cursor) {
      return false;
    }
    Long graceMs = 60000L * (graceMinutes == null ? 0 : graceMinutes);
    return now.getTime() - a.reference.getTime() > graceMs;
  }

  /**
   * @description Reads the enabled schedules that can be overdue or failed,
   * then assesses each. Returns only the unhealthy ones. One SOQL query.
   * @param now The evaluation time.
   * @param graceMinutes One sweep interval in minutes.
   * @return Unhealthy assessments, oldest cursor first.
   */
  public static List<Assessment> findUnhealthy(
    Datetime now,
    Integer graceMinutes
  ) {
    return keepUnhealthy(queryCandidates(now, graceMinutes), now, graceMinutes);
  }

  private static List<Assessment> keepUnhealthy(
    List<Workflow_Schedule__c> candidates,
    Datetime now,
    Integer graceMinutes
  ) {
    List<Assessment> result = new List<Assessment>();
    for (Workflow_Schedule__c sched : candidates) {
      Assessment a = assess(sched, now, graceMinutes);
      if (a.overdue || a.lastFireFailed) {
        result.add(a);
      }
    }
    return result;
  }

  // The SOQL filter is a superset of the rules. assess() decides.
  private static List<Workflow_Schedule__c> queryCandidates(
    Datetime now,
    Integer graceMinutes
  ) {
    Datetime cutoff = now.addMinutes(-graceMinutes);
    Integer maxRows = MAX_ROWS;
    return [
      SELECT
        Id,
        Name,
        Workflow_Name__c,
        Correlation_Key_Prefix__c,
        Enabled__c,
        Dedicated_Slot__c,
        Next_Fire_Window__c,
        Last_Fired_Window__c,
        Last_Outcome__c,
        LastModifiedDate
      FROM Workflow_Schedule__c
      WHERE
        Enabled__c = TRUE
        AND (Last_Outcome__c IN :FAILED_OUTCOMES
        OR (Dedicated_Slot__c = FALSE
        AND LastModifiedDate < :cutoff
        AND (Next_Fire_Window__c = NULL
        OR Next_Fire_Window__c < :cutoff)))
      WITH SYSTEM_MODE
      ORDER BY Next_Fire_Window__c ASC NULLS FIRST, Name ASC
      LIMIT :maxRows
    ];
  }

  /**
   * @description Returns the System Doctor summary: counts, grace and up to
   * MAX_DISPLAY_ROWS rows. One SOQL query.
   * @return Map with overdueCount, failedCount, graceMinutes, truncated and rows.
   */
  public static Map<String, Object> summary() {
    Integer grace = graceMinutes();
    Datetime evalAt = now();
    List<Workflow_Schedule__c> candidates = queryCandidates(evalAt, grace);
    List<Assessment> found = keepUnhealthy(candidates, evalAt, grace);
    Integer overdueCount = 0;
    Integer failedCount = 0;
    List<Map<String, Object>> rows = new List<Map<String, Object>>();
    for (Assessment a : found) {
      overdueCount += a.overdue ? 1 : 0;
      failedCount += a.lastFireFailed ? 1 : 0;
      if (rows.size() < MAX_DISPLAY_ROWS) {
        rows.add(a.toMap());
      }
    }
    return new Map<String, Object>{
      'overdueCount' => overdueCount,
      'failedCount' => failedCount,
      'graceMinutes' => grace,
      'truncated' => candidates.size() >= MAX_ROWS ||
      found.size() > rows.size(),
      'rows' => rows
    };
  }
}
