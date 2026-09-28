/**
 * @description Watchdog stall alert (issue #113). Runs outside the watchdog
 * chain (from WorkflowWatchdog.bootstrap()), so a dead watchdog is still
 * found. Sends one alert per stall: a Workflow_Log__c row with a unique
 * Fire_Key__c ("WatchdogStall:<last sweep ms>") claims the stall before the
 * dispatch. Alerts are opt-in through Workflow_Alert_Config__mdt
 * (WatchdogWorkflow, then Default). Best-effort: never throws.
 */
public inherited sharing class WatchdogStallDetector {
  /** @description Log_Type__c of the claim row. */
  public static final String LOG_TYPE = 'WatchdogStallAlert';

  private static final String WATCHDOG_WORKFLOW = 'WatchdogWorkflow';
  private static final String WATCHDOG_KEY = 'SystemWatchdog';
  private static final String KEY_PREFIX = 'WatchdogStall:';
  // Claim insert plus event publish.
  private static final Integer DML_NEEDED = 2;

  @TestVisible
  private static Boolean forceDmlBudgetExhausted = false;

  /**
   * @description Sends one alert when the watchdog is stale and alerts are
   * on. Does nothing when HEALTHY or UNKNOWN, or when this stall has an alert.
   * @return True when this call sent the alert.
   */
  public static Boolean detectAndAlert() {
    try {
      WatchdogLiveness.Snapshot snap = WatchdogLiveness.evaluateNow();
      if (snap.state != WatchdogLiveness.STATE_STALE) {
        return false;
      }
      Workflow_Alert_Config__mdt config = WorkflowFailureAlertEvaluator.getAlertConfig(
        WATCHDOG_WORKFLOW
      );
      if (!WorkflowAlertManager.isAlertActionable(config) || !hasBudget()) {
        return false;
      }
      String message = buildMessage(snap);
      if (!claim(snap, message)) {
        return false;
      }
      dispatch(snap, config, message);
      return true;
    } catch (Exception ignored) {
      return false;
    }
  }

  // Inserts the claim row. A duplicate key means this stall has an alert.
  private static Boolean claim(WatchdogLiveness.Snapshot snap, String message) {
    Workflow_Log__c marker = new Workflow_Log__c(
      Fire_Key__c = KEY_PREFIX + snap.lastSweepAt.getTime(),
      Fire_Time__c = snap.lastSweepAt,
      Log_Type__c = LOG_TYPE,
      Level__c = 'Error',
      Workflow_Name__c = WATCHDOG_WORKFLOW,
      Correlation_Key__c = WATCHDOG_KEY,
      Message__c = message
    );
    return Database.insert(marker, false, AccessLevel.SYSTEM_MODE).isSuccess();
  }

  private static void dispatch(
    WatchdogLiveness.Snapshot snap,
    Workflow_Alert_Config__mdt config,
    String message
  ) {
    if (String.isNotBlank(config.Email_Recipients__c)) {
      sendEmail(
        WorkflowAlertEmailBuilder.buildWatchdogStallEmail(
          config.Email_Recipients__c,
          message
        )
      );
    }
    if (config.Publish_Alert_Event__c) {
      WorkflowAlertManager.publishEvents(
        new List<Workflow_Alert__e>{
          new Workflow_Alert__e(
            Workflow_Name__c = WATCHDOG_WORKFLOW,
            Correlation_Key__c = WATCHDOG_KEY,
            Alert_Reason__c = 'Watchdog Stall',
            Error_Message__c = message,
            Stall_Threshold_Minutes__c = snap.thresholdMinutes
          )
        }
      );
    }
  }

  private static void sendEmail(Messaging.SingleEmailMessage mail) {
    if (
      mail == null ||
      Limits.getEmailInvocations() >= Limits.getLimitEmailInvocations()
    ) {
      return;
    }
    try {
      if (!Test.isRunningTest()) {
        Messaging.sendEmail(
          new List<Messaging.SingleEmailMessage>{ mail },
          false
        );
      }
      WorkflowAlertManager.sentEmailsCount++;
    } catch (Exception ex) {
      WorkflowLog.error(
        'WatchdogStallAlert',
        'Email dispatch failed: ' + ex.getMessage()
      );
    }
  }

  private static String buildMessage(WatchdogLiveness.Snapshot snap) {
    return 'Watchdog heartbeat stalled. Last sweep: ' +
      snap.lastSweepAt.formatGmt('yyyy-MM-dd HH:mm:ss') +
      ' UTC (' +
      snap.elapsedMinutes +
      ' min ago). Stale after ' +
      snap.thresholdMinutes +
      ' min (' +
      WatchdogLiveness.STALE_MULTIPLIER +
      ' x ' +
      snap.cadenceMinutes +
      ' min cadence). Timeouts, sleeps, schedules and deadlines do not run.';
  }

  private static Boolean hasBudget() {
    return !forceDmlBudgetExhausted &&
      Limits.getDmlStatements() + DML_NEEDED <=
      Limits.getLimitDmlStatements() &&
      Limits.getDmlRows() + DML_NEEDED <= Limits.getLimitDmlRows();
  }
}
