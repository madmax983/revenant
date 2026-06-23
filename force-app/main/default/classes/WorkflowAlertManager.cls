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

  /**
   * Inspects configuration and thresholds, and sends an email alert if needed.
   */
  public static void sendAlert(Workflow_Instance__c instance, String errorMsg) {
    try {
      String workflowName = instance.Workflow_Name__c;
      if (String.isBlank(workflowName)) {
        return;
      }

      // 1. Resolve Config
      Workflow_Alert_Config__mdt config = getAlertConfig(workflowName);
      if (
        config == null ||
        !config.Enable_Alerts__c ||
        String.isBlank(config.Email_Recipients__c)
      ) {
        return;
      }

      // 2. Evaluate Thresholds
      Boolean isThresholdMet = evaluateThresholds(workflowName, config);
      if (!isThresholdMet) {
        return;
      }

      // 3. Dispatch Alert
      dispatchEmail(instance, config.Email_Recipients__c, errorMsg);
    } catch (Exception ex) {
      System.debug(
        LoggingLevel.ERROR,
        'Alert dispatch failed: ' +
          ex.getMessage() +
          '\n' +
          ex.getStackTraceString()
      );
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

    // Query specific config
    List<Workflow_Alert_Config__mdt> configs = [
      SELECT
        Email_Recipients__c,
        Enable_Alerts__c,
        Consecutive_Failures_Limit__c,
        Failure_Count_Limit__c,
        Time_Window_Minutes__c,
        Stall_Threshold_Minutes__c
      FROM Workflow_Alert_Config__mdt
      WHERE DeveloperName = :devName OR DeveloperName = :truncatedDevName
      WITH SYSTEM_MODE
    ];
    if (!configs.isEmpty()) {
      configCache.put(workflowName, configs[0]);
      return configs[0];
    }

    // Fallback to Default
    configs = [
      SELECT
        Email_Recipients__c,
        Enable_Alerts__c,
        Consecutive_Failures_Limit__c,
        Failure_Count_Limit__c,
        Time_Window_Minutes__c,
        Stall_Threshold_Minutes__c
      FROM Workflow_Alert_Config__mdt
      WHERE DeveloperName = 'Default'
      WITH SYSTEM_MODE
    ];
    if (!configs.isEmpty()) {
      configCache.put(workflowName, configs[0]);
      return configs[0];
    }

    configCache.put(workflowName, null);
    return null;
  }

  private static Boolean evaluateThresholds(
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
      return true;
    }

    // Check Consecutive Failures
    if (hasConsecutiveLimit) {
      Integer limitVal = config.Consecutive_Failures_Limit__c.intValue();
      List<Workflow_Instance__c> recent = [
        SELECT Status__c
        FROM Workflow_Instance__c
        WHERE Workflow_Name__c = :workflowName
        WITH SYSTEM_MODE
        ORDER BY CreatedDate DESC, Id DESC
        LIMIT :limitVal
      ];
      if (recent.size() >= limitVal) {
        Boolean allFailed = true;
        for (Workflow_Instance__c inst : recent) {
          if (
            inst.Status__c != 'Failed' &&
            inst.Status__c != 'Compensated' &&
            inst.Status__c != 'Cancelled'
          ) {
            allFailed = false;
            break;
          }
        }
        if (allFailed) {
          return true;
        }
      }
    }

    // Check Sliding Window Count
    if (hasSlidingWindow) {
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

      if (failCount >= limitVal) {
        return true;
      }
    }

    return false;
  }

  private static void dispatchEmail(
    Workflow_Instance__c instance,
    String recipients,
    String errorMsg
  ) {
    List<String> toAddresses = new List<String>();
    for (String email : recipients.split('[,;]')) {
      if (String.isNotBlank(email)) {
        toAddresses.add(email.trim());
      }
    }
    if (toAddresses.isEmpty()) {
      return;
    }

    Messaging.SingleEmailMessage mail = new Messaging.SingleEmailMessage();
    mail.setToAddresses(toAddresses);

    String subject =
      '[Revenant Alert] Workflow Failure: ' + instance.Workflow_Name__c;
    mail.setSubject(subject);

    String escWorkflowName = String.isBlank(instance.Workflow_Name__c)
      ? ''
      : instance.Workflow_Name__c.escapeHtml4();
    String escInstanceName = String.isBlank(instance.Name)
      ? ''
      : instance.Name.escapeHtml4();
    String escInstanceId = instance.Id == null
      ? ''
      : String.valueOf(instance.Id).escapeHtml4();
    String escCorrelationKey = String.isNotBlank(instance.Correlation_Key__c)
      ? instance.Correlation_Key__c.escapeHtml4()
      : 'N/A';

    String truncatedErrorMsg = errorMsg;
    if (
      String.isNotBlank(truncatedErrorMsg) && truncatedErrorMsg.length() > 5000
    ) {
      truncatedErrorMsg =
        truncatedErrorMsg.substring(0, 5000) + '... (truncated)';
    }
    String escapedErrorMsg = String.isBlank(truncatedErrorMsg)
      ? ''
      : truncatedErrorMsg.escapeHtml4();

    String htmlBody =
      '<div style="font-family: sans-serif; padding: 20px; border: 1px solid #e2e8f0; border-radius: 8px; max-width: 600px;">' +
      '<h2 style="color: #e53e3e; margin-top: 0;">Workflow Execution Failed</h2>' +
      '<hr style="border: 0; border-top: 1px solid #e2e8f0; margin-bottom: 20px;"/>' +
      '<table style="width: 100%; border-collapse: collapse; margin-bottom: 20px;">' +
      '<tr><td style="padding: 6px 0; font-weight: bold; width: 150px;">Workflow Name:</td><td>' +
      escWorkflowName +
      '</td></tr>' +
      '<tr><td style="padding: 6px 0; font-weight: bold;">Instance ID:</td><td>' +
      escInstanceName +
      ' (' +
      escInstanceId +
      ')</td></tr>' +
      '<tr><td style="padding: 6px 0; font-weight: bold;">Correlation Key:</td><td>' +
      escCorrelationKey +
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
    } catch (Exception e) {
      System.debug(
        LoggingLevel.ERROR,
        'Email dispatch failed: ' + e.getMessage()
      );
    }
    sentEmailsCount += 1;
  }

  /**
   * Builds a stall alert email message without sending it.
   */
  public static Messaging.SingleEmailMessage buildStallEmail(
    Workflow_Instance__c instance,
    Workflow_Alert_Config__mdt config,
    Integer idleMinutes,
    Integer thresholdMinutes
  ) {
    try {
      if (
        config == null ||
        !config.Enable_Alerts__c ||
        String.isBlank(config.Email_Recipients__c)
      ) {
        return null;
      }

      List<String> toAddresses = new List<String>();
      for (String email : config.Email_Recipients__c.split('[,;]')) {
        if (String.isNotBlank(email)) {
          toAddresses.add(email.trim());
        }
      }
      if (toAddresses.isEmpty()) {
        return null;
      }

      Messaging.SingleEmailMessage mail = new Messaging.SingleEmailMessage();
      mail.setToAddresses(toAddresses);

      String subject =
        '[Revenant Alert] Workflow Stalled: ' + instance.Workflow_Name__c;
      mail.setSubject(subject);

      String escWorkflowName = String.isBlank(instance.Workflow_Name__c)
        ? ''
        : instance.Workflow_Name__c.escapeHtml4();
      String escInstanceName = String.isBlank(instance.Name)
        ? ''
        : instance.Name.escapeHtml4();
      String escInstanceId = instance.Id == null
        ? ''
        : String.valueOf(instance.Id).escapeHtml4();
      String escCorrelationKey = String.isNotBlank(instance.Correlation_Key__c)
        ? instance.Correlation_Key__c.escapeHtml4()
        : 'N/A';
      String escStatus = String.isBlank(instance.Status__c)
        ? ''
        : instance.Status__c.escapeHtml4();

      String htmlBody =
        '<div style="font-family: sans-serif; padding: 20px; border: 1px solid #e2e8f0; border-radius: 8px; max-width: 600px;">' +
        '<h2 style="color: #dd6b20; margin-top: 0;">Workflow Execution Stalled</h2>' +
        '<hr style="border: 0; border-top: 1px solid #e2e8f0; margin-bottom: 20px;"/>' +
        '<table style="width: 100%; border-collapse: collapse; margin-bottom: 20px;">' +
        '<tr><td style="padding: 6px 0; font-weight: bold; width: 150px;">Workflow Name:</td><td>' +
        escWorkflowName +
        '</td></tr>' +
        '<tr><td style="padding: 6px 0; font-weight: bold;">Instance ID:</td><td>' +
        escInstanceName +
        ' (' +
        escInstanceId +
        ')</td></tr>' +
        '<tr><td style="padding: 6px 0; font-weight: bold;">Correlation Key:</td><td>' +
        escCorrelationKey +
        '</td></tr>' +
        '<tr><td style="padding: 6px 0; font-weight: bold;">Current Status:</td><td>' +
        escStatus +
        '</td></tr>' +
        '<tr><td style="padding: 6px 0; font-weight: bold;">Idle Duration:</td><td>' +
        idleMinutes +
        ' minutes (threshold: ' +
        thresholdMinutes +
        ' minutes)</td></tr>' +
        '</table>' +
        '<div style="background-color: #fffaf0; border: 1px solid #feebc8; border-radius: 4px; padding: 15px; margin-bottom: 20px; color: #c05621;">' +
        '<strong>Stall Details:</strong><br/>' +
        'The workflow has been inactive for ' + idleMinutes + ' minutes in status ' + escStatus + '.' +
        '</div>' +
        '<p style="font-size: 14px; color: #718096; margin-bottom: 0;">To view and manage this workflow, open the Workflow Dashboard in Salesforce.</p>' +
        '</div>';

      mail.setHtmlBody(htmlBody);
      lastHtmlBody = htmlBody;

      return mail;
    } catch (Exception ex) {
      System.debug(
        LoggingLevel.ERROR,
        'Failed to build stall email: ' + ex.getMessage()
      );
      return null;
    }
  }

  /**
   * Retrieves active alert configurations (both for production query and unit test mock configs).
   */
  @TestVisible
  private static List<Workflow_Alert_Config__mdt> getActiveStallConfigs() {
    if (Test.isRunningTest()) {
      List<Workflow_Alert_Config__mdt> activeMock = new List<Workflow_Alert_Config__mdt>();
      for (Workflow_Alert_Config__mdt c : mockConfigs.values()) {
        if (c.Enable_Alerts__c && c.Stall_Threshold_Minutes__c != null && c.Stall_Threshold_Minutes__c > 0) {
          activeMock.add(c);
        }
      }
      return activeMock;
    }
    return [
      SELECT DeveloperName, Stall_Threshold_Minutes__c, Email_Recipients__c, Enable_Alerts__c
      FROM Workflow_Alert_Config__mdt
      WHERE Enable_Alerts__c = true AND Stall_Threshold_Minutes__c != null AND Stall_Threshold_Minutes__c > 0
      WITH SYSTEM_MODE
    ];
  }

  /**
   * Performs case-insensitive and name-truncation (40-char limit) lookup matching for workflow configurations.
   */
  @TestVisible
  private static Workflow_Alert_Config__mdt resolveStallConfig(String workflowName, List<Workflow_Alert_Config__mdt> activeConfigs) {
    if (String.isBlank(workflowName)) {
      return null;
    }
    String devName = workflowName.replaceAll('[^a-zA-Z0-9_]', '_').toLowerCase();
    String truncatedDevName = devName.length() > 40 ? devName.substring(0, 40) : devName;

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
      if (config.DeveloperName == 'Default') {
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

    // 2. Query candidates using parent-child subqueries (eliminates 50k SOQL row processed limit risk)
    List<Workflow_Instance__c> candidates = [
      SELECT Id, Name, Workflow_Name__c, Status__c, Sleep_Until__c, CreatedDate, Correlation_Key__c,
        (SELECT CreatedDate FROM Workflow_Step_Executions__r ORDER BY CreatedDate DESC LIMIT 1),
        (SELECT CreatedDate FROM Workflow_Logs__r WHERE Log_Type__c = 'WorkflowStallAlert' ORDER BY CreatedDate DESC LIMIT 1)
      FROM Workflow_Instance__c
      WHERE Status__c IN ('Pending', 'Running', 'Suspended', 'Compensating', 'Cancelling')
        AND Workflow_Name__c NOT IN ('WatchdogWorkflow', 'CleanupWorkflow')
        AND (Status__c != 'Suspended' OR Sleep_Until__c = null OR Sleep_Until__c <= :now)
      WITH SYSTEM_MODE
      ORDER BY CreatedDate ASC
      LIMIT 1000
    ];

    if (candidates.isEmpty()) {
      return;
    }

    // 3. Check suspended instances for pending approval or signal wait steps
    Set<Id> suspendedIds = new Set<Id>();
    for (Workflow_Instance__c inst : candidates) {
      if (inst.Status__c == 'Suspended') {
        suspendedIds.add(inst.Id);
      }
    }

    Set<Id> suspendedWithPendingSteps = new Set<Id>();
    if (!suspendedIds.isEmpty()) {
      for (Workflow_Step_Execution__c step : [
        SELECT Workflow_Instance__c
        FROM Workflow_Step_Execution__c
        WHERE Workflow_Instance__c IN :suspendedIds AND Status__c = 'Pending'
        WITH SYSTEM_MODE
      ]) {
        suspendedWithPendingSteps.add(step.Workflow_Instance__c);
      }
    }

    List<Messaging.SingleEmailMessage> emailsToSend = new List<Messaging.SingleEmailMessage>();
    List<Workflow_Log__c> alertsToInsert = new List<Workflow_Log__c>();

    // 4. Process each candidate
    for (Workflow_Instance__c inst : candidates) {
      // Skip paused definitions
      if (WorkflowPauseGate.isDefinitionPaused(inst.Workflow_Name__c)) {
        continue;
      }

      // Skip instances resumed in the current transaction to prevent false-positives
      if (WorkflowEngine.resumedInstanceIds.contains(inst.Id)) {
        continue;
      }

      // Skip Suspended instances waiting on external signals or approvals
      if (inst.Status__c == 'Suspended' && suspendedWithPendingSteps.contains(inst.Id)) {
        continue;
      }

      // Resolve config case-insensitively
      Workflow_Alert_Config__mdt config = resolveStallConfig(inst.Workflow_Name__c, configs);
      if (config == null || !config.Enable_Alerts__c || config.Stall_Threshold_Minutes__c == null || config.Stall_Threshold_Minutes__c <= 0) {
        continue;
      }

      Integer threshold = config.Stall_Threshold_Minutes__c.intValue();

      // Compute last progress date
      Datetime lastProgressDateTime = inst.CreatedDate;
      if (inst.Workflow_Step_Executions__r != null && !inst.Workflow_Step_Executions__r.isEmpty()) {
        lastProgressDateTime = inst.Workflow_Step_Executions__r[0].CreatedDate;
      }

      // Compute last alert date
      Datetime lastAlertDateTime = null;
      if (inst.Workflow_Logs__r != null && !inst.Workflow_Logs__r.isEmpty()) {
        lastAlertDateTime = inst.Workflow_Logs__r[0].CreatedDate;
      }

      // Check stall threshold
      Long diffMs = now.getTime() - lastProgressDateTime.getTime();
      Long diffMinutes = diffMs / (1000 * 60);

      if (diffMinutes >= threshold) {
        if (lastAlertDateTime == null || lastAlertDateTime < lastProgressDateTime) {
          // Build alert email
          Messaging.SingleEmailMessage mail = buildStallEmail(
            inst,
            config,
            diffMinutes.intValue(),
            threshold
          );
          if (mail != null) {
            emailsToSend.add(mail);
          }

          // Build log marker
          Workflow_Log__c marker = new Workflow_Log__c(
            Workflow_Instance__c = inst.Id,
            Workflow_Name__c = inst.Workflow_Name__c,
            Correlation_Key__c = inst.Correlation_Key__c,
            Log_Type__c = 'WorkflowStallAlert',
            Level__c = 'Warn',
            Message__c = 'Workflow stall detected (idle for ' + diffMinutes + ' minutes)'
          );
          alertsToInsert.add(marker);
        }
      }
    }

    // 5. Bulk dispatch and DML logs
    if (!emailsToSend.isEmpty()) {
      try {
        if (!Test.isRunningTest()) {
          Messaging.sendEmail(emailsToSend, false);
        }
      } catch (Exception emailEx) {
        System.debug(LoggingLevel.ERROR, 'Bulk stall email dispatch failed: ' + emailEx.getMessage());
      }
      sentEmailsCount += emailsToSend.size();
    }

    if (!alertsToInsert.isEmpty()) {
      insert as system alertsToInsert;
    }
  }
}
