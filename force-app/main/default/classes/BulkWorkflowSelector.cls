/**
 * BulkWorkflowSelector
 *
 * Single source of truth for the eligible-instance selection shared by
 * BulkCancelWorkflow and BulkRedriveWorkflow. Both bulk jobs page over the same
 * dashboard filter surface (workflowName / status / searchTerm) and exclude
 * their own Workflow_Name__c (the ouroboros guard); they differ ONLY in which
 * status set is eligible and which name to exclude. That variance is injected
 * through the constructor, so the count/fetch SOQL lives here exactly once
 * instead of being copy-pasted (and hand-branched eight ways) into each job.
 *
 * Runs `inherited sharing` so it evaluates in the sharing context of its caller
 * — the same implicit behavior the two bulk jobs had before extraction. Every
 * dynamic clause is bound (never string-concatenated), so operator-supplied
 * search text can never inject SOQL, and queries run in system mode via
 * AccessLevel.SYSTEM_MODE (equivalent to the original `WITH SYSTEM_MODE`).
 */
public inherited sharing class BulkWorkflowSelector {
  private final Set<String> eligibleStatuses;
  private final String excludeWorkflowName;

  /**
   * Value object wrapping the three selection parameters so the fetch/count
   * entry points take one cohesive filter rather than a long positional list.
   */
  public class Criteria {
    public String workflowName;
    public String status;
    public String searchTerm;

    /**
     * @description Builds a selection filter from the dashboard's three inputs.
     * @param workflowName The workflow developer name to restrict to, or blank for any.
     * @param status An explicit status filter, or blank to include all eligible statuses.
     * @param searchTerm A free-text term matched against name, correlation key, workflow name, and error message.
     */
    public Criteria(String workflowName, String status, String searchTerm) {
      this.workflowName = workflowName;
      this.status = status;
      this.searchTerm = searchTerm;
    }
  }

  /**
   * @description Creates a selector for one bulk job by injecting the status set it treats
   * as eligible and the workflow name it must exclude (its own, the ouroboros guard).
   * @param eligibleStatuses The instance statuses this bulk job is allowed to act on.
   * @param excludeWorkflowName The workflow name to exclude so the job never selects itself.
   */
  public BulkWorkflowSelector(
    Set<String> eligibleStatuses,
    String excludeWorkflowName
  ) {
    this.eligibleStatuses = eligibleStatuses;
    this.excludeWorkflowName = excludeWorkflowName;
  }

  /**
   * @description Resolves the effective status set: an explicit status filter is honored
   * but intersected with the eligible set (so filtering to a non-eligible status yields
   * nothing), while a blank filter expands to the full eligible set.
   * @param status The operator-supplied status filter, or blank for all eligible statuses.
   * @return The statuses to query, empty when the requested status is not eligible.
   */
  private List<String> effectiveStatuses(String status) {
    List<String> result = new List<String>();
    if (String.isBlank(status)) {
      result.addAll(eligibleStatuses);
    } else if (eligibleStatuses.contains(status)) {
      result.add(status);
    }
    return result;
  }

  /**
   * @description Exact count of eligible instances matching the filter — the number shown
   * to the operator for confirmation before a bulk action runs.
   * @param c The selection criteria to count against.
   * @return The number of matching eligible instances, or zero when no status is eligible.
   */
  public Integer count(Criteria c) {
    List<String> effStatuses = effectiveStatuses(c.status);
    if (effStatuses.isEmpty()) {
      return 0;
    }
    Map<String, Object> binds = new Map<String, Object>{
      'statuses' => effStatuses
    };
    String whereClause = buildWhere(c, null, binds);
    return Database.countQueryWithBinds(
      'SELECT COUNT() FROM Workflow_Instance__c WHERE ' + whereClause,
      binds,
      AccessLevel.SYSTEM_MODE
    );
  }

  /**
   * @description Fetches up to `chunkSize` eligible instance Ids ordered by Id, starting
   * strictly after `afterId`. Ordering by Id gives a stable, resumable cursor across
   * batch yield boundaries.
   * @param c The selection criteria to fetch against.
   * @param afterId The exclusive lower-bound Id cursor; pass null to start from the beginning.
   * @param chunkSize The maximum number of Ids to return in this page.
   * @return The matching instance Ids in ascending Id order, empty when no status is eligible.
   */
  public List<Id> fetchChunk(Criteria c, Id afterId, Integer chunkSize) {
    List<String> effStatuses = effectiveStatuses(c.status);
    if (effStatuses.isEmpty()) {
      return new List<Id>();
    }
    Map<String, Object> binds = new Map<String, Object>{
      'statuses' => effStatuses,
      'lim' => chunkSize
    };
    String whereClause = buildWhere(c, afterId, binds);
    List<Workflow_Instance__c> rows = Database.queryWithBinds(
      'SELECT Id FROM Workflow_Instance__c WHERE ' +
        whereClause +
        ' ORDER BY Id ASC LIMIT :lim',
      binds,
      AccessLevel.SYSTEM_MODE
    );
    List<Id> ids = new List<Id>();
    for (Workflow_Instance__c inst : rows) {
      ids.add(inst.Id);
    }
    return ids;
  }

  /**
   * @description Builds the shared WHERE body and populates `binds` (which the caller has
   * already seeded with the `statuses` bind). Optional clauses are appended as guard-driven
   * fragments rather than through a combinatorial if/else tree, and every value is bound.
   * @param c The selection criteria supplying the optional workflow-name and search filters.
   * @param afterId The exclusive Id cursor to append as a keyset clause, or null to omit it.
   * @param binds The bind map to populate; mutated in place with each clause's bound values.
   * @return The composed WHERE clause body (without the leading WHERE keyword).
   */
  private String buildWhere(Criteria c, Id afterId, Map<String, Object> binds) {
    binds.put('excludeName', excludeWorkflowName);
    List<String> clauses = new List<String>{
      'Status__c IN :statuses',
      'Workflow_Name__c != :excludeName'
    };
    if (afterId != null) {
      binds.put('afterId', afterId);
      clauses.add('Id > :afterId');
    }
    if (String.isNotBlank(c.workflowName)) {
      binds.put('workflowName', c.workflowName);
      clauses.add('Workflow_Name__c = :workflowName');
    }
    if (String.isNotBlank(c.searchTerm)) {
      binds.put('likeTerm', '%' + c.searchTerm + '%');
      clauses.add(
        '(Name LIKE :likeTerm' +
          ' OR Correlation_Key__c LIKE :likeTerm' +
          ' OR Workflow_Name__c LIKE :likeTerm' +
          ' OR Error_Message__c LIKE :likeTerm)'
      );
    }
    return String.join(clauses, ' AND ');
  }
}
