/**
 * @description Resolves per-workflow alert configuration and evaluates the failure
 * thresholds (immediate, consecutive-failure and sliding-window) that decide whether a
 * failure alert is warranted. Extracted from WorkflowAlertManager so the manager stays
 * focused on orchestration and dispatch.
 */
public inherited sharing class WorkflowFailureAlertEvaluator {
  /**
   * @description Per-transaction cache of resolved configs keyed by raw workflow name.
   */
  @TestVisible
  private static Map<String, Workflow_Alert_Config__mdt> configCache = new Map<String, Workflow_Alert_Config__mdt>();

  /**
   * @description Resolves the alert config for a workflow using the sanitized developer name,
   * its 40-character truncation, and a Default fallback, checking injected mock configs
   * first and the custom metadata otherwise. Results are cached per transaction.
   * @param workflowName The workflow name to resolve a config for.
   * @return The matching config, the Default config, or null when none applies.
   */
  public static Workflow_Alert_Config__mdt getAlertConfig(String workflowName) {
    if (configCache.containsKey(workflowName)) {
      return configCache.get(workflowName);
    }

    String devName = workflowName.replaceAll('[^a-zA-Z0-9_]', '_');
    String truncatedDevName = devName.length() > 40
      ? devName.substring(0, 40)
      : devName;

    // Check mock configs first
    if (WorkflowAlertManager.mockConfigs.containsKey(devName)) {
      return WorkflowAlertManager.mockConfigs.get(devName);
    }
    if (WorkflowAlertManager.mockConfigs.containsKey(truncatedDevName)) {
      return WorkflowAlertManager.mockConfigs.get(truncatedDevName);
    }
    if (WorkflowAlertManager.mockConfigs.containsKey('Default')) {
      return WorkflowAlertManager.mockConfigs.get('Default');
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

  /**
   * @description Determines the applicable alert reason for a workflow given its thresholds,
   * returning 'immediate' when no thresholds are configured, a breached-threshold token when
   * a limit is exceeded, or null when configured thresholds are not breached.
   * @param workflowName The workflow name being evaluated.
   * @param config The resolved alert config to evaluate.
   * @return The alert reason token, or null when no alert should fire.
   */
  public static String determineAlertReason(
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

  /**
   * @description Determines whether the most recent instances of a workflow are all terminal
   * failures up to the configured consecutive-failure limit.
   * @param workflowName The workflow name to evaluate.
   * @param config The resolved alert config supplying the consecutive-failure limit.
   * @return True when the consecutive-failure limit is met by terminal failures.
   */
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

  /**
   * @description Determines whether every instance in the list is in a terminal failed state
   * (Failed, Compensated or Cancelled).
   * @param recent The instances to inspect.
   * @return True when all instances are terminally failed.
   */
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

  /**
   * @description Determines whether the number of terminal failures within the configured
   * sliding time window meets the configured failure-count limit.
   * @param workflowName The workflow name to evaluate.
   * @param config The resolved alert config supplying the limit and time window.
   * @return True when the sliding-window failure-count limit is met.
   */
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
}
