/**
 * @description Backs the dashboard's stalled-instance list and stalled count. Holds the
 * stalled WHERE-clause building and attribute-filter pre-query (the stalled predicate
 * uses two anti-join sub-selects, so the attribute match cannot be expressed inline and
 * is resolved into a bound id set). Genuine-stall detection is delegated to
 * WorkflowStallDetectionService. All SOQL runs in AccessLevel.SYSTEM_MODE.
 */
public inherited sharing class WorkflowStalledService {
  // Class-level static binding variables for the stalled dynamic SOQL: the wildcard term,
  // the idle cutoff, and the pre-queried attribute-matching id set. They must be in scope
  // of this class when Database.query() runs, even though the WHERE clause is built in a
  // helper method.
  private static String likeTerm;
  private static Datetime stalledCutoff;
  private static Set<Id> filterInstanceIds;
  // Attribute filter key-values (used only to decide whether to bind filterInstanceIds).
  private static String attributeFilter0;
  private static String attributeFilter1;

  // Upper bound on Suspended candidate rows a single stalled query/count scans, so a
  // large backlog of long-suspended instances cannot exhaust governor limits.
  private static final Integer STALLED_CANDIDATE_CAP = 2000;

  // Resolves attributeFilter0/1 (and resets filterInstanceIds) from the filter JSON.
  // Malformed JSON is treated as "no attribute filter".
  private static void resolveMatchingAttributes(String attributesFilterJson) {
    attributeFilter0 = null;
    attributeFilter1 = null;
    filterInstanceIds = new Set<Id>();
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

  // Attribute resolution for the stalled list/count, which cannot express the attribute
  // match inline (the stalled WHERE already uses two anti-join sub-selects and SOQL caps
  // sub-selects at 2). Resolves attributeFilter0/1, then pre-queries the matching instance
  // ids into filterInstanceIds for the WHERE bind.
  private static void resolveMatchingAttributesForStalled(
    String attributesFilterJson
  ) {
    resolveMatchingAttributes(attributesFilterJson);
    if (attributeFilter0 == null && attributeFilter1 == null) {
      return;
    }
    try {
      if (attributeFilter0 != null && attributeFilter1 != null) {
        Set<Id> ids0 = queryAttributeInstanceIds(attributeFilter0);
        for (Id instanceId : queryAttributeInstanceIds(attributeFilter1)) {
          if (ids0.contains(instanceId)) {
            filterInstanceIds.add(instanceId);
          }
        }
      } else {
        String target = (attributeFilter0 != null)
          ? attributeFilter0
          : attributeFilter1;
        filterInstanceIds.addAll(queryAttributeInstanceIds(target));
      }
    } catch (Exception ignored) {
    }
  }

  private static Set<Id> queryAttributeInstanceIds(String keyValue) {
    Set<Id> ids = new Set<Id>();
    for (Workflow_Search_Attribute__c attr : [
      SELECT Workflow_Instance__c
      FROM Workflow_Search_Attribute__c
      WHERE Key_Value__c = :keyValue
      WITH SYSTEM_MODE
      LIMIT 10000
    ]) {
      ids.add(attr.Workflow_Instance__c);
    }
    return ids;
  }

  // Appends the optional stalled predicates (workflow-name filter, search LIKE, attribute
  // id set) to a fully-formed literal base query and runs it. baseQuery and trailing are
  // string-literal fragments supplied by each caller; every user-supplied value reaches SOQL
  // only via a :bind variable (:workflowName / :likeTerm / :filterInstanceIds), so the
  // executed query text is provably built from literals plus :bind tokens (no returned
  // fragment concatenated into a query, no String.join). The caller resolves :stalledCutoff
  // and filterInstanceIds before calling.
  private static List<Workflow_Instance__c> queryStalledCandidates(
    String baseQuery,
    WorkflowDashboardController.StalledQuery criteria,
    String trailing
  ) {
    String workflowName = criteria.workflowName;
    String searchTerm = criteria.searchTerm;
    String query = baseQuery;
    if (String.isNotBlank(workflowName)) {
      query += ' AND Workflow_Name__c = :workflowName';
    }
    if (String.isNotBlank(searchTerm)) {
      likeTerm = '%' + searchTerm + '%';
      query += ' AND (Name LIKE :likeTerm OR Correlation_Key__c LIKE :likeTerm OR Workflow_Name__c LIKE :likeTerm OR Error_Message__c LIKE :likeTerm)';
    }
    if (attributeFilter0 != null || attributeFilter1 != null) {
      query += ' AND Id IN :filterInstanceIds';
    }
    query += trailing;
    return Database.query(query, AccessLevel.SYSTEM_MODE);
  }

  /**
   * @description Returns a page of genuinely stalled instances — candidates past the idle
   * threshold with no live job — filtered before pagination so the client never stops
   * paging early on a short in-memory-filtered page.
   * @param criteria The stalled-query filter, threshold, and pagination criteria.
   * @return One display-field map per stalled instance on the requested page.
   */
  public static List<Map<String, Object>> listStalled(
    WorkflowDashboardController.StalledQuery criteria
  ) {
    WorkflowDashboardSupport.checkAuthorization();
    Integer threshold = (criteria.thresholdMinutes == null)
      ? WorkflowEngine.staleThresholdMinutes
      : criteria.thresholdMinutes;
    stalledCutoff = Datetime.now().addMinutes(-threshold);

    resolveMatchingAttributesForStalled(criteria.attributesFilterJson);

    Integer limitSize = WorkflowDashboardSupport.clampListLimit(
      criteria.limitSize
    );
    Integer offsetSize = criteria.offsetSize;
    if (offsetSize == null || offsetSize < 0) {
      offsetSize = 0;
    }

    // The always-present base is a single string literal: it selects Suspended instances
    // idle past the cutoff with no sleep timer, no declared step timeout, and no pending
    // step-exec row (signal/approval/child waits park exactly one Pending row; excluding
    // them avoids false positives on legitimate waits). queryStalledCandidates appends the
    // optional predicates and runs the query.
    List<Workflow_Instance__c> candidates = queryStalledCandidates(
      'SELECT Id, Name, Workflow_Name__c, Status__c, Correlation_Key__c, CreatedDate, LastModifiedDate, Error_Message__c, Async_Job_Id__c, Sleep_Until__c, Deadline_At__c FROM Workflow_Instance__c WHERE Status__c = \'Suspended\' AND Sleep_Until__c = null AND LastModifiedDate <= :stalledCutoff AND Id NOT IN (SELECT Workflow_Instance__c FROM Workflow_Step_Execution__c WHERE Timeout_At__c != null) AND Id NOT IN (SELECT Workflow_Instance__c FROM Workflow_Step_Execution__c WHERE Status__c = \'Pending\')',
      criteria,
      ' ORDER BY LastModifiedDate ASC LIMIT :STALLED_CANDIDATE_CAP'
    );

    // Filter to genuinely stalled rows FIRST, then paginate, so the in-memory
    // job-liveness filter (which SOQL cannot express) never returns a short page
    // that would make the LWC stop paging before later stalled rows are reached.
    List<Map<String, Object>> stalledRows = WorkflowStallDetectionService.buildStalledRows(
      candidates,
      threshold
    );

    List<Map<String, Object>> results = new List<Map<String, Object>>();
    for (
      Integer i = offsetSize;
      i < stalledRows.size() &&
      results.size() < limitSize;
      i++
    ) {
      results.add(stalledRows[i]);
    }
    return results;
  }

  /**
   * @description Counts genuinely stalled instances for the given criteria, reporting a
   * capped flag when the candidate scan hit its governor-safety bound.
   * @param criteria The stalled-query filter and threshold (pagination ignored).
   * @return A map with the stalled count and a capped flag.
   */
  public static Map<String, Object> countStalled(
    WorkflowDashboardController.StalledQuery criteria
  ) {
    WorkflowDashboardSupport.checkAuthorization();
    Integer threshold = (criteria.thresholdMinutes == null)
      ? WorkflowEngine.staleThresholdMinutes
      : criteria.thresholdMinutes;
    stalledCutoff = Datetime.now().addMinutes(-threshold);

    resolveMatchingAttributesForStalled(criteria.attributesFilterJson);

    // Same always-present single-literal base as listStalled (minus the display fields);
    // queryStalledCandidates appends the optional predicates and runs the query.
    List<Workflow_Instance__c> candidates = queryStalledCandidates(
      'SELECT Id, Async_Job_Id__c, Sleep_Until__c, Status__c, LastModifiedDate FROM Workflow_Instance__c WHERE Status__c = \'Suspended\' AND Sleep_Until__c = null AND LastModifiedDate <= :stalledCutoff AND Id NOT IN (SELECT Workflow_Instance__c FROM Workflow_Step_Execution__c WHERE Timeout_At__c != null) AND Id NOT IN (SELECT Workflow_Instance__c FROM Workflow_Step_Execution__c WHERE Status__c = \'Pending\')',
      criteria,
      ' LIMIT :STALLED_CANDIDATE_CAP'
    );
    Boolean capped = candidates.size() >= STALLED_CANDIDATE_CAP;

    Integer count = WorkflowStallDetectionService.countStalledCandidates(
      candidates,
      threshold
    );
    return new Map<String, Object>{ 'count' => count, 'capped' => capped };
  }
}
