public inherited sharing class WorkflowAlertManager {
  @TestVisible
  private static Map<String, Workflow_Alert_Config__mdt> mockConfigs = new Map<String, Workflow_Alert_Config__mdt>();

  @TestVisible
  private static Map<String, Workflow_Alert_Config__mdt> configCache = new Map<String, Workflow_Alert_Config__mdt>();

  @TestVisible
  public static Integer sentEmailsCount = 0;

  @TestVisible
  private static Boolean throwTestException = false;

  @TestVisible
  private static String lastHtmlBody = null;

  @TestVisible
  private static List<Workflow_Alert__e> publishedEvents = new List<Workflow_Alert__e>();

  @TestVisible
  private static Boolean forceDmlBudgetExhausted = false;

  // ---------------------------------------------------------------------------
  // Request / value objects (keep parameter lists short and self-documenting).
  // ---------------------------------------------------------------------------

  // Inputs required to build a Workflow_Alert__e platform event.
  public class AlertEventRequest {
    public Workflow_Instance__c instance;
    public Workflow_Alert_Config__mdt config;
    public String errorMsg;
    public String alertReason;
  }

  // Inputs required to build a stall alert email.
  public class StallAlertRequest {
    public Workflow_Instance__c instance;
    public Workflow_Alert_Config__mdt config;
    public Integer idleMinutes;
    public Integer thresholdMinutes;
  }

  // Escaped, display-safe view of a workflow instance's identifying fields.
  private class EscapedInstance {
    public String workflowName;
    public String instanceName;
    public String instanceId;
    public String correlationKey;
    public String status;
  }

  // Mutable accumulator threaded through the stall-detection scan.
  private class StallScan {
    public Datetime now;
    public List<Workflow_Alert_Config__mdt> configs;
    public Set<Id> suspendedWithPendingSteps;
    public List<Messaging.SingleEmailMessage> emails;
    public List<Workflow_Alert__e> events;
    public List<Workflow_Log__c> logs;
  }

  // A single instance that has been confirmed stalled and is due for alerting.
  private class StallHit {
    public Workflow_Instance__c instance;
    public Workflow_Alert_Config__mdt config;
    public Long idleMinutes;
    public Integer threshold;
  }

  // ---------------------------------------------------------------------------
  // Failure alerts
  // ---------------------------------------------------------------------------

  /**
   * Inspects configuration and thresholds, and sends an email alert and/or platform event if needed.
   */
  public static void sendAlert(Workflow_Instance__c instance, String errorMsg) {
    try {
      if (instance == null || String.isBlank(instance.Workflow_Name__c)) {
        return;
      }

      String workflowName = instance.Workflow_Name__c;

      // 1. Resolve config and short-circuit when alerting is not actionable.
      Workflow_Alert_Config__mdt config = getAlertConfig(workflowName);
      if (!isAlertActionable(config)) {
        return;
      }

      // 2. Determine alert reason.
      String alertReason = determineAlertReason(workflowName, config);
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
      dispatchEmail(
        request.instance,
        request.config.Email_Recipients__c,
        request.errorMsg
      );
    }
    if (request.config.Publish_Alert_Event__c) {
      publishEvents(new List<Workflow_Alert__e>{ buildAlertEvent(request) });
    }
  }

  private static Workflow_Alert_Config__mdt getAlertConfig(
    String workflowName
  ) {
    if (configCache.containsKey(workflowName)) {
      return configCache.get(workflowName);
    }

    String devName = workflowName.replaceAll('[^a-zA-Z0-9_]', '_');
    String truncatedDevName = devName.length() > 40
      ? devName.substring(0, 40)
      : devName;

    // Check mock configs first
    if (mockConfigs.containsKey(devName)) {
      return mockConfigs.get(devName);
    }
    if (mockConfigs.containsKey(truncatedDevName)) {
      return mockConfigs.get(truncatedDevName);
    }
    if (mockConfigs.containsKey('Default')) {
      return mockConfigs.get('Default');
    }

    // SOQL-free Custom Metadata Retrieval
    Workflow_Alert_Config__mdt config = Workflow_Alert_Config__mdt.getInstance(
      devName
    );
    if (config == null && truncatedDevName != devName) {
      config = Workflow_Alert_Config__mdt.getInstance(truncatedDevName);
    }
    if (config == null) {
      config = Workflow_Alert_Config__mdt.getInstance('Default');
    }

    configCache.put(workflowName, config);
    return config;
  }

  private static String determineAlertReason(
    String workflowName,
    Workflow_Alert_Config__mdt config
  ) {
    Boolean hasConsecutiveLimit =
      config.Consecutive_Failures_Limit__c != null &&
      config.Consecutive_Failures_Limit__c > 0;
    Boolean hasSlidingWindow =
      config.Failure_Count_Limit__c != null &&
      config.Failure_Count_Limit__c > 0 &&
      config.Time_Window_Minutes__c != null &&
      config.Time_Window_Minutes__c > 0;

    // If no thresholds are configured, default to sending the alert
    if (!hasConsecutiveLimit && !hasSlidingWindow) {
      return 'immediate';
    }
    if (hasConsecutiveLimit && hasConsecutiveFailures(workflowName, config)) {
      return 'consecutive-failure';
    }
    if (hasSlidingWindow && hasSlidingWindowBreach(workflowName, config)) {
      return 'sliding-window';
    }
    return null;
  }

  private static Boolean hasConsecutiveFailures(
    String workflowName,
    Workflow_Alert_Config__mdt config
  ) {
    Integer limitVal = config.Consecutive_Failures_Limit__c.intValue();
    List<Workflow_Instance__c> recent = [
      SELECT Status__c
      FROM Workflow_Instance__c
      WHERE Workflow_Name__c = :workflowName
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC, Id DESC
      LIMIT :limitVal
    ];
    return recent.size() >= limitVal && allTerminalFailed(recent);
  }

  private static Boolean allTerminalFailed(List<Workflow_Instance__c> recent) {
    for (Workflow_Instance__c inst : recent) {
      if (
        inst.Status__c != 'Failed' &&
        inst.Status__c != 'Compensated' &&
        inst.Status__c != 'Cancelled'
      ) {
        return false;
      }
    }
    return true;
  }

  private static Boolean hasSlidingWindowBreach(
    String workflowName,
    Workflow_Alert_Config__mdt config
  ) {
    Integer limitVal = config.Failure_Count_Limit__c.intValue();
    Integer timeWindow = config.Time_Window_Minutes__c.intValue();
    Datetime windowStart = Datetime.now().addMinutes(-timeWindow);

    Integer failCount = [
      SELECT COUNT()
      FROM Workflow_Instance__c
      WHERE
        Workflow_Name__c = :workflowName
        AND (Status__c = 'Failed'
        OR Status__c = 'Compensated'
        OR Status__c = 'Cancelled')
        AND Terminal_At__c >= :windowStart
      WITH SYSTEM_MODE
    ];

    return failCount >= limitVal;
  }

  private static Workflow_Alert__e buildAlertEvent(AlertEventRequest request) {
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

  private static void publishEvents(List<Workflow_Alert__e> events) {
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
  // Email construction
  // ---------------------------------------------------------------------------

  private static void dispatchEmail(
    Workflow_Instance__c instance,
    String recipients,
    String errorMsg
  ) {
    List<String> toAddresses = parseRecipients(recipients);
    if (toAddresses.isEmpty()) {
      return;
    }

    Messaging.SingleEmailMessage mail = new Messaging.SingleEmailMessage();
    mail.setToAddresses(toAddresses);

    String subject =
      '[Revenant Alert] Workflow Failure: ' + instance.Workflow_Name__c;
    mail.setSubject(subject);

    EscapedInstance esc = escapeInstance(instance);
    String escapedErrorMsg = escapeErrorForEmail(errorMsg);

    String htmlBody =
      '<div style="font-family: sans-serif; padding: 20px; border: 1px solid #e2e8f0; border-radius: 8px; max-width: 600px;">' +
      '<h2 style="color: #e53e3e; margin-top: 0;">Workflow Execution Failed</h2>' +
      '<hr style="border: 0; border-top: 1px solid #e2e8f0; margin-bottom: 20px;"/>' +
      '<table style="width: 100%; border-collapse: collapse; margin-bottom: 20px;">' +
      '<tr><td style="padding: 6px 0; font-weight: bold; width: 150px;">Workflow Name:</td><td>' +
      esc.workflowName +
      '</td></tr>' +
      '<tr><td style="padding: 6px 0; font-weight: bold;">Instance ID:</td><td>' +
      esc.instanceName +
      ' (' +
      esc.instanceId +
      ')</td></tr>' +
      '<tr><td style="padding: 6px 0; font-weight: bold;">Correlation Key:</td><td>' +
      esc.correlationKey +
      '</td></tr>' +
      '<tr><td style="padding: 6px 0; font-weight: bold;">Failed Time:</td><td>' +
      Datetime.now().format() +
      '</td></tr>' +
      '</table>' +
      '<div style="background-color: #fff5f5; border: 1px solid #fed7d7; border-radius: 4px; padding: 15px; margin-bottom: 20px; color: #c53030;">' +
      '<strong>Error Details:</strong><br/><pre style="white-space: pre-wrap; font-family: monospace; margin: 5px 0 0 0;">' +
      escapedErrorMsg +
      '</pre>' +
      '</div>' +
      '<p style="font-size: 14px; color: #718096; margin-bottom: 0;">To view and retry this workflow, open the Workflow Dashboard in Salesforce.</p>' +
      '</div>';

    mail.setHtmlBody(htmlBody);
    lastHtmlBody = htmlBody;

    try {
      if (!Test.isRunningTest()) {
        Messaging.sendEmail(new List<Messaging.SingleEmailMessage>{ mail });
      } else if (throwTestException) {
        throw new IllegalArgumentException('Simulated email exception');
      }
    } catch (Exception ignored) {
    }
    sentEmailsCount += 1;
  }

  /**
   * Builds a stall alert email message without sending it.
   */
  public static Messaging.SingleEmailMessage buildStallEmail(
    StallAlertRequest request
  ) {
    try {
      Workflow_Alert_Config__mdt config = request.config;
      if (
        config == null ||
        !config.Enable_Alerts__c ||
        String.isBlank(config.Email_Recipients__c)
      ) {
        return null;
      }

      List<String> toAddresses = parseRecipients(config.Email_Recipients__c);
      if (toAddresses.isEmpty()) {
        return null;
      }

      Workflow_Instance__c instance = request.instance;
      Messaging.SingleEmailMessage mail = new Messaging.SingleEmailMessage();
      mail.setToAddresses(toAddresses);

      String subject =
        '[Revenant Alert] Workflow Stalled: ' + instance.Workflow_Name__c;
      mail.setSubject(subject);

      EscapedInstance esc = escapeInstance(instance);
      Integer idleMinutes = request.idleMinutes;
      Integer thresholdMinutes = request.thresholdMinutes;

      String htmlBody =
        '<div style="font-family: sans-serif; padding: 20px; border: 1px solid #e2e8f0; border-radius: 8px; max-width: 600px;">' +
        '<h2 style="color: #dd6b20; margin-top: 0;">Workflow Execution Stalled</h2>' +
        '<hr style="border: 0; border-top: 1px solid #e2e8f0; margin-bottom: 20px;"/>' +
        '<table style="width: 100%; border-collapse: collapse; margin-bottom: 20px;">' +
        '<tr><td style="padding: 6px 0; font-weight: bold; width: 150px;">Workflow Name:</td><td>' +
        esc.workflowName +
        '</td></tr>' +
        '<tr><td style="padding: 6px 0; font-weight: bold;">Instance ID:</td><td>' +
        esc.instanceName +
        ' (' +
        esc.instanceId +
        ')</td></tr>' +
        '<tr><td style="padding: 6px 0; font-weight: bold;">Correlation Key:</td><td>' +
        esc.correlationKey +
        '</td></tr>' +
        '<tr><td style="padding: 6px 0; font-weight: bold;">Current Status:</td><td>' +
        esc.status +
        '</td></tr>' +
        '<tr><td style="padding: 6px 0; font-weight: bold;">Idle Duration:</td><td>' +
        idleMinutes +
        ' minutes (threshold: ' +
        thresholdMinutes +
        ' minutes)</td></tr>' +
        '</table>' +
        '<div style="background-color: #fffaf0; border: 1px solid #feebc8; border-radius: 4px; padding: 15px; margin-bottom: 20px; color: #c05621;">' +
        '<strong>Stall Details:</strong><br/>' +
        'The workflow has been inactive for ' +
        idleMinutes +
        ' minutes in status ' +
        esc.status +
        '.' +
        '</div>' +
        '<p style="font-size: 14px; color: #718096; margin-bottom: 0;">To view and manage this workflow, open the Workflow Dashboard in Salesforce.</p>' +
        '</div>';

      mail.setHtmlBody(htmlBody);
      lastHtmlBody = htmlBody;

      return mail;
    } catch (Exception ex) {
      return null;
    }
  }

  // Splits, trims and drops blank recipient addresses.
  private static List<String> parseRecipients(String recipients) {
    List<String> toAddresses = new List<String>();
    for (String email : recipients.split('[,;]')) {
      if (String.isNotBlank(email)) {
        toAddresses.add(email.trim());
      }
    }
    return toAddresses;
  }

  // Escapes the instance fields shared by the failure and stall email bodies.
  private static EscapedInstance escapeInstance(Workflow_Instance__c instance) {
    EscapedInstance esc = new EscapedInstance();
    esc.workflowName = String.isBlank(instance.Workflow_Name__c)
      ? ''
      : instance.Workflow_Name__c.escapeHtml4();
    esc.instanceName = String.isBlank(instance.Name)
      ? ''
      : instance.Name.escapeHtml4();
    esc.instanceId = instance.Id == null
      ? ''
      : String.valueOf(instance.Id).escapeHtml4();
    esc.correlationKey = String.isNotBlank(instance.Correlation_Key__c)
      ? instance.Correlation_Key__c.escapeHtml4()
      : 'N/A';
    esc.status = String.isBlank(instance.Status__c)
      ? ''
      : instance.Status__c.escapeHtml4();
    return esc;
  }

  // Truncates (to 5000 chars) and HTML-escapes the failure error message.
  private static String escapeErrorForEmail(String errorMsg) {
    String truncatedErrorMsg = errorMsg;
    if (
      String.isNotBlank(truncatedErrorMsg) && truncatedErrorMsg.length() > 5000
    ) {
      truncatedErrorMsg =
        truncatedErrorMsg.substring(0, 5000) + '... (truncated)';
    }
    return String.isBlank(truncatedErrorMsg)
      ? ''
      : truncatedErrorMsg.escapeHtml4();
  }

  // ---------------------------------------------------------------------------
  // Stall detection
  // ---------------------------------------------------------------------------

  /**
   * Retrieves active alert configurations (both for production query and unit test mock configs).
   */
  @TestVisible
  private static List<Workflow_Alert_Config__mdt> getActiveStallConfigs() {
    List<Workflow_Alert_Config__mdt> activeConfigs = new List<Workflow_Alert_Config__mdt>();
    Map<String, Workflow_Alert_Config__mdt> allConfigs = Test.isRunningTest()
      ? mockConfigs
      : Workflow_Alert_Config__mdt.getAll();

    for (Workflow_Alert_Config__mdt c : allConfigs.values()) {
      if (
        c.Enable_Alerts__c &&
        c.Stall_Threshold_Minutes__c != null &&
        c.Stall_Threshold_Minutes__c > 0
      ) {
        activeConfigs.add(c);
      }
    }
    return activeConfigs;
  }

  /**
   * Performs case-insensitive and name-truncation (40-char limit) lookup matching for workflow configurations.
   */
  @TestVisible
  private static Workflow_Alert_Config__mdt resolveStallConfig(
    String workflowName,
    List<Workflow_Alert_Config__mdt> activeConfigs
  ) {
    if (String.isBlank(workflowName)) {
      return null;
    }
    String devName = workflowName.replaceAll('[^a-zA-Z0-9_]', '_')
      .toLowerCase();
    String truncatedDevName = devName.length() > 40
      ? devName.substring(0, 40)
      : devName;

    Workflow_Alert_Config__mdt defaultConfig = null;

    for (Workflow_Alert_Config__mdt config : activeConfigs) {
      if (String.isBlank(config.DeveloperName)) {
        continue;
      }
      String configKey = config.DeveloperName.toLowerCase();
      if (configKey == devName) {
        return config;
      }
      if (configKey == truncatedDevName) {
        return config; // Store first match, but exact match takes precedence
      }
      if (config.DeveloperName.equalsIgnoreCase('Default')) {
        defaultConfig = config;
      }
    }
    return defaultConfig;
  }

  /**
   * Proactively identifies stuck workflows in non-terminal states and triggers alerts.
   */
  public static void detectAndAlertStalls() {
    Datetime now = System.now();

    // 1. Get active configs
    List<Workflow_Alert_Config__mdt> configs = getActiveStallConfigs();
    if (configs.isEmpty()) {
      return;
    }

    // 2. Query candidates using parent-child subqueries.
    List<Workflow_Instance__c> candidates = queryStallCandidates(now);
    if (candidates.isEmpty()) {
      return;
    }

    // 3. Scan candidates, accumulating emails / events / log markers.
    StallScan scan = new StallScan();
    scan.now = now;
    scan.configs = configs;
    scan.suspendedWithPendingSteps = suspendedWithPendingSteps(candidates);
    scan.emails = new List<Messaging.SingleEmailMessage>();
    scan.events = new List<Workflow_Alert__e>();
    scan.logs = new List<Workflow_Log__c>();

    for (Workflow_Instance__c inst : candidates) {
      processStallCandidate(inst, scan);
    }

    // 4. Bulk dispatch and DML logs.
    dispatchStallAlerts(scan);
  }

  // Queries non-terminal instances that may have stalled, eliminating the 50k
  // SOQL-row-processed limit risk via parent-child subqueries.
  private static List<Workflow_Instance__c> queryStallCandidates(Datetime now) {
    return [
      SELECT
        Id,
        Name,
        Workflow_Name__c,
        Status__c,
        Sleep_Until__c,
        CreatedDate,
        Correlation_Key__c,
        (
          SELECT CreatedDate
          FROM Workflow_Step_Executions__r
          ORDER BY CreatedDate DESC
          LIMIT 1
        ),
        (
          SELECT CreatedDate
          FROM Workflow_Logs__r
          WHERE Log_Type__c = 'WorkflowStallAlert'
          ORDER BY CreatedDate DESC
          LIMIT 1
        )
      FROM Workflow_Instance__c
      WHERE
        Status__c IN (
          'Pending',
          'Running',
          'Suspended',
          'Compensating',
          'Cancelling'
        )
        AND Workflow_Name__c NOT IN ('WatchdogWorkflow', 'CleanupWorkflow')
        AND (Status__c != 'Suspended'
        OR Sleep_Until__c = NULL
        OR Sleep_Until__c <= :now)
      WITH SYSTEM_MODE
      ORDER BY CreatedDate ASC
      LIMIT 1000
    ];
  }

  // Suspended instances that have a Pending step (waiting on approval/signal).
  private static Set<Id> suspendedWithPendingSteps(
    List<Workflow_Instance__c> candidates
  ) {
    Set<Id> suspendedIds = new Set<Id>();
    for (Workflow_Instance__c inst : candidates) {
      if (inst.Status__c == 'Suspended') {
        suspendedIds.add(inst.Id);
      }
    }

    Set<Id> result = new Set<Id>();
    if (suspendedIds.isEmpty()) {
      return result;
    }
    for (Workflow_Step_Execution__c step : [
      SELECT Workflow_Instance__c
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c IN :suspendedIds AND Status__c = 'Pending'
      WITH SYSTEM_MODE
    ]) {
      result.add(step.Workflow_Instance__c);
    }
    return result;
  }

  // Evaluates one candidate and appends any due alert artefacts to the scan.
  private static void processStallCandidate(
    Workflow_Instance__c inst,
    StallScan scan
  ) {
    if (shouldSkipCandidate(inst, scan.suspendedWithPendingSteps)) {
      return;
    }

    Workflow_Alert_Config__mdt config = resolveStallConfig(
      inst.Workflow_Name__c,
      scan.configs
    );
    if (!hasStallThreshold(config)) {
      return;
    }
    Integer threshold = config.Stall_Threshold_Minutes__c.intValue();

    Datetime lastProgress = lastProgressTime(inst);
    Datetime lastAlert = lastAlertTime(inst);

    Long diffMs = scan.now.getTime() - lastProgress.getTime();
    Long diffMinutes = diffMs / (1000 * 60);
    if (diffMinutes < threshold) {
      return;
    }

    // Suppress if an alert was already logged since the last progress.
    if (lastAlert != null && lastAlert >= lastProgress) {
      return;
    }

    StallHit hit = new StallHit();
    hit.instance = inst;
    hit.config = config;
    hit.idleMinutes = diffMinutes;
    hit.threshold = threshold;
    appendStallAlert(hit, scan);
  }

  // Skip paused definitions, in-transaction resumes and suspended-awaiting steps.
  private static Boolean shouldSkipCandidate(
    Workflow_Instance__c inst,
    Set<Id> suspendedWithPendingSteps
  ) {
    if (WorkflowPauseGate.isDefinitionPaused(inst.Workflow_Name__c)) {
      return true;
    }
    if (WorkflowEngine.resumedInstanceIds.contains(inst.Id)) {
      return true;
    }
    return inst.Status__c == 'Suspended' &&
      suspendedWithPendingSteps.contains(inst.Id);
  }

  private static Boolean hasStallThreshold(Workflow_Alert_Config__mdt config) {
    return config != null &&
      config.Enable_Alerts__c &&
      config.Stall_Threshold_Minutes__c != null &&
      config.Stall_Threshold_Minutes__c > 0;
  }

  // Most recent step-execution time, falling back to the instance creation time.
  private static Datetime lastProgressTime(Workflow_Instance__c inst) {
    if (
      inst.Workflow_Step_Executions__r != null &&
      !inst.Workflow_Step_Executions__r.isEmpty()
    ) {
      return inst.Workflow_Step_Executions__r[0].CreatedDate;
    }
    return inst.CreatedDate;
  }

  // Most recent stall-alert log time, or null when none has been recorded.
  private static Datetime lastAlertTime(Workflow_Instance__c inst) {
    if (inst.Workflow_Logs__r != null && !inst.Workflow_Logs__r.isEmpty()) {
      return inst.Workflow_Logs__r[0].CreatedDate;
    }
    return null;
  }

  // Builds the email / event / log marker for a confirmed stall.
  private static void appendStallAlert(StallHit hit, StallScan scan) {
    Workflow_Instance__c inst = hit.instance;
    Workflow_Alert_Config__mdt config = hit.config;
    String message =
      'Workflow stall detected (idle for ' +
      hit.idleMinutes +
      ' minutes)';

    // Build alert email if recipients configured
    if (String.isNotBlank(config.Email_Recipients__c)) {
      StallAlertRequest request = new StallAlertRequest();
      request.instance = inst;
      request.config = config;
      request.idleMinutes = hit.idleMinutes.intValue();
      request.thresholdMinutes = hit.threshold;
      Messaging.SingleEmailMessage mail = buildStallEmail(request);
      if (mail != null) {
        scan.emails.add(mail);
      }
    }

    // Build event if enabled
    if (config.Publish_Alert_Event__c) {
      AlertEventRequest eventRequest = new AlertEventRequest();
      eventRequest.instance = inst;
      eventRequest.config = config;
      eventRequest.errorMsg = message;
      eventRequest.alertReason = 'stall';
      scan.events.add(buildAlertEvent(eventRequest));
    }

    // Build log marker
    scan.logs.add(
      new Workflow_Log__c(
        Workflow_Instance__c = inst.Id,
        Workflow_Name__c = inst.Workflow_Name__c,
        Correlation_Key__c = inst.Correlation_Key__c,
        Log_Type__c = 'WorkflowStallAlert',
        Level__c = 'Warn',
        Message__c = message
      )
    );
  }

  // Sends gathered stall emails, publishes events and inserts the log markers.
  private static void dispatchStallAlerts(StallScan scan) {
    if (!scan.emails.isEmpty()) {
      try {
        if (!Test.isRunningTest()) {
          Messaging.sendEmail(scan.emails, false);
        }
      } catch (Exception ex) {
        WorkflowLog.error(
          'StallAlert',
          'Bulk stall email dispatch failed: ' + ex.getMessage()
        );
      }
      sentEmailsCount += scan.emails.size();
    }

    // Publish all gathered event alerts in bulk
    publishEvents(scan.events);

    if (!scan.logs.isEmpty()) {
      insert as system scan.logs;
    }
  }
}
