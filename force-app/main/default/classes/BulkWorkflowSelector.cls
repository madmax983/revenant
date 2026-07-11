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

    public Criteria(String workflowName, String status, String searchTerm) {
      this.workflowName = workflowName;
      this.status = status;
      this.searchTerm = searchTerm;
    }
  }

  public BulkWorkflowSelector(
    Set<String> eligibleStatuses,
    String excludeWorkflowName
  ) {
    this.eligibleStatuses = eligibleStatuses;
    this.excludeWorkflowName = excludeWorkflowName;
  }

  /**
   * Resolves the effective status set: an explicit status filter is honored but
   * intersected with the eligible set (so filtering to a non-eligible status
   * yields nothing), while a blank filter expands to the full eligible set.
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
   * Exact count of eligible instances matching the filter — the number shown to
   * the operator for confirmation.
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
   * Up to `chunkSize` eligible instance Ids ordered by Id, starting strictly
   * after `afterId`. Ordering by Id gives a stable, resumable cursor across
   * yield boundaries.
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
   * Builds the shared WHERE body and populates `binds` (which the caller has
   * already seeded with the `statuses` bind). Optional clauses are appended as
   * guard-driven fragments rather than through a combinatorial if/else tree.
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
