/**
 * @description Resolves the alert config for stall detection (issue #139).
 * It uses the failure-alert rule: the record for the workflow DeveloperName
 * wins, else Default. A matched record that disables stall alerts also
 * blocks Default. Uses no SOQL.
 */
public inherited sharing class WorkflowStallConfigResolver {
  /**
   * @description Gets all alert configs. Tests use the mock configs.
   * @return All Workflow_Alert_Config__mdt records.
   */
  @TestVisible
  public static List<Workflow_Alert_Config__mdt> getAllConfigs() {
    Map<String, Workflow_Alert_Config__mdt> allConfigs = Test.isRunningTest()
      ? WorkflowAlertManager.mockConfigs
      : Workflow_Alert_Config__mdt.getAll();
    return allConfigs.values();
  }

  /**
   * @description Gets the smallest threshold of the configs that enable
   * stall alerts.
   * @param configs The configs to read.
   * @return The smallest threshold in minutes, or null when no config
   * enables stall alerts.
   */
  public static Integer minStallThreshold(
    List<Workflow_Alert_Config__mdt> configs
  ) {
    Integer result = null;
    for (Workflow_Alert_Config__mdt config : configs) {
      if (isStallEnabled(config)) {
        Integer threshold = config.Stall_Threshold_Minutes__c.intValue();
        result = result == null ? threshold : Math.min(result, threshold);
      }
    }
    return result;
  }

  /**
   * @description Tells if a config enables stall alerts: Enable_Alerts__c
   * is true and the threshold is more than 0.
   * @param config The resolved config, or null.
   * @return True when the config enables stall alerts.
   */
  public static Boolean isStallEnabled(Workflow_Alert_Config__mdt config) {
    return config != null &&
      config.Enable_Alerts__c == true &&
      config.Stall_Threshold_Minutes__c != null &&
      config.Stall_Threshold_Minutes__c.intValue() > 0;
  }

  /**
   * @description Resolves the config for a workflow. It compares the
   * sanitized name and its 40-character cut without case, else it uses
   * Default. It does not skip a disabled match.
   * @param workflowName The workflow name.
   * @param configs All configs.
   * @return The matched config, the Default config, or null.
   */
  @TestVisible
  public static Workflow_Alert_Config__mdt resolveStallConfig(
    String workflowName,
    List<Workflow_Alert_Config__mdt> configs
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
    for (Workflow_Alert_Config__mdt config : configs) {
      if (String.isBlank(config.DeveloperName)) {
        continue;
      }
      String configKey = config.DeveloperName.toLowerCase();
      // A DeveloperName has at most 40 characters, so only one key can match.
      if (configKey == devName || configKey == truncatedDevName) {
        return config;
      }
      if (configKey == 'default') {
        defaultConfig = config;
      }
    }
    return defaultConfig;
  }
}
