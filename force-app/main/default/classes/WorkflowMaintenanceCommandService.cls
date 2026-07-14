/**
 * @description Maintenance operator actions for the workflow dashboard: manually
 * bootstrapping the watchdog and pausing / resuming a workflow definition (or org-wide
 * maintenance mode). Extracted from WorkflowDashboardController; preserves the exact
 * authorization ordering and AuraHandledException messages of the original.
 */
public inherited sharing class WorkflowMaintenanceCommandService {
  /**
   * @description Manually bootstraps the watchdog from the dashboard, kicking off a fresh
   * sweep/heartbeat cycle.
   */
  public static void bootstrapWatchdog() {
    WorkflowDashboardSupport.checkAuthorization();
    try {
      WorkflowWatchdog.bootstrap();
    } catch (Exception ex) {
      throw new AuraHandledException(ex.getMessage());
    }
  }

  /**
   * @description Pause a workflow definition (or * for org-wide maintenance mode). After
   * calling this, new starts for the definition are parked (Paused) and the chain handoff
   * gate parks in-flight instances instead of executing the next step.
   * @param workflowName The definition name to pause, or * for org-wide.
   * @param reason The operator-supplied reason recorded on the pause record.
   */
  public static void pauseDef(String workflowName, String reason) {
    WorkflowDashboardSupport.checkAuthorization();
    try {
      WorkflowPauseGate.pauseDefinition(workflowName, reason);
    } catch (Exception ex) {
      throw new AuraHandledException(ex.getMessage());
    }
  }

  /**
   * @description Resume a paused workflow definition (or * for all). All instances
   * currently in Paused status are transitioned back to Running and re-enqueued.
   * @param workflowName The definition name to resume, or * for all.
   */
  public static void resumeDef(String workflowName) {
    WorkflowDashboardSupport.checkAuthorization();
    try {
      WorkflowPauseGate.resumeDefinition(workflowName);
    } catch (Exception ex) {
      throw new AuraHandledException(ex.getMessage());
    }
  }
}
