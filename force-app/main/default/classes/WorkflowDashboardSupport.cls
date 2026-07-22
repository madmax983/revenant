/**
 * @description Shared authorization, pagination-clamping, id-shape and error helpers
 * for the Revenant workflow-dashboard controllers and their services. Extracted from
 * WorkflowDashboardController so the endpoint logic can live in focused service classes
 * without duplicating the cross-cutting checks. All SOQL runs WITH SYSTEM_MODE, matching
 * the original controller behavior exactly.
 */
public inherited sharing class WorkflowDashboardSupport {
  /**
   * @description Enforces the Workflow Dashboard authorization gate: allows callers who
   * hold the Workflow_Admin custom permission (full admin) or the least-privilege
   * Workflow_Dashboard_View custom permission (read-only monitoring operator), otherwise
   * falls back to holders of the "Modify All Data" system permission. Throws an
   * AuraHandledException with the exact restricted-access message when no grant is present.
   */
  public static void checkAuthorization() {
    if (FeatureManagement.checkPermission('Workflow_Admin')) {
      return;
    }
    // Read-only monitoring operators hold Workflow_Dashboard_View (granted by the
    // Revenant_Operator permission set) so they can open the dashboard and inspect
    // instances/steps/signals WITHOUT holding Workflow_Admin, which would otherwise also
    // satisfy the separate operator-action gate (see checkOperatorAction) and defeat the
    // read-only/action separation.
    if (FeatureManagement.checkPermission('Workflow_Dashboard_View')) {
      return;
    }
    // Fall back to users who hold the "Modify All Data" system permission (see
    // currentUserHasModifyAllData). This replaces the previous hard-coded 'System
    // Administrator' profile-NAME comparison, which silently locked out real admins when
    // the profile was renamed (common post-migration) and could be spoofed by cloning a
    // profile and naming it 'System Administrator'.
    if (currentUserHasModifyAllData()) {
      return;
    }

    AuraHandledException ex = new AuraHandledException(
      'Unauthorized: Access to the Workflow Dashboard is restricted.'
    );
    ex.setMessage(
      'Unauthorized: Access to the Workflow Dashboard is restricted.'
    );
    throw ex;
  }

  /**
   * @description Enforces the operator-ACTION gate for state-mutating recovery endpoints
   * (re-drive, cancel, resume, compensate, pause/resume, redeliver, start). Allows callers
   * who hold the Workflow_Operator_Action custom permission (action-capable operator) or the
   * Workflow_Admin custom permission (full admin), otherwise falls back to holders of the
   * "Modify All Data" system permission. Read-only operators hold only Workflow_Dashboard_View
   * and are rejected here, so granting dashboard visibility never implicitly grants the ability
   * to mutate engine state. Throws an AuraHandledException with the exact required-permission
   * message when no grant is present.
   */
  public static void checkOperatorAction() {
    if (
      FeatureManagement.checkPermission('Workflow_Operator_Action') ||
      FeatureManagement.checkPermission('Workflow_Admin')
    ) {
      return;
    }
    if (currentUserHasModifyAllData()) {
      return;
    }

    AuraHandledException ex = new AuraHandledException(
      'Unauthorized: this action requires the "Workflow_Operator_Action" permission.'
    );
    ex.setMessage(
      'Unauthorized: this action requires the "Workflow_Operator_Action" permission.'
    );
    throw ex;
  }

  /**
   * @description True when the running user has "Modify All Data", granted via EITHER
   * their profile or an assigned permission set. Rename-proof and covers
   * permission-set-granted admins, unlike matching a mutable profile name.
   * @return True if the running user holds Modify All Data; false otherwise.
   */
  public static Boolean currentUserHasModifyAllData() {
    return ![
        SELECT Id
        FROM PermissionSetAssignment
        WHERE
          AssigneeId = :UserInfo.getUserId()
          AND PermissionSet.PermissionsModifyAllData = TRUE
        WITH SYSTEM_MODE
        LIMIT 1
      ]
      .isEmpty();
  }

  /**
   * @description Clamps a caller-supplied page size to [1, 100], defaulting blank or
   * non-positive values to 50.
   * @param limitSize The requested page size, possibly null or out of range.
   * @return The clamped page size.
   */
  public static Integer clampListLimit(Integer limitSize) {
    if (limitSize == null || limitSize <= 0) {
      return 50;
    }
    return limitSize > 100 ? 100 : limitSize;
  }

  /**
   * @description Clamps a caller-supplied offset to [0, 2000], defaulting blank or
   * negative values to 0.
   * @param offsetSize The requested offset, possibly null or out of range.
   * @return The clamped offset.
   */
  public static Integer clampListOffset(Integer offsetSize) {
    if (offsetSize == null || offsetSize < 0) {
      return 0;
    }
    return offsetSize > 2000 ? 2000 : offsetSize;
  }

  /**
   * @description True when the string is plausibly a 15/18-char CronTrigger (08e) or
   * AsyncApexJob (707) id.
   * @param jobIdStr The candidate job id string.
   * @return True when the value has the shape of a cron/async job id.
   */
  public static Boolean isJobIdShaped(String jobIdStr) {
    return (jobIdStr.length() == 15 || jobIdStr.length() == 18) &&
      (jobIdStr.startsWith('08e') || jobIdStr.startsWith('707'));
  }

  /**
   * @description Parses the attribute-filter JSON into an ordered list of "key=value"
   * match tokens, mirroring the previous inline resolution. Malformed or empty JSON yields
   * an empty list (treated by callers as "no attribute filter").
   * @param attributesFilterJson The raw attribute-filter JSON, or blank.
   * @return The ordered list of "key=value" match tokens.
   */
  public static List<String> parseAttributeKeyValues(
    String attributesFilterJson
  ) {
    List<String> targetKeyValues = new List<String>();
    if (String.isBlank(attributesFilterJson)) {
      return targetKeyValues;
    }
    try {
      Map<String, Object> raw = (Map<String, Object>) JSON.deserializeUntyped(
        attributesFilterJson
      );
      if (raw == null || raw.isEmpty()) {
        return targetKeyValues;
      }
      for (String k : raw.keySet()) {
        String val = String.valueOf(raw.get(k));
        targetKeyValues.add(k + '=' + (val == null ? '' : val));
      }
    } catch (Exception ignored) {
    }
    return targetKeyValues;
  }

  /**
   * @description Builds an AuraHandledException whose getMessage() returns the supplied
   * text (the explicit setMessage is required so the specific message survives to the
   * client instead of the generic "Script-thrown exception").
   * @param message The message to surface to the client.
   * @return The configured AuraHandledException.
   */
  public static AuraHandledException auraError(String message) {
    AuraHandledException ex = new AuraHandledException(message);
    ex.setMessage(message);
    return ex;
  }
}
