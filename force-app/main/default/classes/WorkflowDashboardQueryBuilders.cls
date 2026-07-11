@IsTest
public class WorkflowDashboardQueryBuilders {
  // Shared fluent builders that assemble the WorkflowDashboardController request
  // wrappers for the dashboard test suite. Consolidating the wrapper construction
  // here keeps a single copy of each build block (no cross-file duplication) and
  // keeps every builder method to at most three parameters. Each builder is a 1:1
  // repackaging of the former positional test helpers: identical field values,
  // just assigned fluently.

  public static InstanceQueryBuilder instanceQuery() {
    return new InstanceQueryBuilder();
  }

  public static StalledQueryBuilder stalledQuery() {
    return new StalledQueryBuilder();
  }

  public static UnroutedQueryBuilder unroutedQuery() {
    return new UnroutedQueryBuilder();
  }

  // Builds InstanceQuery for getFilteredInstances / getWorkflowStats.
  public class InstanceQueryBuilder {
    private final WorkflowDashboardController.InstanceQuery q = new WorkflowDashboardController.InstanceQuery();

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

    public InstanceQueryBuilder failureCategory(String failureCategory) {
      q.failureCategory = failureCategory;
      return this;
    }

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

    public WorkflowDashboardController.InstanceQuery build() {
      return q;
    }
  }

  // Builds StalledQuery for getStalledInstances / getStalledCount.
  public class StalledQueryBuilder {
    private final WorkflowDashboardController.StalledQuery q = new WorkflowDashboardController.StalledQuery();

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

    public WorkflowDashboardController.StalledQuery build() {
      return q;
    }
  }

  // Builds UnroutedQuery for getUnroutedSignals.
  public class UnroutedQueryBuilder {
    private final WorkflowDashboardController.UnroutedQuery q = new WorkflowDashboardController.UnroutedQuery();

    public UnroutedQueryBuilder searchTerm(String searchTerm) {
      q.searchTerm = searchTerm;
      return this;
    }

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

    public WorkflowDashboardController.UnroutedQuery build() {
      return q;
    }
  }
}
