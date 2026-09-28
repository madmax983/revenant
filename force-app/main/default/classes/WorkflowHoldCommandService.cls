/**
 * @description Dashboard hold and release actions for one instance (issue
 * #119). Checks the dashboard and operator-action permissions, then calls
 * `WorkflowInstanceHold`. Expected states return the outcome name, not an
 * error. Other errors become an AuraHandledException.
 */
public inherited sharing class WorkflowHoldCommandService {
  /**
   * @description Holds one instance at its next step boundary.
   * @param instanceId The instance to hold.
   * @param reason The operator reason, or blank.
   * @return The WorkflowInstanceHold.Outcome name.
   */
  public static String holdInstance(Id instanceId, String reason) {
    WorkflowDashboardSupport.checkAuthorization();
    WorkflowDashboardSupport.checkOperatorAction();
    try {
      return WorkflowInstanceHold.hold(instanceId, reason).outcome.name();
    } catch (Exception ex) {
      throw wrap(ex);
    }
  }

  /**
   * @description Releases a held instance.
   * @param instanceId The instance to release.
   * @return The WorkflowInstanceHold.Outcome name.
   */
  public static String releaseHeldInstance(Id instanceId) {
    WorkflowDashboardSupport.checkAuthorization();
    WorkflowDashboardSupport.checkOperatorAction();
    try {
      return WorkflowInstanceHold.release(instanceId).outcome.name();
    } catch (Exception ex) {
      throw wrap(ex);
    }
  }

  // setMessage keeps the text readable in the LWC toast.
  private static AuraHandledException wrap(Exception ex) {
    AuraHandledException wrapped = new AuraHandledException(ex.getMessage());
    wrapped.setMessage(ex.getMessage());
    return wrapped;
  }
}
