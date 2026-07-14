/**
 * @description Central alerting service for workflow failures and stalls, resolving
 * per-workflow alert configuration and dispatching notifications over email and the
 * Workflow_Alert__e platform event. All dispatch is best-effort and budget-aware so
 * alerting can never roll back or break the engine's terminal-state writes.
 */
public inherited sharing class WorkflowAlertManager {
  @TestVisible
  public static Map<String, Workflow_Alert_Config__mdt> mockConfigs = new Map<String, Workflow_Alert_Config__mdt>();

  @TestVisible
  public static Integer sentEmailsCount = 0;

  @TestVisible
  public static Boolean throwTestException = false;

  @TestVisible
  public static String lastHtmlBody = null;

  @TestVisible
  private static List<Workflow_Alert__e> publishedEvents = new List<Workflow_Alert__e>();

  @TestVisible
  private static Boolean forceDmlBudgetExhausted = false;

  // ---------------------------------------------------------------------------
  // Request / value objects (keep parameter lists short and self-documenting).
  // ---------------------------------------------------------------------------

  /**
   * @description Inputs required to build a Workflow_Alert__e platform event.
   */
  public class AlertEventRequest {
    public Workflow_Instance__c instance;
    public Workflow_Alert_Config__mdt config;
    public String errorMsg;
    public String alertReason;
  }

  /**
   * @description Inputs required to build a stall alert email.
   */
  public class StallAlertRequest {
    public Workflow_Instance__c instance;
    public Workflow_Alert_Config__mdt config;
    public Integer idleMinutes;
    public Integer thresholdMinutes;
  }

  // ---------------------------------------------------------------------------
  // Failure alerts
  // ---------------------------------------------------------------------------

  /**
   * @description Inspects the workflow's alert configuration and failure thresholds and, when
   * a threshold is breached, dispatches an email alert and/or platform event. Failures are
   * swallowed so alerting never disrupts the caller.
   * @param instance The failed workflow instance to evaluate and alert on.
   * @param errorMsg The error detail to include in the alert.
   */
  public static void sendAlert(Workflow_Instance__c instance, String errorMsg) {
    try {
      if (instance == null || String.isBlank(instance.Workflow_Name__c)) {
        return;
      }

      String workflowName = instance.Workflow_Name__c;

      // 1. Resolve config and short-circuit when alerting is not actionable.
      Workflow_Alert_Config__mdt config = WorkflowFailureAlertEvaluator.getAlertConfig(
        workflowName
      );
      if (!isAlertActionable(config)) {
        return;
      }

      // 2. Determine alert reason.
      String alertReason = WorkflowFailureAlertEvaluator.determineAlertReason(
        workflowName,
        config
      );
      if (alertReason == null) {
        return;
      }

      // 3. Dispatch email and/or platform event.
      AlertEventRequest request = new AlertEventRequest();
      request.instance = instance;
      request.config = config;
      request.errorMsg = errorMsg;
      request.alertReason = alertReason;
      dispatchAlert(request);
    } catch (Exception ignored) {
    }
  }

  // Alerting only proceeds when enabled and at least one channel is configured.
  private static Boolean isAlertActionable(Workflow_Alert_Config__mdt config) {
    if (config == null || !config.Enable_Alerts__c) {
      return false;
    }
    // If email recipients are blank and event publishing is disabled, skip.
    return String.isNotBlank(config.Email_Recipients__c) ||
      config.Publish_Alert_Event__c;
  }

  private static void dispatchAlert(AlertEventRequest request) {
    if (String.isNotBlank(request.config.Email_Recipients__c)) {
      WorkflowAlertEmailBuilder.dispatchEmail(
        request.instance,
        request.config.Email_Recipients__c,
        request.errorMsg
      );
    }
    if (request.config.Publish_Alert_Event__c) {
      publishEvents(new List<Workflow_Alert__e>{ buildAlertEvent(request) });
    }
  }

  /**
   * @description Builds a Workflow_Alert__e platform event from the supplied request,
   * truncating an over-length error message and mapping the internal reason token to its
   * display value.
   * @param request The inputs describing the instance, config, error and reason.
   * @return The populated platform event ready for publishing.
   */
  public static Workflow_Alert__e buildAlertEvent(AlertEventRequest request) {
    Workflow_Instance__c instance = request.instance;
    Workflow_Alert_Config__mdt config = request.config;

    Workflow_Alert__e evt = new Workflow_Alert__e();
    evt.Workflow_Name__c = instance.Workflow_Name__c;
    evt.Workflow_Instance_Id__c = instance.Id;
    evt.Correlation_Key__c = instance.Correlation_Key__c;

    // Truncate error message if it exceeds 20000 characters
    String errorMsg = request.errorMsg;
    if (errorMsg != null && errorMsg.length() > 20000) {
      evt.Error_Message__c = errorMsg.substring(0, 20000);
    } else {
      evt.Error_Message__c = errorMsg;
    }

    evt.Alert_Reason__c = displayReason(request.alertReason);

    evt.Consecutive_Failures_Limit__c = config.Consecutive_Failures_Limit__c;
    evt.Failure_Count_Limit__c = config.Failure_Count_Limit__c;
    evt.Time_Window_Minutes__c = config.Time_Window_Minutes__c;
    evt.Stall_Threshold_Minutes__c = config.Stall_Threshold_Minutes__c;

    return evt;
  }

  // Maps an internal reason token to its final user-facing string.
  private static String displayReason(String alertReason) {
    if (alertReason == 'consecutive-failure') {
      return 'Consecutive Failures';
    }
    if (alertReason == 'sliding-window') {
      return 'Sliding Window';
    }
    if (alertReason == 'immediate') {
      return 'Immediate';
    }
    if (alertReason == 'stall') {
      return 'Stall';
    }
    return alertReason;
  }

  /**
   * @description Publishes the supplied platform events, skipping publication when the DML
   * statement or DML row budget cannot safely absorb the events so alerting never rolls back
   * the engine's terminal-state writes. Publication failures are swallowed.
   * @param events The platform events to publish; null or empty is a no-op.
   */
  public static void publishEvents(List<Workflow_Alert__e> events) {
    if (events == null || events.isEmpty()) {
      return;
    }

    // Never spend the transaction's last DML statement or DML rows here.
    // EventBus.publish consumes a DML statement AND one DML row per event; over
    // budget either throws an uncatchable System.LimitException that would roll
    // back the terminal-state write — defeating the fire-and-forget contract.
    if (
      forceDmlBudgetExhausted ||
      Limits.getDmlStatements() >= Limits.getLimitDmlStatements() ||
      Limits.getDmlRows() + events.size() > Limits.getLimitDmlRows()
    ) {
      return;
    }

    if (Test.isRunningTest()) {
      publishedEvents.addAll(events);
    }
    try {
      EventBus.publish(events);
    } catch (Exception ignored) {
    }
  }

  // ---------------------------------------------------------------------------
  // Email construction (delegated to WorkflowAlertEmailBuilder)
  // ---------------------------------------------------------------------------

  /**
   * @description Builds a stall alert email message without sending it, returning null when
   * alerting is disabled, no recipients are configured, or construction fails. Delegates to
   * WorkflowAlertEmailBuilder.
   * @param request The stall alert inputs (instance, config, idle and threshold minutes).
   * @return A ready-to-send email message, or null when no email should be sent.
   */
  public static Messaging.SingleEmailMessage buildStallEmail(
    StallAlertRequest request
  ) {
    return WorkflowAlertEmailBuilder.buildStallEmail(request);
  }

  // ---------------------------------------------------------------------------
  // Stall detection (delegated to WorkflowStallDetector)
  // ---------------------------------------------------------------------------

  /**
   * @description Proactively identifies stuck workflows in non-terminal states and triggers
   * alerts. Delegates to WorkflowStallDetector.
   */
  public static void detectAndAlertStalls() {
    WorkflowStallDetector.detectAndAlertStalls();
  }
}
