@IsTest
public class WorkflowDashboardQueryBuilders {
  // Shared fluent builders that assemble the WorkflowDashboardController request
  // wrappers for the dashboard test suite. Consolidating the wrapper construction
  // here keeps a single copy of each build block (no cross-file duplication) and
  // keeps every builder method to at most three parameters. Each builder is a 1:1
  // repackaging of the former positional test helpers: identical field values,
  // just assigned fluently.

  /**
   * @description Starts a fluent builder for a WorkflowDashboardController.InstanceQuery.
   * @return A new, empty InstanceQueryBuilder.
   */
  public static InstanceQueryBuilder instanceQuery() {
    return new InstanceQueryBuilder();
  }

  /**
   * @description Starts a fluent builder for a WorkflowDashboardController.StalledQuery.
   * @return A new, empty StalledQueryBuilder.
   */
  public static StalledQueryBuilder stalledQuery() {
    return new StalledQueryBuilder();
  }

  /**
   * @description Starts a fluent builder for a WorkflowDashboardController.UnroutedQuery.
   * @return A new, empty UnroutedQueryBuilder.
   */
  public static UnroutedQueryBuilder unroutedQuery() {
    return new UnroutedQueryBuilder();
  }

  /**
   * @description Fluent builder assembling an InstanceQuery for the getFilteredInstances
   * and getWorkflowStats dashboard tests.
   */
  public class InstanceQueryBuilder {
    private final WorkflowDashboardController.InstanceQuery q = new WorkflowDashboardController.InstanceQuery();

    /**
     * @description Sets the primary workflow-name, status, and search-term filters.
     * @param workflowName The workflow developer name to filter by.
     * @param status The instance status to filter by.
     * @param searchTerm The free-text search term to filter by.
     * @return This builder for chaining.
     */
    public InstanceQueryBuilder filter(
      String workflowName,
      String status,
      String searchTerm
    ) {
      q.workflowName = workflowName;
      q.status = status;
      q.searchTerm = searchTerm;
      return this;
    }

    /**
     * @description Sets the failure-category facet filter.
     * @param failureCategory The failure category to filter by.
     * @return This builder for chaining.
     */
    public InstanceQueryBuilder failureCategory(String failureCategory) {
      q.failureCategory = failureCategory;
      return this;
    }

    /**
     * @description Sets the JSON-encoded instance-attributes filter.
     * @param attributesFilterJson The attributes filter serialized as JSON.
     * @return This builder for chaining.
     */
    public InstanceQueryBuilder attributesFilter(String attributesFilterJson) {
      q.attributesFilterJson = attributesFilterJson;
      return this;
    }

    /**
     * @description Sets the pagination window and cache-buster token.
     * @param limitSize The maximum number of rows per page.
     * @param offsetSize The row offset into the result set.
     * @param cacheBuster A token used to defeat platform query caching in tests.
     * @return This builder for chaining.
     */
    public InstanceQueryBuilder page(
      Integer limitSize,
      Integer offsetSize,
      String cacheBuster
    ) {
      q.limitSize = limitSize;
      q.offsetSize = offsetSize;
      q.cacheBuster = cacheBuster;
      return this;
    }

    /**
     * @description Returns the assembled InstanceQuery.
     * @return The configured WorkflowDashboardController.InstanceQuery.
     */
    public WorkflowDashboardController.InstanceQuery build() {
      return q;
    }
  }

  /**
   * @description Fluent builder assembling a StalledQuery for the getStalledInstances and
   * getStalledCount dashboard tests.
   */
  public class StalledQueryBuilder {
    private final WorkflowDashboardController.StalledQuery q = new WorkflowDashboardController.StalledQuery();

    /**
     * @description Sets the stalled-instance selection criteria.
     * @param workflowName The workflow developer name to filter by.
     * @param searchTerm The free-text search term to filter by.
     * @param thresholdMinutes The minimum idle minutes for an instance to count as stalled.
     * @return This builder for chaining.
     */
    public StalledQueryBuilder criteria(
      String workflowName,
      String searchTerm,
      Integer thresholdMinutes
    ) {
      q.workflowName = workflowName;
      q.searchTerm = searchTerm;
      q.thresholdMinutes = thresholdMinutes;
      return this;
    }

    /**
     * @description Sets the pagination window and cache-buster token.
     * @param limitSize The maximum number of rows per page.
     * @param offsetSize The row offset into the result set.
     * @param cacheBuster A token used to defeat platform query caching in tests.
     * @return This builder for chaining.
     */
    public StalledQueryBuilder page(
      Integer limitSize,
      Integer offsetSize,
      String cacheBuster
    ) {
      q.limitSize = limitSize;
      q.offsetSize = offsetSize;
      q.cacheBuster = cacheBuster;
      return this;
    }

    /**
     * @description Sets the JSON-encoded instance-attributes filter.
     * @param attributesFilterJson The attributes filter serialized as JSON.
     * @return This builder for chaining.
     */
    public StalledQueryBuilder attributesFilter(String attributesFilterJson) {
      q.attributesFilterJson = attributesFilterJson;
      return this;
    }

    /**
     * @description Returns the assembled StalledQuery.
     * @return The configured WorkflowDashboardController.StalledQuery.
     */
    public WorkflowDashboardController.StalledQuery build() {
      return q;
    }
  }

  /**
   * @description Fluent builder assembling an UnroutedQuery for the getUnroutedSignals
   * dashboard test.
   */
  public class UnroutedQueryBuilder {
    private final WorkflowDashboardController.UnroutedQuery q = new WorkflowDashboardController.UnroutedQuery();

    /**
     * @description Sets the free-text search-term filter.
     * @param searchTerm The search term to filter unrouted signals by.
     * @return This builder for chaining.
     */
    public UnroutedQueryBuilder searchTerm(String searchTerm) {
      q.searchTerm = searchTerm;
      return this;
    }

    /**
     * @description Sets the pagination window and cache-buster token.
     * @param limitSize The maximum number of rows per page.
     * @param offsetSize The row offset into the result set.
     * @param cacheBuster A token used to defeat platform query caching in tests.
     * @return This builder for chaining.
     */
    public UnroutedQueryBuilder page(
      Integer limitSize,
      Integer offsetSize,
      String cacheBuster
    ) {
      q.limitSize = limitSize;
      q.offsetSize = offsetSize;
      q.cacheBuster = cacheBuster;
      return this;
    }

    /**
     * @description Returns the assembled UnroutedQuery.
     * @return The configured WorkflowDashboardController.UnroutedQuery.
     */
    public WorkflowDashboardController.UnroutedQuery build() {
      return q;
    }
  }
}
