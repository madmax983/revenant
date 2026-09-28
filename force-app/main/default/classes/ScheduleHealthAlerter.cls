/**
 * @description Sends one alert for each schedule problem (issue #126). The
 * watchdog heartbeat calls it after the schedule sweep, so it adds no
 * scheduled job. It reads schedules and writes only Workflow_Log__c claim
 * rows. It never writes instance, step or schedule rows. Does not throw.
 *
 * Dedup: a Workflow_Log__c row with a unique Fire_Key__c claims each
 * problem (see ScheduleHealthAlert for the keys). A missed window or a
 * failure streak sends one alert. When no channel sends the alert, the claim is
 * deleted, so a later sweep tries again.
 *
 * Config: Workflow_Alert_Config__mdt for the schedule's workflow, then
 * Default. Alerts need Enable_Alerts__c and a channel.
 */
public inherited sharing class ScheduleHealthAlerter {
  // Claim insert, event publish, claim release and attempt upsert.
  private static final Integer DML_NEEDED = 4;
  // Rows: claim, event, release and attempt for each alert.
  private static final Integer ROWS_PER_ALERT = 4;
  private static final String LOG_SOURCE = 'ScheduleHealthAlert';
  // Maximum candidate pages for one sweep.
  private static final Integer MAX_PAGES = 5;
  // Candidate pages, last good fire query and claim query.
  private static final Integer SOQL_NEEDED = MAX_PAGES + 2;

  /** @description Maximum alerts for one sweep. The next sweep sends the rest. */
  @TestVisible
  private static Integer maxAlertsPerSweep = 10;

  @TestVisible
  private static Boolean forceBudgetExhausted = false;

  /**
   * @description Finds overdue and failed schedules and sends one alert for
   * each new problem. Does not throw.
   * @param now The evaluation time (the heartbeat time).
   * @return The number of alerts sent.
   */
  public static Integer detectAndAlert(Datetime now) {
    Integer sent = 0;
    try {
      if (now == null || !hasBudget()) {
        return 0;
      }
      ScheduleHealthClock clock = ScheduleHealthClock.forSweep(now);
      List<ScheduleHealthAlert> alerts = unclaimed(
        buildAlerts(
          ScheduleHealth.findUnhealthyPages(clock, MAX_PAGES),
          clock.graceMinutes
        )
      );
      if (alerts.isEmpty()) {
        return 0;
      }
      alerts = claim(alerts);
      try {
        dispatch(alerts);
      } finally {
        // Release runs also when dispatch throws, so no claim stays unsent.
        sent = release(alerts, now);
      }
      return sent;
    } catch (Exception ex) {
      WorkflowLog.error(
        LOG_SOURCE,
        'Schedule health alert failed: ' + ex.getMessage()
      );
      return sent;
    }
  }

  private static List<ScheduleHealthAlert> buildAlerts(
    List<ScheduleHealth.Assessment> found,
    Integer grace
  ) {
    List<ScheduleHealthAlert> alerts = new List<ScheduleHealthAlert>();
    Map<Id, Datetime> lastGoodFire = ScheduleFireHistory.lastGoodFireBySchedule(
      found
    );
    for (ScheduleHealth.Assessment a : found) {
      Workflow_Alert_Config__mdt config = configFor(a.schedule);
      if (!WorkflowAlertManager.isAlertActionable(config)) {
        continue;
      }
      if (a.overdue) {
        alerts.add(ScheduleHealthAlert.forOverdue(a, config, grace));
      }
      if (a.lastFireFailed) {
        alerts.add(
          ScheduleHealthAlert.forFailed(
            a,
            config,
            lastGoodFire.get(a.schedule.Id)
          )
        );
      }
    }
    return alerts;
  }

  private static Workflow_Alert_Config__mdt configFor(
    Workflow_Schedule__c sched
  ) {
    return String.isBlank(sched.Workflow_Name__c)
      ? null
      : WorkflowFailureAlertEvaluator.getAlertConfig(sched.Workflow_Name__c);
  }

  // Drops the alerts that a claim row already covers. Puts the alerts that
  // were never tried first, then the oldest attempt. Applies the cap.
  private static List<ScheduleHealthAlert> unclaimed(
    List<ScheduleHealthAlert> alerts
  ) {
    if (alerts.isEmpty()) {
      return alerts;
    }
    Set<String> keys = new Set<String>();
    for (ScheduleHealthAlert alert : alerts) {
      keys.add(alert.key);
      keys.add(alert.attemptKey());
    }
    Map<String, Workflow_Log__c> rowsByKey = new Map<String, Workflow_Log__c>();
    for (Workflow_Log__c row : [
      SELECT Fire_Key__c, Fire_Time__c
      FROM Workflow_Log__c
      WHERE Fire_Key__c IN :keys
      WITH SYSTEM_MODE
    ]) {
      rowsByKey.put(row.Fire_Key__c, row);
    }
    List<ScheduleHealthAlert> free = new List<ScheduleHealthAlert>();
    for (ScheduleHealthAlert alert : alerts) {
      if (rowsByKey.containsKey(alert.key)) {
        continue;
      }
      Workflow_Log__c attempt = rowsByKey.get(alert.attemptKey());
      alert.setQueueData(
        free.size(),
        attempt == null ? null : attempt.Fire_Time__c
      );
      free.add(alert);
    }
    free.sort();
    List<ScheduleHealthAlert> result = new List<ScheduleHealthAlert>();
    for (Integer i = 0; i < free.size() && i < maxAlertsPerSweep; i++) {
      result.add(free[i]);
    }
    return result;
  }

  // Inserts the claim rows. Keeps only the alerts whose claim is new.
  private static List<ScheduleHealthAlert> claim(
    List<ScheduleHealthAlert> alerts
  ) {
    List<Workflow_Log__c> rows = new List<Workflow_Log__c>();
    for (ScheduleHealthAlert alert : alerts) {
      rows.add(alert.toClaim());
    }
    List<Database.SaveResult> results = Database.insert(
      rows,
      false,
      AccessLevel.SYSTEM_MODE
    );
    List<ScheduleHealthAlert> claimed = new List<ScheduleHealthAlert>();
    for (Integer i = 0; i < results.size(); i++) {
      if (results[i].isSuccess()) {
        claimed.add(alerts[i]);
      }
    }
    return claimed;
  }

  // Sends one email for each recipient list and one event publish.
  private static void dispatch(List<ScheduleHealthAlert> alerts) {
    Map<String, List<ScheduleHealthAlert>> byRecipients = ScheduleHealthAlert.groupByRecipients(
      alerts
    );
    for (String recipients : byRecipients.keySet()) {
      List<ScheduleHealthAlert> members = byRecipients.get(recipients);
      if (
        WorkflowAlertEmailBuilder.sendEmail(
          ScheduleHealthAlert.buildEmail(recipients, members)
        )
      ) {
        ScheduleHealthAlert.markAllSent(members);
      }
    }
    publish(alerts);
  }

  private static void publish(List<ScheduleHealthAlert> alerts) {
    List<ScheduleHealthAlert> eventAlerts = new List<ScheduleHealthAlert>();
    List<Workflow_Alert__e> events = new List<Workflow_Alert__e>();
    for (ScheduleHealthAlert alert : alerts) {
      if (alert.config.Publish_Alert_Event__c == true) {
        eventAlerts.add(alert);
        events.add(alert.toEvent());
      }
    }
    // Mark each event on its own result, so a partial failure does not
    // release the claim of an event that the platform accepted.
    List<Boolean> results = WorkflowAlertManager.publishEachEvent(events);
    for (Integer i = 0; i < results.size(); i++) {
      if (results[i]) {
        eventAlerts[i].markSent();
      }
    }
  }

  // Deletes the claims of unsent alerts and records each attempt, so the
  // next sweep tries other alerts first. Returns the sent count.
  private static Integer release(
    List<ScheduleHealthAlert> alerts,
    Datetime now
  ) {
    List<Workflow_Log__c> unsent = new List<Workflow_Log__c>();
    List<Workflow_Log__c> attempts = new List<Workflow_Log__c>();
    Integer sent = 0;
    for (ScheduleHealthAlert alert : alerts) {
      if (alert.sent) {
        sent++;
      } else {
        unsent.add(alert.claim);
        attempts.add(alert.toAttempt(now));
      }
    }
    if (!unsent.isEmpty()) {
      Database.delete(unsent, false, AccessLevel.SYSTEM_MODE);
      Database.upsert(
        attempts,
        Workflow_Log__c.Fire_Key__c,
        false,
        AccessLevel.SYSTEM_MODE
      );
    }
    return sent;
  }

  // Keeps WatchdogLiveness.DML_RESERVE statements and queries free.
  private static Boolean hasBudget() {
    Integer dml = DML_NEEDED + WatchdogLiveness.DML_RESERVE;
    Integer soql = SOQL_NEEDED + WatchdogLiveness.DML_RESERVE;
    return !forceBudgetExhausted &&
      Limits.getDmlStatements() + dml <= Limits.getLimitDmlStatements() &&
      Limits.getDmlRows() + ROWS_PER_ALERT * maxAlertsPerSweep + dml <=
      Limits.getLimitDmlRows() &&
      Limits.getQueries() + soql <= Limits.getLimitQueries();
  }
}
