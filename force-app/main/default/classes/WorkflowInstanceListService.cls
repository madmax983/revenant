/**
 * @description Backs the dashboard's filtered-instance list and the workflow-stat rollup.
 * Holds the dynamic WHERE-clause building, attribute-filter resolution, and page query
 * for those two read endpoints; the job-liveness and stalled-detection logic lives in
 * WorkflowJobLivenessService / WorkflowStallDetectionService. All SOQL runs in
 * AccessLevel.SYSTEM_MODE, matching the original controller exactly.
 */
public inherited sharing class WorkflowInstanceListService {
  // Class-level static binding variable for the dynamic SOQL wildcard term; a :bind must be
  // in scope of this class when Database.query() executes, and holding the LIKE term in a
  // static keeps it addressable as :likeTerm from the assembled query.
  private static String likeTerm;
  // Binding variables for filtering by attributes (up to 2 semi-joins for performance).
  private static String attributeFilter0;
  private static String attributeFilter1;

  private static final Set<String> TERMINAL_STATUSES = new Set<String>{
    'Completed',
    'Failed',
    'Compensated',
    'Cancelled',
    'ContinuedAsNew'
  };

  // Resolves attributeFilter0/1 from the filter JSON for the non-stalled queries, which
  // express the attribute match as inline SOQL semi-joins in the WHERE clause. Malformed
  // JSON is treated as "no attribute filter".
  private static void resolveMatchingAttributes(String attributesFilterJson) {
    attributeFilter0 = null;
    attributeFilter1 = null;
    List<String> targetKeyValues = WorkflowDashboardSupport.parseAttributeKeyValues(
      attributesFilterJson
    );
    if (targetKeyValues.size() > 0) {
      attributeFilter0 = targetKeyValues[0];
    }
    if (targetKeyValues.size() > 1) {
      attributeFilter1 = targetKeyValues[1];
    }
  }

  // Runs the filtered-instance SOQL. The bind tokens (:workflowName, :status,
  // :failureCategory, :likeTerm, :attributeFilter0/1, and :limitSize / :offsetSize) resolve
  // against this method's scope, so the caller passes the clamped page bounds in.
  private static List<Workflow_Instance__c> queryFilteredInstances(
    WorkflowDashboardController.InstanceQuery criteria,
    Integer limitSize,
    Integer offsetSize
  ) {
    String workflowName = criteria.workflowName;
    String status = criteria.status;
    String failureCategory = criteria.failureCategory;
    String searchTerm = criteria.searchTerm;

    // The dynamic WHERE predicates are assembled here, in the same method that runs
    // Database.query, from string literals appended to the `whereBody` local (no helper
    // return, no String.join), so the entire query text is provably built from literals
    // plus :bind tokens. Every user-supplied value reaches SOQL only via a :bind variable
    // (:workflowName / :status / :failureCategory / :likeTerm / :attributeFilter0 /
    // :attributeFilter1), never through string concatenation. Each predicate is prefixed
    // with ' AND '; the leading ' AND ' is rewritten to ' WHERE ' once at the end.
    String whereBody = '';
    if (String.isNotBlank(workflowName)) {
      whereBody += ' AND Workflow_Name__c = :workflowName';
    }
    if (String.isNotBlank(status)) {
      whereBody += ' AND Status__c = :status';
    }
    if (String.isNotBlank(failureCategory)) {
      whereBody += ' AND Failure_Category__c = :failureCategory';
    }
    if (String.isNotBlank(searchTerm)) {
      likeTerm = '%' + searchTerm + '%';
      whereBody += ' AND (Name LIKE :likeTerm OR Correlation_Key__c LIKE :likeTerm OR Workflow_Name__c LIKE :likeTerm OR Error_Message__c LIKE :likeTerm)';
    }
    if (attributeFilter0 != null) {
      whereBody += ' AND Id IN (SELECT Workflow_Instance__c FROM Workflow_Search_Attribute__c WHERE Key_Value__c = :attributeFilter0)';
    }
    if (attributeFilter1 != null) {
      whereBody += ' AND Id IN (SELECT Workflow_Instance__c FROM Workflow_Search_Attribute__c WHERE Key_Value__c = :attributeFilter1)';
    }

    String query =
      'SELECT Id, Name, Workflow_Name__c, Status__c, Correlation_Key__c, CreatedDate, LastModifiedDate, Error_Message__c, Async_Job_Id__c, Sleep_Until__c, Deadline_At__c, Failure_Category__c ' +
      'FROM Workflow_Instance__c';
    if (String.isNotBlank(whereBody)) {
      query += ' WHERE ' + whereBody.substring(5);
    }
    query += ' ORDER BY CreatedDate DESC LIMIT :limitSize OFFSET :offsetSize';

    return Database.query(query, AccessLevel.SYSTEM_MODE);
  }

  /**
   * @description Returns a paginated, filtered page of workflow instances with per-row
   * display fields including a computed waiting-on hint and a stalled flag.
   * @param criteria The filter, attribute, and pagination criteria.
   * @return One display-field map per matching instance, newest first.
   */
  public static List<Map<String, Object>> listInstances(
    WorkflowDashboardController.InstanceQuery criteria
  ) {
    WorkflowDashboardSupport.checkAuthorization();
    resolveMatchingAttributes(criteria.attributesFilterJson);

    Integer limitSize = WorkflowDashboardSupport.clampListLimit(
      criteria.limitSize
    );
    Integer offsetSize = WorkflowDashboardSupport.clampListOffset(
      criteria.offsetSize
    );
    List<Workflow_Instance__c> instances = queryFilteredInstances(
      criteria,
      limitSize,
      offsetSize
    );

    Set<Id> pageIds = new Set<Id>();
    for (Workflow_Instance__c inst : instances) {
      pageIds.add(inst.Id);
    }
    Set<Id> activeCronIds = new Set<Id>();
    Set<Id> activeAsyncIds = new Set<Id>();
    WorkflowJobLivenessService.loadActiveJobIds(
      instances,
      activeCronIds,
      activeAsyncIds
    );
    Set<Id> instancesWithStepTimeout = WorkflowJobLivenessService.queryInstancesWithStepTimeout(
      pageIds
    );
    Set<Id> instancesWithPendingStep = WorkflowJobLivenessService.queryInstancesWithPendingStep(
      pageIds
    );
    // Awaited-signal descriptors for the Suspended rows parked on a signal/approval/child
    // wait (bulk-resolved in one query to avoid N+1); timer waits get no descriptor.
    Map<Id, Map<String, Object>> waitDescriptors = WorkflowWaitDescriptorService.describeSignalWaits(
      instances
    );

    Long nowMs = Datetime.now().getTime();
    List<Map<String, Object>> results = new List<Map<String, Object>>();
    for (Workflow_Instance__c inst : instances) {
      String waitingOn = WorkflowJobLivenessService.computeWaitingOn(
        inst,
        activeCronIds,
        activeAsyncIds
      );
      Long idleMinutes = TERMINAL_STATUSES.contains(inst.Status__c)
        ? null
        : Math.max(0L, (nowMs - inst.LastModifiedDate.getTime()) / 60000L);
      WorkflowStallDetectionService.StallSignals sig = new WorkflowStallDetectionService.StallSignals();
      sig.hasStepTimeout = instancesWithStepTimeout.contains(inst.Id);
      sig.hasPendingStep = instancesWithPendingStep.contains(inst.Id);
      sig.idleMinutes = idleMinutes;
      sig.thresholdMinutes = WorkflowEngine.staleThresholdMinutes;
      Boolean stalled = WorkflowStallDetectionService.computeStalled(
        inst,
        waitingOn,
        sig
      );

      Map<String, Object> m = WorkflowStallDetectionService.buildInstanceRow(
        inst,
        waitingOn,
        idleMinutes
      );
      m.put('stalled', stalled);
      m.put('Failure_Category__c', inst.Failure_Category__c);
      m.put('waitDescriptor', waitDescriptors.get(inst.Id));
      results.add(m);
    }
    return results;
  }

  /**
   * @description Rolls instances up into total / active / completed / failed counts for
   * the summary tiles; reuses InstanceQuery but reads only the filter fields.
   * @param criteria The filter criteria (pagination and failureCategory ignored).
   * @return A map of the total, active, completed, and failed counts.
   */
  public static Map<String, Integer> rollupStats(
    WorkflowDashboardController.InstanceQuery criteria
  ) {
    WorkflowDashboardSupport.checkAuthorization();
    resolveMatchingAttributes(criteria.attributesFilterJson);

    Map<String, Integer> results = new Map<String, Integer>{
      'total' => 0,
      'active' => 0,
      'completed' => 0,
      'failed' => 0
    };

    // Locals named to match the :workflowName / :status bind tokens; the WHERE predicates
    // are assembled here, in the same method that runs Database.query, from string literals
    // appended to the `whereBody` local (no helper return, no String.join), so the whole
    // query text is provably literals plus :bind tokens. The rollup ignores failureCategory
    // (never set on this path), so that predicate is intentionally absent. Each predicate is
    // prefixed with ' AND '; the leading ' AND ' is rewritten to ' WHERE ' once at the end.
    String workflowName = criteria.workflowName;
    String status = criteria.status;
    String searchTerm = criteria.searchTerm;

    String whereBody = '';
    if (String.isNotBlank(workflowName)) {
      whereBody += ' AND Workflow_Name__c = :workflowName';
    }
    if (String.isNotBlank(status)) {
      whereBody += ' AND Status__c = :status';
    }
    if (String.isNotBlank(searchTerm)) {
      likeTerm = '%' + searchTerm + '%';
      whereBody += ' AND (Name LIKE :likeTerm OR Correlation_Key__c LIKE :likeTerm OR Workflow_Name__c LIKE :likeTerm OR Error_Message__c LIKE :likeTerm)';
    }
    if (attributeFilter0 != null) {
      whereBody += ' AND Id IN (SELECT Workflow_Instance__c FROM Workflow_Search_Attribute__c WHERE Key_Value__c = :attributeFilter0)';
    }
    if (attributeFilter1 != null) {
      whereBody += ' AND Id IN (SELECT Workflow_Instance__c FROM Workflow_Search_Attribute__c WHERE Key_Value__c = :attributeFilter1)';
    }

    String query = 'SELECT Status__c, COUNT(Id) cnt FROM Workflow_Instance__c';
    if (String.isNotBlank(whereBody)) {
      query += ' WHERE ' + whereBody.substring(5);
    }
    query += ' GROUP BY Status__c';

    for (AggregateResult ar : Database.query(query, AccessLevel.SYSTEM_MODE)) {
      WorkflowStallDetectionService.bucketWorkflowStat(
        results,
        (String) ar.get('Status__c'),
        (Integer) ar.get('cnt')
      );
    }
    return results;
  }
}
