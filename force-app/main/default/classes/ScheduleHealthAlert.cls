/**
 * @description One problem of one schedule (issue #126): an overdue window
 * or a failed fire. Builds the dedup key, the message, the claim row, the
 * alert event and the alert email. Does no SOQL and no DML.
 * ScheduleHealthAlerter sends it.
 */
public inherited sharing class ScheduleHealthAlert {
  /** @description Log_Type__c of the claim row. */
  public static final String LOG_TYPE = 'ScheduleHealthAlert';
  /** @description Alert_Reason__c for an overdue schedule. */
  public static final String REASON_OVERDUE = 'Schedule Overdue';
  /** @description Alert_Reason__c for a failed fire. */
  public static final String REASON_FAILED = 'Schedule Fire Failed';
  /** @description Outcome__c of an overdue claim row. */
  public static final String OUTCOME_OVERDUE = 'Overdue';
  /** @description Outcome__c of a failed claim row. */
  public static final String OUTCOME_FAILED = 'Fire failed';

  private static final String OVERDUE_PREFIX = 'ScheduleOverdue:';
  private static final String FAILED_PREFIX = 'ScheduleFailed:';

  /** @description The assessed schedule. */
  public ScheduleHealth.Assessment assessment { get; private set; }
  /** @description True for an overdue alert, false for a failed-fire alert. */
  public Boolean overdue { get; private set; }
  /** @description The resolved alert config. */
  public Workflow_Alert_Config__mdt config { get; private set; }
  /** @description The unique dedup key (Fire_Key__c of the claim row). */
  public String key { get; private set; }
  /** @description The alert text. */
  public String message { get; private set; }
  /** @description The claim row after toClaim(). */
  public Workflow_Log__c claim { get; private set; }
  /** @description True when a channel sent the alert. */
  public Boolean sent { get; private set; }

  private ScheduleHealthAlert(
    ScheduleHealth.Assessment assessment,
    Workflow_Alert_Config__mdt config
  ) {
    this.assessment = assessment;
    this.config = config;
    this.sent = false;
  }

  /**
   * @description Builds an overdue alert. Key: schedule Id + cursor. The
   * key stays the same while the same window stays missed.
   * @param a The assessment. a.overdue must be true.
   * @param config The resolved alert config.
   * @param graceMinutes One sweep interval in minutes.
   * @return The alert.
   */
  public static ScheduleHealthAlert forOverdue(
    ScheduleHealth.Assessment a,
    Workflow_Alert_Config__mdt config,
    Integer graceMinutes
  ) {
    ScheduleHealthAlert alert = new ScheduleHealthAlert(a, config);
    alert.overdue = true;
    Datetime cursor = a.schedule.Next_Fire_Window__c != null
      ? a.schedule.Next_Fire_Window__c
      : a.reference;
    alert.key = OVERDUE_PREFIX + a.schedule.Id + ':' + millis(cursor);
    alert.message =
      describe(a.schedule) +
      ' is overdue. Expected window: ' +
      formatGmt(a.schedule.Next_Fire_Window__c) +
      '. Late by ' +
      a.lapsedMinutes +
      ' min. Grace: ' +
      graceMinutes +
      ' min (one sweep interval). Schedule Id: ' +
      a.schedule.Id +
      '.';
    return alert;
  }

  /**
   * @description Builds a failed-fire alert. Key: schedule Id + outcome +
   * last window. Each new failed window gives a new key.
   * @param a The assessment. a.lastFireFailed must be true.
   * @param config The resolved alert config.
   * @return The alert.
   */
  public static ScheduleHealthAlert forFailed(
    ScheduleHealth.Assessment a,
    Workflow_Alert_Config__mdt config
  ) {
    ScheduleHealthAlert alert = new ScheduleHealthAlert(a, config);
    alert.overdue = false;
    alert.key =
      FAILED_PREFIX +
      a.schedule.Id +
      ':' +
      a.schedule.Last_Outcome__c +
      ':' +
      millis(a.schedule.Last_Fired_Window__c);
    alert.message =
      describe(a.schedule) +
      ' last fire failed. Last outcome: ' +
      a.schedule.Last_Outcome__c +
      '. Last window: ' +
      formatGmt(a.schedule.Last_Fired_Window__c) +
      '. Schedule Id: ' +
      a.schedule.Id +
      '.';
    return alert;
  }

  /**
   * @description Records that a channel sent the alert.
   */
  public void markSent() {
    sent = true;
  }

  /**
   * @description Records that a channel sent each alert.
   * @param alerts The sent alerts.
   */
  public static void markAllSent(List<ScheduleHealthAlert> alerts) {
    for (ScheduleHealthAlert alert : alerts) {
      alert.markSent();
    }
  }

  /**
   * @description Groups the alerts that have email recipients by the raw
   * recipient list, so each list gets one email.
   * @param alerts The alerts.
   * @return Alerts by recipient list.
   */
  public static Map<String, List<ScheduleHealthAlert>> groupByRecipients(
    List<ScheduleHealthAlert> alerts
  ) {
    Map<String, List<ScheduleHealthAlert>> result = new Map<String, List<ScheduleHealthAlert>>();
    for (ScheduleHealthAlert alert : alerts) {
      String recipients = alert.config.Email_Recipients__c;
      if (String.isBlank(recipients)) {
        continue;
      }
      if (!result.containsKey(recipients)) {
        result.put(recipients, new List<ScheduleHealthAlert>());
      }
      result.get(recipients).add(alert);
    }
    return result;
  }

  /**
   * @description Builds the claim row and keeps it on this alert.
   * @return The unsaved Workflow_Log__c claim row.
   */
  public Workflow_Log__c toClaim() {
    Workflow_Schedule__c sched = assessment.schedule;
    claim = new Workflow_Log__c(
      Fire_Key__c = key,
      Log_Type__c = LOG_TYPE,
      Level__c = 'Error',
      Outcome__c = overdue ? OUTCOME_OVERDUE : OUTCOME_FAILED,
      Schedule__c = sched.Id,
      Schedule_Name__c = sched.Name,
      Workflow_Name__c = sched.Workflow_Name__c,
      Correlation_Key__c = WorkflowScheduleSweeper.effectivePrefix(sched),
      Fire_Time__c = overdue
        ? sched.Next_Fire_Window__c
        : sched.Last_Fired_Window__c,
      Message__c = message
    );
    return claim;
  }

  /**
   * @description Builds the Workflow_Alert__e event.
   * @return The unpublished event.
   */
  public Workflow_Alert__e toEvent() {
    Workflow_Schedule__c sched = assessment.schedule;
    return new Workflow_Alert__e(
      Workflow_Name__c = sched.Workflow_Name__c,
      Correlation_Key__c = WorkflowScheduleSweeper.effectivePrefix(sched),
      Alert_Reason__c = overdue ? REASON_OVERDUE : REASON_FAILED,
      Error_Message__c = message
    );
  }

  /**
   * @description Builds one email with one list item for each alert.
   * Returns null when no recipient is valid, the list is empty or the build
   * fails.
   * @param recipients The raw recipient address list.
   * @param alerts The alerts to put in the email.
   * @return The email, or null.
   */
  public static Messaging.SingleEmailMessage buildEmail(
    String recipients,
    List<ScheduleHealthAlert> alerts
  ) {
    try {
      List<String> toAddresses = WorkflowAlertEmailBuilder.parseRecipients(
        recipients
      );
      if (toAddresses.isEmpty() || alerts == null || alerts.isEmpty()) {
        return null;
      }
      String items = '';
      for (ScheduleHealthAlert alert : alerts) {
        items +=
          '<li style="margin-bottom: 8px;">' +
          alert.message.escapeHtml4() +
          '</li>';
      }
      String htmlBody =
        '<div style="font-family: sans-serif; padding: 20px; border: 1px solid #e2e8f0; border-radius: 8px; max-width: 600px;">' +
        '<h2 style="color: #e53e3e; margin-top: 0;">Schedule Health</h2>' +
        '<ul>' +
        items +
        '</ul>' +
        '<p style="font-size: 14px; color: #718096; margin-bottom: 0;">Open System Doctor or the Workflow Schedule Manager to examine the schedules.</p>' +
        '</div>';
      Messaging.SingleEmailMessage mail = new Messaging.SingleEmailMessage();
      mail.setToAddresses(toAddresses);
      mail.setSubject(
        '[Revenant Alert] Schedule Health: ' + alerts.size() + ' problem(s)'
      );
      mail.setHtmlBody(htmlBody);
      WorkflowAlertManager.lastHtmlBody = htmlBody;
      return mail;
    } catch (Exception ex) {
      return null;
    }
  }

  private static String describe(Workflow_Schedule__c sched) {
    return 'Schedule "' + sched.Name + '" (' + sched.Workflow_Name__c + ')';
  }

  private static String millis(Datetime value) {
    return value == null ? '0' : String.valueOf(value.getTime());
  }

  private static String formatGmt(Datetime value) {
    return value == null
      ? 'none'
      : value.formatGmt('yyyy-MM-dd HH:mm') + ' UTC';
  }
}
