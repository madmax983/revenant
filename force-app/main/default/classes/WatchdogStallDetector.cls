/**
 * @description Sends one alert for each watchdog stall (issue #113).
 * WorkflowWatchdog.bootstrap() and the System Doctor read call it. These
 * calls are not in the watchdog chain, so the detector can find a dead
 * watchdog. A Workflow_Log__c row with a unique Fire_Key__c claims the stall.
 * Alerts need a WatchdogWorkflow or Default Workflow_Alert_Config__mdt.
 * Does not throw.
 */
public inherited sharing class WatchdogStallDetector {
  /** @description Log_Type__c of the claim row. */
  public static final String LOG_TYPE = 'WatchdogStallAlert';

  /** @description Alert_Reason__c of the alert event. */
  public static final String ALERT_REASON = 'Watchdog Stall';

  private static final String WATCHDOG_WORKFLOW = 'WatchdogWorkflow';
  private static final String WATCHDOG_KEY = 'SystemWatchdog';
  private static final String KEY_PREFIX = 'WatchdogStall:';
  // Claim insert, event publish, alert marker, and claim release.
  private static final Integer DML_NEEDED = 4;

  @TestVisible
  private static Boolean forceDmlBudgetExhausted = false;

  /**
   * @description Sends one alert when the watchdog is STALE and alerts are
   * on. When the state is HEALTHY or UNKNOWN, or the stall has its alert, it
   * does no DML. When no channel sends the alert, it releases the claim so a
   * later call can try again.
   * @return True when this call sent the alert.
   */
  public static Boolean detectAndAlert() {
    try {
      WatchdogLiveness.Snapshot snap = WatchdogLiveness.evaluateNow();
      if (snap.state != WatchdogLiveness.STATE_STALE || snap.alertSent) {
        return false;
      }
      Workflow_Alert_Config__mdt config = WorkflowFailureAlertEvaluator.getAlertConfig(
        WATCHDOG_WORKFLOW
      );
      if (!WorkflowAlertManager.isAlertActionable(config) || !hasBudget()) {
        return false;
      }
      String message = buildMessage(snap);
      Messaging.SingleEmailMessage mail = String.isNotBlank(
          config.Email_Recipients__c
        )
        ? WorkflowAlertEmailBuilder.buildWatchdogStallEmail(
            config.Email_Recipients__c,
            message
          )
        : null;
      Boolean useEvent = config.Publish_Alert_Event__c == true;
      if (mail == null && !useEvent) {
        return false;
      }

      Workflow_Log__c claimRow = buildClaim(snap, message);
      if (
        !Database.insert(claimRow, false, AccessLevel.SYSTEM_MODE).isSuccess()
      ) {
        // Another transaction has the claim for this stall.
        return false;
      }
      Boolean sent = mail != null && WorkflowAlertEmailBuilder.sendEmail(mail);
      if (useEvent) {
        sent = publish(snap, message) || sent;
      }
      if (!sent) {
        Database.delete(claimRow, false, AccessLevel.SYSTEM_MODE);
        return false;
      }
      WatchdogLiveness.markAlertSent(snap.lastSweepAt);
      return true;
    } catch (Exception ignored) {
      return false;
    }
  }

  private static Workflow_Log__c buildClaim(
    WatchdogLiveness.Snapshot snap,
    String message
  ) {
    return new Workflow_Log__c(
      Fire_Key__c = KEY_PREFIX + snap.lastSweepAt.getTime(),
      Fire_Time__c = snap.lastSweepAt,
      Log_Type__c = LOG_TYPE,
      Level__c = 'Error',
      Workflow_Name__c = WATCHDOG_WORKFLOW,
      Correlation_Key__c = WATCHDOG_KEY,
      Message__c = message
    );
  }

  private static Boolean publish(
    WatchdogLiveness.Snapshot snap,
    String message
  ) {
    return WorkflowAlertManager.publishEvents(
      new List<Workflow_Alert__e>{
        new Workflow_Alert__e(
          Workflow_Name__c = WATCHDOG_WORKFLOW,
          Correlation_Key__c = WATCHDOG_KEY,
          Alert_Reason__c = ALERT_REASON,
          Error_Message__c = message,
          Stall_Threshold_Minutes__c = snap.thresholdMinutes
        )
      }
    );
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

  // Keeps WatchdogLiveness.DML_RESERVE statements free for the caller.
  private static Boolean hasBudget() {
    Integer needed = DML_NEEDED + WatchdogLiveness.DML_RESERVE;
    return !forceDmlBudgetExhausted &&
      Limits.getDmlStatements() + needed <= Limits.getLimitDmlStatements() &&
      Limits.getDmlRows() + needed <= Limits.getLimitDmlRows();
  }
}
