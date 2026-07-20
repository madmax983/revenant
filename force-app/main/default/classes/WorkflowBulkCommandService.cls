/**
 * @description Bulk operator actions for the workflow dashboard: eligibility counts and
 * the filter-scoped re-drive / cancel launchers, each of which runs asynchronously as a
 * BulkRedriveWorkflow / BulkCancelWorkflow instance. Extracted from
 * WorkflowDashboardController; preserves the exact authorization ordering and
 * AuraHandledException messages of the original.
 */
public inherited sharing class WorkflowBulkCommandService {
  /**
   * @description Exact count of failed instances that a "Re-drive matching" action would
   * re-enqueue for the operator's current filter.
   * @param workflowName The workflow name filter, or null for all.
   * @param status The status filter, or null for all.
   * @param searchTerm The free-text search term, or null for none.
   * @return The number of re-drive-eligible instances matching the filter.
   */
  public static Integer countRedriveEligible(
    String workflowName,
    String status,
    String searchTerm
  ) {
    WorkflowDashboardSupport.checkAuthorization();
    try {
      return BulkRedriveWorkflow.countEligible(
        workflowName,
        status,
        searchTerm
      );
    } catch (Exception ex) {
      throw new AuraHandledException(ex.getMessage());
    }
  }

  /**
   * @description Re-drives every failed instance matching the operator's current filter in
   * a single bounded action. The actual re-drive runs asynchronously as a
   * BulkRedriveWorkflow instance.
   * @param workflowName The workflow name filter, or null for all.
   * @param status The status filter, or null for all.
   * @param searchTerm The free-text search term, or null for none.
   * @return A map of { started, eligibleCount, redriveInstanceId } describing the launched
   * re-driver.
   */
  public static Map<String, Object> redriveMatching(
    String workflowName,
    String status,
    String searchTerm
  ) {
    WorkflowDashboardSupport.checkAuthorization();
    WorkflowDashboardSupport.checkOperatorAction();
    try {
      Integer eligibleCount = BulkRedriveWorkflow.countEligible(
        workflowName,
        status,
        searchTerm
      );
      if (eligibleCount == 0) {
        return new Map<String, Object>{
          'started' => false,
          'eligibleCount' => 0,
          'redriveInstanceId' => null
        };
      }

      Map<String, Object> filter = new Map<String, Object>{
        'workflowName' => workflowName,
        'status' => status,
        'searchTerm' => searchTerm
      };
      String correlationKey =
        'BulkRedrive_' +
        DateTime.now().getTime() +
        '_' +
        Math.abs(Crypto.getRandomLong());
      Id redriveInstanceId = WorkflowEngine.start(
        BulkRedriveWorkflow.REDRIVER_WORKFLOW_NAME,
        correlationKey,
        filter
      );

      return new Map<String, Object>{
        'started' => true,
        'eligibleCount' => eligibleCount,
        'redriveInstanceId' => redriveInstanceId
      };
    } catch (Exception ex) {
      throw new AuraHandledException(ex.getMessage());
    }
  }

  /**
   * @description Exact count of active/stalled instances that a "Cancel matching" action
   * would cancel/rollback for the operator's current filter.
   * @param workflowName The workflow name filter, or null for all.
   * @param status The status filter, or null for all.
   * @param searchTerm The free-text search term, or null for none.
   * @return The number of cancel-eligible instances matching the filter.
   */
  public static Integer countCancelEligible(
    String workflowName,
    String status,
    String searchTerm
  ) {
    WorkflowDashboardSupport.checkAuthorization();
    try {
      return BulkCancelWorkflow.countEligible(workflowName, status, searchTerm);
    } catch (Exception ex) {
      throw new AuraHandledException(ex.getMessage());
    }
  }

  /**
   * @description Cancels every active or stalled instance matching the operator's current
   * filter in a single bounded action, WITHOUT running compensations.
   * @param workflowName The workflow name filter, or null for all.
   * @param status The status filter, or null for all.
   * @param searchTerm The free-text search term, or null for none.
   * @return A map describing the launched bulk-cancel job.
   */
  public static Map<String, Object> cancelMatching(
    String workflowName,
    String status,
    String searchTerm
  ) {
    return startBulkCancel(
      new Map<String, Object>{
        'workflowName' => workflowName,
        'status' => status,
        'searchTerm' => searchTerm,
        'runCompensations' => false
      }
    );
  }

  /**
   * @description Cancels every active or stalled instance matching the operator's current
   * filter in a single bounded action, running each instance's compensations as part of
   * the rollback.
   * @param workflowName The workflow name filter, or null for all.
   * @param status The status filter, or null for all.
   * @param searchTerm The free-text search term, or null for none.
   * @return A map describing the launched bulk-cancel job.
   */
  public static Map<String, Object> cancelMatchingWithCompensations(
    String workflowName,
    String status,
    String searchTerm
  ) {
    return startBulkCancel(
      new Map<String, Object>{
        'workflowName' => workflowName,
        'status' => status,
        'searchTerm' => searchTerm,
        'runCompensations' => true
      }
    );
  }

  // Shared bulk-cancel launcher. The filter map already carries the operator's
  // workflowName/status/searchTerm plus the runCompensations flag; the BulkCancelWorkflow
  // instance reads it to page and cancel the matching set asynchronously.
  private static Map<String, Object> startBulkCancel(
    Map<String, Object> filter
  ) {
    WorkflowDashboardSupport.checkAuthorization();
    WorkflowDashboardSupport.checkOperatorAction();
    try {
      String workflowName = (String) filter.get('workflowName');
      String status = (String) filter.get('status');
      String searchTerm = (String) filter.get('searchTerm');
      Integer eligibleCount = BulkCancelWorkflow.countEligible(
        workflowName,
        status,
        searchTerm
      );
      if (eligibleCount == 0) {
        return new Map<String, Object>{
          'started' => false,
          'eligibleCount' => 0,
          'cancelInstanceId' => null
        };
      }

      String correlationKey =
        'BulkCancel_' +
        DateTime.now().getTime() +
        '_' +
        Math.abs(Crypto.getRandomLong());
      Id cancelInstanceId = WorkflowEngine.start(
        BulkCancelWorkflow.CANCELER_WORKFLOW_NAME,
        correlationKey,
        filter
      );

      return new Map<String, Object>{
        'started' => true,
        'eligibleCount' => eligibleCount,
        'cancelInstanceId' => cancelInstanceId
      };
    } catch (Exception ex) {
      throw new AuraHandledException(ex.getMessage());
    }
  }
}
