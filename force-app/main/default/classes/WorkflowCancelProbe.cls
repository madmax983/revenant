/**
 * @description Engine cancel reader for `StepContext.isCancellationRequested()`
 * (issue #143). One read is one SOQL and 0 DML. It reads the status of the
 * instance and of its five nearest ancestors. Five is the SOQL limit for a
 * parent path. `cancel()` marks all active descendants in the same
 * transaction, so a deeper descendant sees its own status. Runs in system mode.
 */
public inherited sharing class WorkflowCancelProbe implements StepContext.CancellationSource {
  private static final Set<String> CANCEL_STATUSES = new Set<String>{
    'Cancelled',
    'Cancelling'
  };
  private static final Integer ANCESTOR_DEPTH = 5;

  private Id instanceId;

  /**
   * @description Makes a reader for one instance.
   * @param instanceId The instance of the running step.
   */
  public WorkflowCancelProbe(Id instanceId) {
    this.instanceId = instanceId;
  }

  /**
   * @description Reads the cancel state now.
   * @return True when the instance or one of its five nearest ancestors is
   * `Cancelled` or `Cancelling`. False when the instance is missing.
   */
  public Boolean isCancellationRequested() {
    Workflow_Instance__c row = readChain(this.instanceId);
    return row != null &&
      (isCancelStatus(row.Status__c) || nearestCancelledAncestor(row) != null);
  }

  /**
   * @description Tells if a status means "cancel requested".
   * @param status The instance status.
   * @return True for `Cancelled` and `Cancelling`.
   */
  public static Boolean isCancelStatus(String status) {
    return status != null && CANCEL_STATUSES.contains(status);
  }

  /**
   * @description Gives the status of the nearest cancelled ancestor. One SOQL.
   * @param instanceId The instance to start from. Its own status is not read.
   * @return `Cancelled`, `Cancelling`, or null when no ancestor in five levels
   * is cancelled.
   */
  public static String ancestorCancelStatus(Id instanceId) {
    Workflow_Instance__c row = readChain(instanceId);
    return row == null ? null : nearestCancelledAncestor(row);
  }

  // Walks the queried parent path. It never reads past ANCESTOR_DEPTH, because
  // the query does not load a deeper level.
  private static String nearestCancelledAncestor(Workflow_Instance__c row) {
    Workflow_Instance__c node = row;
    for (Integer depth = 0; depth < ANCESTOR_DEPTH && node != null; depth++) {
      node = node.Parent_Instance__r;
      if (node != null && isCancelStatus(node.Status__c)) {
        return node.Status__c;
      }
    }
    return null;
  }

  private static Workflow_Instance__c readChain(Id instanceId) {
    if (instanceId == null) {
      return null;
    }
    List<Workflow_Instance__c> rows = [
      SELECT
        Status__c,
        Parent_Instance__r.Status__c,
        Parent_Instance__r.Parent_Instance__r.Status__c,
        Parent_Instance__r.Parent_Instance__r.Parent_Instance__r.Status__c,
        Parent_Instance__r.Parent_Instance__r.Parent_Instance__r.Parent_Instance__r.Status__c,
        Parent_Instance__r.Parent_Instance__r.Parent_Instance__r.Parent_Instance__r.Parent_Instance__r.Status__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
      WITH SYSTEM_MODE
      LIMIT 1
    ];
    return rows.isEmpty() ? null : rows[0];
  }
}
