/**
 * @description Resolves the alert configurations used by stall detection: gathering the
 * active configs that have stall detection enabled and matching a workflow name to its
 * applicable config. Extracted from WorkflowStallDetector to keep the scanner focused on
 * candidate evaluation and dispatch.
 */
public inherited sharing class WorkflowStallConfigResolver {
  /**
   * @description Retrieves alert configurations that have stall detection enabled, sourcing
   * from injected mock configs under test and the custom metadata otherwise.
   * @return The active configs that have a positive stall threshold.
   */
  @TestVisible
  public static List<Workflow_Alert_Config__mdt> getActiveStallConfigs() {
    List<Workflow_Alert_Config__mdt> activeConfigs = new List<Workflow_Alert_Config__mdt>();
    Map<String, Workflow_Alert_Config__mdt> allConfigs = Test.isRunningTest()
      ? WorkflowAlertManager.mockConfigs
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
   * @description Resolves the stall config for a workflow using case-insensitive matching
   * against the sanitized developer name, its 40-character truncation, and a Default
   * fallback.
   * @param workflowName The workflow name to resolve a config for.
   * @param activeConfigs The candidate active stall configs to match against.
   * @return The matching config, the Default config, or null when none applies.
   */
  @TestVisible
  public static Workflow_Alert_Config__mdt resolveStallConfig(
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
}
