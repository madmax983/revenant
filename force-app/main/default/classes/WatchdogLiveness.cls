/**
 * @description Watchdog liveness marker (issue #113). Each complete sweep
 * writes its time and cadence to the Watchdog_Liveness__c org-default row.
 * Each read calculates HEALTHY, STALE or UNKNOWN from that row. No record
 * keeps the state, so the next sweep clears STALE. A read costs 0 SOQL.
 */
public inherited sharing class WatchdogLiveness {
  /** @description Elapsed time is not more than the threshold. */
  public static final String STATE_HEALTHY = 'HEALTHY';
  /** @description Elapsed time is more than the threshold. */
  public static final String STATE_STALE = 'STALE';
  /** @description No sweep is recorded. */
  public static final String STATE_UNKNOWN = 'UNKNOWN';

  /** @description Stale threshold = this value × cadence. */
  public static final Integer STALE_MULTIPLIER = 2;

  /**
   * @description DML statements to keep free for the caller. Same value as
   * the checkpoint reserve in WorkflowBreadcrumbs.
   */
  public static final Integer DML_RESERVE = 10;

  private static final Integer DEFAULT_CADENCE_MINUTES = 10;

  @TestVisible
  private static Boolean forceDmlBudgetExhausted = false;

  /**
   * @description Liveness state at one point in time.
   */
  public class Snapshot {
    /** @description HEALTHY, STALE or UNKNOWN. */
    public String state;
    /** @description Time of the last complete sweep, or null. */
    public Datetime lastSweepAt;
    /** @description Minutes since the last sweep, or null when UNKNOWN. */
    public Integer elapsedMinutes;
    /** @description Larger of the recorded and configured cadence. */
    public Integer cadenceMinutes;
    /** @description The state is STALE when elapsed time is more than this. */
    public Integer thresholdMinutes;
    /** @description True when this stall has sent its alert. */
    public Boolean alertSent = false;

    /**
     * @description Returns the snapshot as a dashboard map.
     * @return Map with state, lastSweepAt, elapsedMinutes, thresholdMinutes and cadenceMinutes.
     */
    public Map<String, Object> toMap() {
      return new Map<String, Object>{
        'state' => state,
        'lastSweepAt' => lastSweepAt,
        'elapsedMinutes' => elapsedMinutes,
        'thresholdMinutes' => thresholdMinutes,
        'cadenceMinutes' => cadenceMinutes
      };
    }
  }

  /**
   * @description Writes the sweep time and cadence. Does not write when the
   * DML budget is low. Does not throw.
   * @param sweptAt Time of the complete sweep.
   * @param cadenceMinutes Watchdog cadence for this sweep.
   */
  public static void recordSweep(Datetime sweptAt, Integer cadenceMinutes) {
    if (sweptAt == null) {
      return;
    }
    write(
      new Watchdog_Liveness__c(
        Last_Sweep_At__c = sweptAt,
        Cadence_Minutes__c = normalizeCadence(cadenceMinutes)
      )
    );
  }

  /**
   * @description Records that the stall after this sweep sent its alert.
   * Writes only Last_Alert_Sweep_At__c. Does not throw.
   * @param sweptAt Last_Sweep_At__c value of the stall.
   */
  public static void markAlertSent(Datetime sweptAt) {
    if (sweptAt == null) {
      return;
    }
    write(new Watchdog_Liveness__c(Last_Alert_Sweep_At__c = sweptAt));
  }

  // Inserts or updates the org-default row. The row sets only the fields to
  // change, so two writers do not overwrite each other.
  private static void write(Watchdog_Liveness__c row) {
    if (!hasDmlBudget()) {
      return;
    }
    try {
      Watchdog_Liveness__c current = Watchdog_Liveness__c.getOrgDefaults();
      if (current == null || current.Id == null) {
        row.SetupOwnerId = UserInfo.getOrganizationId();
        insert as system row;
      } else {
        row.Id = current.Id;
        update as system row;
      }
    } catch (Exception ignored) {
      // A failed write must not stop the caller.
    }
  }

  /**
   * @description Calculates the state now. Uses WorkflowEngine.mockNow when a
   * test sets it.
   * @return The snapshot.
   */
  public static Snapshot evaluateNow() {
    return evaluate(
      WorkflowEngine.mockNow != null ? WorkflowEngine.mockNow : System.now()
    );
  }

  /**
   * @description Calculates the state at the given time.
   * @param now Evaluation time.
   * @return The snapshot.
   */
  public static Snapshot evaluate(Datetime now) {
    Watchdog_Liveness__c row = Watchdog_Liveness__c.getOrgDefaults();
    Integer configured = normalizeCadence(WorkflowEngine.watchdogDelayMinutes);
    Integer recorded = (row == null ||
      row.Cadence_Minutes__c == null)
      ? configured
      : normalizeCadence(row.Cadence_Minutes__c.intValue());

    Snapshot snap = new Snapshot();
    snap.cadenceMinutes = Math.max(recorded, configured);
    snap.thresholdMinutes = STALE_MULTIPLIER * snap.cadenceMinutes;
    if (row == null || row.Last_Sweep_At__c == null) {
      snap.state = STATE_UNKNOWN;
      return snap;
    }

    snap.lastSweepAt = row.Last_Sweep_At__c;
    snap.alertSent = row.Last_Alert_Sweep_At__c == row.Last_Sweep_At__c;
    Long elapsedMs = Math.max(0L, now.getTime() - snap.lastSweepAt.getTime());
    snap.elapsedMinutes = (elapsedMs / 60000L).intValue();
    snap.state = elapsedMs > snap.thresholdMinutes * 60000L
      ? STATE_STALE
      : STATE_HEALTHY;
    return snap;
  }

  /**
   * @description Returns 10 for null and 1 for a value less than 1.
   * @param cadenceMinutes Raw cadence.
   * @return Cadence of 1 minute or more.
   */
  public static Integer normalizeCadence(Integer cadenceMinutes) {
    if (cadenceMinutes == null) {
      return DEFAULT_CADENCE_MINUTES;
    }
    return Math.max(1, cadenceMinutes);
  }

  private static Boolean hasDmlBudget() {
    return !forceDmlBudgetExhausted &&
      Limits.getDmlStatements() + 1 + DML_RESERVE <=
      Limits.getLimitDmlStatements() &&
      Limits.getDmlRows() + 1 + DML_RESERVE <= Limits.getLimitDmlRows();
  }
}
