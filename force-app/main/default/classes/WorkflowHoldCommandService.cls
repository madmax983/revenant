/**
 * @description Dashboard hold and release actions for one instance (issue
 * #119). Checks the dashboard and operator-action permissions, then calls
 * `WorkflowInstanceHold`. For an expected state, it returns the outcome name
 * and the operator message. Other errors become an AuraHandledException.
 */
public inherited sharing class WorkflowHoldCommandService {
  /**
   * @description Holds one instance at its next step boundary.
   * @param instanceId The instance to hold.
   * @param reason The operator reason, or blank.
   * @return The outcome name ('outcome') and the operator text ('message').
   */
  public static Map<String, String> holdInstance(Id instanceId, String reason) {
    WorkflowDashboardSupport.checkAuthorization();
    WorkflowDashboardSupport.checkOperatorAction();
    try {
      return toMap(WorkflowInstanceHold.hold(instanceId, reason));
    } catch (Exception ex) {
      throw wrap(ex);
    }
  }

  /**
   * @description Releases a held instance.
   * @param instanceId The instance to release.
   * @return The outcome name ('outcome') and the operator text ('message').
   */
  public static Map<String, String> releaseHeldInstance(Id instanceId) {
    WorkflowDashboardSupport.checkAuthorization();
    WorkflowDashboardSupport.checkOperatorAction();
    try {
      return toMap(WorkflowInstanceHold.release(instanceId));
    } catch (Exception ex) {
      throw wrap(ex);
    }
  }

  private static Map<String, String> toMap(
    WorkflowInstanceHold.HoldResult result
  ) {
    return new Map<String, String>{
      'outcome' => result.outcome.name(),
      'message' => result.message
    };
  }

  // setMessage keeps the text readable in the LWC toast.
  private static AuraHandledException wrap(Exception ex) {
    AuraHandledException wrapped = new AuraHandledException(ex.getMessage());
    wrapped.setMessage(ex.getMessage());
    return wrapped;
  }
}
