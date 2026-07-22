/**
 * @description Apex controller backing the READ endpoints of the Revenant workflow
 * dashboard LWCs (instance lists, stats, trends, payload/detail resolution, stalled /
 * unrouted-signal views, version drain, watchdog / concurrency status, definition
 * discovery). Each endpoint is a thin delegator to a focused read service, preserving the
 * original @AuraEnabled names, cacheable flags, signatures, authorization ordering, and
 * AuraHandledException mapping exactly. Operator ACTION endpoints live on
 * WorkflowDashboardCommandController; the query-criteria DTOs (InstanceQuery / StalledQuery
 * / UnroutedQuery) remain here because WorkflowDashboardQueryBuilders binds to them by
 * qualified name.
 */
public inherited sharing class WorkflowDashboardController {
  // Retained @TestVisible toggle used by WorkflowDashboardControllerAuthTest to exercise
  // the definition-discovery fallback path. Not read by production logic.
  @TestVisible
  private static Boolean forceDefinitionFallback = false;

  // Query criteria for the filtered-instance list and the workflow-stat rollup. Field-based
  // (@AuraEnabled properties) so the LWC and tests populate it by assignment; a wide
  // constructor would re-introduce the long parameter list this wrapper removes. Unset
  // fields default to null, reproducing the previous shorter overloads.
  /**
   * @description Field-based query criteria for the filtered-instance list and the
   * workflow-stat rollup, populated by the LWC and tests via assignment; unset fields
   * default to null.
   */
  public class InstanceQuery {
    @AuraEnabled
    public String workflowName;
    @AuraEnabled
    public String status;
    @AuraEnabled
    public String searchTerm;
    @AuraEnabled
    public String failureCategory;
    @AuraEnabled
    public Integer limitSize;
    @AuraEnabled
    public Integer offsetSize;
    @AuraEnabled
    public String cacheBuster;
    @AuraEnabled
    public String attributesFilterJson;
  }

  // cacheBuster is unused in Apex; it only varies the client-side cache key so a dashboard
  // refresh re-queries instead of serving a stale cached list.
  // Query criteria shared by the stalled-instance list and the stalled count. Field-based
  // (@AuraEnabled properties) so the LWC and tests populate it by assignment. getStalledCount
  // ignores the pagination fields (limitSize/offsetSize/cacheBuster); getStalledInstances uses
  // them. Unset fields default to null, reproducing the previous shorter overloads.
  /**
   * @description Field-based query criteria shared by the stalled-instance list and the
   * stalled count; the count ignores the pagination fields. Unset fields default to null.
   */
  public class StalledQuery {
    @AuraEnabled
    public String workflowName;
    @AuraEnabled
    public String searchTerm;
    @AuraEnabled
    public Integer thresholdMinutes;
    @AuraEnabled
    public Integer limitSize;
    @AuraEnabled
    public Integer offsetSize;
    @AuraEnabled
    public String cacheBuster;
    @AuraEnabled
    public String attributesFilterJson;
  }

  // Query criteria for the unrouted-signal list. Field-based (@AuraEnabled properties) so the
  // LWC and tests populate it by assignment. cacheBuster only varies the client-side cache key
  // and is unused in Apex.
  /**
   * @description Field-based query criteria for the unrouted-signal list, populated by the
   * LWC and tests via assignment; unset fields default to null.
   */
  public class UnroutedQuery {
    @AuraEnabled
    public String searchTerm;
    @AuraEnabled
    public Integer limitSize;
    @AuraEnabled
    public Integer offsetSize;
    @AuraEnabled
    public String cacheBuster;
  }

  /**
   * @description Returns a paginated, filtered page of workflow instances with per-row
   * display fields including a computed waiting-on hint and a stalled flag.
   * @param criteria The filter, attribute, and pagination criteria.
   * @return One display-field map per matching instance, newest first.
   */
  @AuraEnabled(cacheable=true)
  public static List<Map<String, Object>> getFilteredInstances(
    InstanceQuery criteria
  ) {
    return WorkflowInstanceListService.listInstances(criteria);
  }

  /**
   * @description Returns a page of genuinely stalled instances — candidates past the idle
   * threshold with no live job — filtered before pagination so the client never stops
   * paging early on a short in-memory-filtered page.
   * @param criteria The stalled-query filter, threshold, and pagination criteria.
   * @return One display-field map per stalled instance on the requested page.
   */
  @AuraEnabled(cacheable=true)
  public static List<Map<String, Object>> getStalledInstances(
    StalledQuery criteria
  ) {
    return WorkflowStalledService.listStalled(criteria);
  }

  /**
   * @description Counts genuinely stalled instances for the given criteria, reporting a
   * capped flag when the candidate scan hit its governor-safety bound.
   * @param criteria The stalled-query filter and threshold (pagination ignored).
   * @return A map with the stalled count and a capped flag.
   */
  @AuraEnabled
  public static Map<String, Object> getStalledCount(StalledQuery criteria) {
    return WorkflowStalledService.countStalled(criteria);
  }

  /**
   * @description Rolls instances up into total / active / completed / failed counts for
   * the summary tiles; reuses InstanceQuery but reads only the filter fields.
   * @param criteria The filter criteria (pagination and failureCategory ignored).
   * @return A map of the total, active, completed, and failed counts.
   */
  @AuraEnabled
  public static Map<String, Integer> getWorkflowStats(InstanceQuery criteria) {
    return WorkflowInstanceListService.rollupStats(criteria);
  }

  /**
   * @description Per-definition success-rate and throughput over a selectable recent
   * window, sorted worst-first.
   * @param windowKey one of '1h' | '24h' | '7d' (blank/unknown → 24h).
   * @return A map with the resolved window and the per-definition trend rows.
   */
  @AuraEnabled
  public static Map<String, Object> getDefinitionTrends(String windowKey) {
    return WorkflowTrendService.computeTrends(windowKey);
  }

  /**
   * @description Loads the full detail view for one instance: the record, its steps,
   * children, successor, search attributes, breadcrumb log, pending compensations, and
   * resolved payload download descriptors.
   * @param instanceId The workflow instance to load details for.
   * @return A map of the instance detail sections consumed by the detail LWC.
   */
  @AuraEnabled
  public static Map<String, Object> getInstanceDetails(Id instanceId) {
    return WorkflowInstanceDetailService.loadDetails(instanceId);
  }

  /**
   * @description Returns the discoverable WorkflowDefinition class names for the dashboard,
   * after enforcing the Workflow_Admin authorization gate.
   * @return The sorted list of concrete WorkflowDefinition class names.
   */
  @AuraEnabled(cacheable=true)
  public static List<String> getDefinitions() {
    return WorkflowDefinitionDiscoveryService.discoverChecked();
  }

  /**
   * @description Returns the read-only Workflow Catalog: one row per concrete, startable
   * definition the engine discovers, each carrying its class name, a human-readable label,
   * a description (or "undocumented" marker), the current declared version for
   * VersionedWorkflow implementations, and an active/failed/suspended health rollup.
   * @return One catalog row map per discovered definition, sorted by class name.
   */
  @AuraEnabled(cacheable=true)
  public static List<Map<String, Object>> getWorkflowCatalog() {
    return WorkflowCatalogService.buildCatalog();
  }

  /**
   * @description Returns a per-Definition_Version__c drain view for the given workflow
   * name: non-terminal, failed (re-drivable), and clean-terminal counts plus a
   * safeToRetire flag per observed version.
   * @param workflowName The workflow definition name to build the drain view for.
   * @return One drain-bucket map per observed definition version, or an empty list.
   */
  @AuraEnabled
  public static List<Map<String, Object>> getVersionDrain(String workflowName) {
    return WorkflowVersionDrainService.buildDrainView(workflowName);
  }

  /**
   * @description Returns a page of unrouted (unmatched) signals with a computed age, so
   * operators can inspect and redeliver signals that found no target instance.
   * @param criteria The search and pagination criteria.
   * @return One display map per unrouted signal on the requested page, oldest first.
   */
  @AuraEnabled(cacheable=true)
  public static List<Map<String, Object>> getUnroutedSignals(
    UnroutedQuery criteria
  ) {
    return WorkflowSignalReadService.listUnrouted(criteria);
  }

  /**
   * @description Counts unrouted signals matching the search term, reporting a capped flag
   * when the candidate scan hit its governor-safety bound.
   * @param searchTerm The free-text search term over key/name, or blank for all.
   * @return A map with the unrouted-signal count and a capped flag.
   */
  @AuraEnabled
  public static Map<String, Object> getUnroutedSignalCount(String searchTerm) {
    return WorkflowSignalReadService.countUnrouted(searchTerm);
  }

  /**
   * @description Returns the watchdog/scheduler health snapshot for the dashboard.
   * @return A map of the watchdog status fields consumed by the status panel.
   */
  @AuraEnabled
  public static Map<String, Object> getWatchdogStatus() {
    return WorkflowDashboardStatusService.watchdogStatus();
  }

  /**
   * @description Returns Revenant's data-storage footprint for the System Doctor panel:
   * per-object record counts, estimated bytes and 7-/30-day growth deltas, the summed
   * ContentVersion byte volume of offloaded payloads, and the combined estimate as a
   * percentage of the org's data-storage allowance with the configured warning threshold.
   * Strictly read-only (bounded aggregate reads only).
   *
   * Intentionally NOT cacheable: this backs a LIVE storage-warning surface whose metrics
   * change as records are created, offloaded, or purged (e.g. CleanupWorkflow). A
   * client-side Lightning cache would serve a stale footprint for a platform-managed
   * duration on panel reopen, defeating the panel's purpose. Loaded imperatively by the LWC.
   * @return A map of the storage-footprint fields consumed by the panel.
   */
  @AuraEnabled
  public static Map<String, Object> getStorageFootprint() {
    return WorkflowStorageFootprintService.storageFootprint();
  }

  /**
   * @description Returns a list of currently paused definitions with parked-instance
   * counts.
   * @return One map per paused definition, or an empty list when none are paused.
   */
  @AuraEnabled
  public static List<Map<String, Object>> getPausedDefinitions() {
    return WorkflowDashboardStatusService.pausedDefinitions();
  }

  /**
   * @description Returns the concurrency-limit picture for each governed workflow.
   * @return One concurrency-status map per governed workflow, or an empty list.
   */
  @AuraEnabled
  public static List<Map<String, Object>> getConcurrencyStatus() {
    return WorkflowDashboardStatusService.concurrencyStatus();
  }

  /**
   * @description Returns a per-step failure breakdown for a workflow over the given time
   * window, capped at a governor-safe scan bound with an isCapped flag.
   * @param workflowName The workflow definition name to analyze.
   * @param timeWindow The window key selecting how far back to scan.
   * @return A map with the window, cap metadata, total failures, and per-step groups.
   */
  @AuraEnabled
  public static Map<String, Object> getWorkflowFailureBreakdown(
    String workflowName,
    String timeWindow
  ) {
    return WorkflowFailureBreakdownService.breakdown(workflowName, timeWindow);
  }

  /**
   * @description Returns end-to-end instance-duration percentiles (p50/p95/p99/max) and a
   * median-wall-clock step ranking for a workflow definition over the given window, computed
   * from a governor-bounded sample with an isCapped flag when the sample is truncated.
   * Strictly read-only (Terminal_At__c and step CreatedDate are read, never written).
   * Intentionally NON-cacheable: these are live metrics that change as instances terminate
   * and as the time window advances, so a Lightning Data Service cache keyed on
   * (workflowName, windowKey) would serve stale percentiles/step rankings on Refresh. The LWC
   * calls this imperatively; matches the non-cacheable sibling getWorkflowFailureBreakdown.
   * @param workflowName The workflow definition name to analyze.
   * @param windowKey The window key ('1h' | '24h' | '7d'; blank/unknown → all time).
   * @return A map with the window, cap metadata/isCapped flag, sample size, the p50/p95/p99/max
   *         duration milliseconds, and the per-step median ranking rows.
   */
  @AuraEnabled
  public static Map<String, Object> getDefinitionLatency(
    String workflowName,
    String windowKey
  ) {
    return WorkflowLatencyService.definitionLatency(workflowName, windowKey);
  }

  /**
   * @description Exact count of failed instances that a "Re-drive matching" action would
   * re-enqueue for the operator's current filter.
   * @param workflowName The workflow name filter, or null for all.
   * @param status The status filter, or null for all.
   * @param searchTerm The free-text search term, or null for none.
   * @return The number of re-drive-eligible instances matching the filter.
   */
  @AuraEnabled
  public static Integer getRedriveEligibleCount(
    String workflowName,
    String status,
    String searchTerm
  ) {
    return WorkflowBulkCommandService.countRedriveEligible(
      workflowName,
      status,
      searchTerm
    );
  }

  /**
   * @description Exact count of active/stalled instances that a "Cancel matching" action
   * would cancel/rollback for the operator's current filter.
   * @param workflowName The workflow name filter, or null for all.
   * @param status The status filter, or null for all.
   * @param searchTerm The free-text search term, or null for none.
   * @return The number of cancel-eligible instances matching the filter.
   */
  @AuraEnabled
  public static Integer getCancelEligibleCount(
    String workflowName,
    String status,
    String searchTerm
  ) {
    return WorkflowBulkCommandService.countCancelEligible(
      workflowName,
      status,
      searchTerm
    );
  }
}
