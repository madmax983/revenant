/**
 * @description Records an operator approval decision from the dashboard by delivering an
 * Approve signal, after enforcing the gate's designated approval role and stamping the
 * approver identity. Extracted from WorkflowDashboardController; preserves the exact
 * role-enforcement ordering (thrown before the signal try/catch so the specific message is
 * not flattened) and AuraHandledException messages. All SOQL runs WITH SYSTEM_MODE.
 */
public inherited sharing class WorkflowApprovalCommandService {
  /**
   * @description Records an approval decision by delivering an Approve signal, after
   * enforcing the gate's designated approval role and stamping the approver identity.
   * @param req The approval request naming the instance, gate key, and decision.
   */
  public static void recordApproval(
    WorkflowDashboardCommandController.ApprovalRequest req
  ) {
    WorkflowDashboardSupport.checkAuthorization();
    // Enforce the approval gate's designated role BEFORE recording the decision, so a
    // dashboard admin cannot approve a gate they were not assigned to. Thrown before the
    // try/catch below so the specific message is not flattened into a generic one.
    enforceApprovalRole(req.instanceId, req.approvalKey);
    try {
      Map<String, Object> payload = new Map<String, Object>{
        'approved' => req.approved,
        'comments' => req.comments,
        // Record the immutable User Id (and username) as the authoritative approver
        // identity for the audit trail; the display name alone is mutable and not unique.
        'approverId' => UserInfo.getUserId(),
        'approverUsername' => UserInfo.getUserName(),
        'approver' => UserInfo.getName()
      };
      String payloadJson = JSON.serialize(payload);
      String signalName = 'Approve:' + req.approvalKey;

      WorkflowEngine.signal(
        String.valueOf(req.instanceId),
        signalName,
        payloadJson
      );
    } catch (Exception ex) {
      throw new AuraHandledException(ex.getMessage());
    }
  }

  /**
   * @description If the instance has a pending approval gate for the given key that
   * designates an approvalRole, require the running user to hold a custom permission of
   * that API name (or "Modify All Data" as a break-glass override). Gates with no role, or
   * no matching pending gate, impose no additional restriction.
   * @param instanceId The instance whose pending approval gate is checked.
   * @param approvalKey The approval gate key to match.
   */
  private static void enforceApprovalRole(Id instanceId, String approvalKey) {
    if (instanceId == null) {
      return;
    }
    // A non-blank role is only ever returned for a matched, still-pending gate, so
    // checking the role alone reproduces the previous "gateFound && role" guard.
    String requiredRole = findRequiredApprovalRole(instanceId, approvalKey);
    if (
      String.isNotBlank(requiredRole) &&
      !FeatureManagement.checkPermission(requiredRole) &&
      !WorkflowDashboardSupport.currentUserHasModifyAllData()
    ) {
      AuraHandledException ex = new AuraHandledException(
        'Unauthorized: this approval requires the "' +
          requiredRole +
          '" permission.'
      );
      ex.setMessage(
        'Unauthorized: this approval requires the "' +
          requiredRole +
          '" permission.'
      );
      throw ex;
    }
  }

  // Returns the approvalRole designated by the most recent pending approval gate whose key
  // matches approvalKey (which may be null/blank when the gate designates no role), or null
  // when no pending gate matches. Stops at the first matching gate, mirroring the previous
  // inline scan.
  private static String findRequiredApprovalRole(
    Id instanceId,
    String approvalKey
  ) {
    for (Workflow_Step_Execution__c se : [
      SELECT Output__c
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c = :instanceId AND Status__c = 'Pending'
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC, Id DESC
      LIMIT 50
    ]) {
      String resolved = WorkflowEngine.resolvePayload(se.Output__c);
      if (
        String.isBlank(resolved) || !resolved.contains('waitingForApproval')
      ) {
        continue;
      }
      try {
        Map<String, Object> state = (Map<String, Object>) JSON.deserializeUntyped(
          resolved
        );
        String stateKey = (String) state.get('approvalKey');
        if (
          state.get('waitingForApproval') == true &&
          approvalKey != null &&
          approvalKey.equalsIgnoreCase(stateKey)
        ) {
          return (String) state.get('approvalRole');
        }
      } catch (Exception ignored) {
      }
    }
    return null;
  }
}
