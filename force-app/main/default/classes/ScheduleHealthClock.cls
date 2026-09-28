/**
 * @description The time values that the schedule health rules use (issue
 * #126): the evaluation time, one sweep interval, and the time of the last
 * sweep. Costs 0 SOQL.
 */
public inherited sharing class ScheduleHealthClock {
  /** @description The evaluation time. */
  public Datetime now { get; private set; }
  /** @description One sweep interval in minutes. */
  public Integer graceMinutes { get; private set; }
  /**
   * @description Time of the last sweep. A reference after this time is not
   * overdue, because no sweep had a chance to fire it.
   */
  public Datetime sweptAt { get; private set; }

  /**
   * @description Makes a clock.
   * @param now The evaluation time.
   * @param graceMinutes One sweep interval in minutes. Null means 0.
   * @param sweptAt Time of the last sweep. Null means now.
   */
  public ScheduleHealthClock(
    Datetime now,
    Integer graceMinutes,
    Datetime sweptAt
  ) {
    this.now = now;
    this.graceMinutes = graceMinutes == null ? 0 : graceMinutes;
    this.sweptAt = sweptAt == null ? now : sweptAt;
  }

  /**
   * @description Returns the current time. Uses WorkflowEngine.mockNow when a
   * test sets it.
   * @return The evaluation time.
   */
  public static Datetime currentTime() {
    return WorkflowEngine.mockNow != null
      ? WorkflowEngine.mockNow
      : System.now();
  }

  /**
   * @description Returns one sweep interval in minutes: the larger of the
   * recorded cadence and Watchdog_Delay_Minutes__c.
   * @return The grace period in minutes.
   */
  public static Integer sweepIntervalMinutes() {
    return WatchdogLiveness.evaluateNow().cadenceMinutes;
  }

  /**
   * @description Clock for the heartbeat. The sweep ran in this transaction,
   * so the last sweep time is now.
   * @param now The heartbeat time.
   * @return The clock.
   */
  public static ScheduleHealthClock forSweep(Datetime now) {
    return new ScheduleHealthClock(now, sweepIntervalMinutes(), now);
  }

  /**
   * @description Clock for a dashboard read. When the watchdog is HEALTHY,
   * it uses the last sweep time, so a read between sweeps shows no false
   * overdue. When it is STALE or UNKNOWN, it uses now, so the read shows the
   * schedules that do not fire.
   * @return The clock.
   */
  public static ScheduleHealthClock forRead() {
    WatchdogLiveness.Snapshot snap = WatchdogLiveness.evaluateNow();
    Datetime evalAt = currentTime();
    Datetime sweptAt = snap.state == WatchdogLiveness.STATE_HEALTHY
      ? snap.lastSweepAt
      : evalAt;
    return new ScheduleHealthClock(evalAt, snap.cadenceMinutes, sweptAt);
  }
}
