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
  // Claim insert, event publish and claim release.
  private static final Integer DML_NEEDED = 3;
  // Rows: one claim, one event and one release for each alert.
  private static final Integer ROWS_PER_ALERT = 3;
  private static final String LOG_SOURCE = 'ScheduleHealthAlert';
  // Candidate query, last good fire query and claim query.
  private static final Integer SOQL_NEEDED = 3;

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
        buildAlerts(ScheduleHealth.findUnhealthy(clock), clock.graceMinutes)
      );
      if (alerts.isEmpty()) {
        return 0;
      }
      alerts = claim(alerts);
      try {
        dispatch(alerts);
      } finally {
        // Release runs also when dispatch throws, so no claim stays unsent.
        sent = release(alerts);
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
    Map<Id, Datetime> lastGoodFire = ScheduleHealth.lastGoodFireBySchedule(
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

  // Drops the alerts that a claim row already covers. Applies the cap.
  private static List<ScheduleHealthAlert> unclaimed(
    List<ScheduleHealthAlert> alerts
  ) {
    if (alerts.isEmpty()) {
      return alerts;
    }
    Set<String> keys = new Set<String>();
    for (ScheduleHealthAlert alert : alerts) {
      keys.add(alert.key);
    }
    Set<String> taken = new Set<String>();
    for (Workflow_Log__c row : [
      SELECT Fire_Key__c
      FROM Workflow_Log__c
      WHERE Fire_Key__c IN :keys
      WITH SYSTEM_MODE
    ]) {
      taken.add(row.Fire_Key__c);
    }
    List<ScheduleHealthAlert> result = new List<ScheduleHealthAlert>();
    for (ScheduleHealthAlert alert : alerts) {
      if (!taken.contains(alert.key) && result.size() < maxAlertsPerSweep) {
        result.add(alert);
      }
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
    if (!events.isEmpty() && WorkflowAlertManager.publishEvents(events)) {
      ScheduleHealthAlert.markAllSent(eventAlerts);
    }
  }

  // Deletes the claims of unsent alerts. Returns the sent count.
  private static Integer release(List<ScheduleHealthAlert> alerts) {
    List<Workflow_Log__c> unsent = new List<Workflow_Log__c>();
    Integer sent = 0;
    for (ScheduleHealthAlert alert : alerts) {
      if (alert.sent) {
        sent++;
      } else {
        unsent.add(alert.claim);
      }
    }
    if (!unsent.isEmpty()) {
      Database.delete(unsent, false, AccessLevel.SYSTEM_MODE);
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
