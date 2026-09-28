/**
 * @description Watchdog liveness marker (issue #113). Each good sweep writes
 * the time and cadence to the Watchdog_Liveness__c org-default row. Readers
 * compute HEALTHY, STALE or UNKNOWN from that row. The state is not stored,
 * so a new sweep clears STALE. Reads cost 0 SOQL.
 */
public inherited sharing class WatchdogLiveness {
  public static final String STATE_HEALTHY = 'HEALTHY';
  public static final String STATE_STALE = 'STALE';
  public static final String STATE_UNKNOWN = 'UNKNOWN';

  /** @description Stale threshold = this value × cadence. */
  public static final Integer STALE_MULTIPLIER = 2;

  // DML statements to keep free for the step commit after the heartbeat.
  private static final Integer DML_RESERVE = 5;
  private static final Integer DEFAULT_CADENCE_MINUTES = 10;

  @TestVisible
  private static Boolean forceDmlBudgetExhausted = false;

  /**
   * @description Liveness state at one point in time.
   */
  public class Snapshot {
    /** @description HEALTHY, STALE or UNKNOWN. */
    public String state;
    /** @description Time of the last good sweep, or null. */
    public Datetime lastSweepAt;
    /** @description Minutes since the last sweep, or null when UNKNOWN. */
    public Integer elapsedMinutes;
    /** @description Larger of the recorded and configured cadence. */
    public Integer cadenceMinutes;
    /** @description Elapsed time over this value is STALE. */
    public Integer thresholdMinutes;

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
   * @description Writes the sweep time and cadence. Best-effort: it skips when
   * the DML budget is low and never throws.
   * @param sweptAt Time of the good sweep.
   * @param cadenceMinutes Watchdog cadence for this sweep.
   */
  public static void recordSweep(Datetime sweptAt, Integer cadenceMinutes) {
    if (sweptAt == null || !hasDmlBudget()) {
      return;
    }
    try {
      Watchdog_Liveness__c current = Watchdog_Liveness__c.getOrgDefaults();
      // Set only the stamp fields, so the write changes nothing else.
      Watchdog_Liveness__c row = new Watchdog_Liveness__c(
        Last_Sweep_At__c = sweptAt,
        Cadence_Minutes__c = normalizeCadence(cadenceMinutes)
      );
      if (current == null || current.Id == null) {
        row.SetupOwnerId = UserInfo.getOrganizationId();
        insert as system row;
      } else {
        row.Id = current.Id;
        update as system row;
      }
    } catch (Exception ignored) {
      // Best-effort: a failed stamp must not stop the heartbeat.
    }
  }

  /**
   * @description Computes the liveness state now. Uses WorkflowEngine.mockNow
   * when a test sets it.
   * @return The snapshot.
   */
  public static Snapshot evaluateNow() {
    return evaluate(
      WorkflowEngine.mockNow != null ? WorkflowEngine.mockNow : System.now()
    );
  }

  /**
   * @description Computes the liveness state at the given time.
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
    Long elapsedMs = Math.max(0L, now.getTime() - snap.lastSweepAt.getTime());
    snap.elapsedMinutes = (elapsedMs / 60000L).intValue();
    snap.state = elapsedMs > snap.thresholdMinutes * 60000L
      ? STATE_STALE
      : STATE_HEALTHY;
    return snap;
  }

  /**
   * @description Makes a cadence usable: blank gives 10, less than 1 gives 1.
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
      Limits.getDmlStatements() + DML_RESERVE <
      Limits.getLimitDmlStatements() &&
      Limits.getDmlRows() + DML_RESERVE < Limits.getLimitDmlRows();
  }
}
