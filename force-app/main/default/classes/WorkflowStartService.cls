/**
 * @description Public start / get-or-start facade for {@link WorkflowEngine}.
 * Exposes the start entry points the engine and its callers invoke (scalar
 * get-or-start, bulk get-or-start, debounced and singleton starts) and the
 * shared DUPLICATE_VALUE predicate, delegating the exactly-once work to the
 * cohesive start classes: the scalar admission sequence (INV-1) to
 * {@link WorkflowScalarStartService}, the bulk pipeline (INV-3) to
 * {@link WorkflowBulkStartService}, and the dedup query engine (INV-2) to
 * {@link WorkflowStartDedup}. This class holds no admission logic itself so its
 * public surface stays stable for existing callers.
 */
public inherited sharing class WorkflowStartService {
  /**
   * @description Get-or-start facade target: get-or-start a workflow instance and
   * return its Id. Delegates to the scalar admission pipeline.
   * @param workflowName developer name of the workflow definition to start
   * @param correlationKey dedup/correlation key for the instance
   * @param input start input payload passed to the first step
   * @return Id of the new or deduplicated existing instance
   */
  public static Id startOne(
    String workflowName,
    String correlationKey,
    Object input
  ) {
    return WorkflowScalarStartService.doStartGetOrStart(
        new WorkflowEngine.StartRequest(workflowName, correlationKey, input)
      )
      .instanceId;
  }

  /**
   * @description Get-or-start facade target from a fully-built request.
   * @param request the start request describing the instance to get-or-start
   * @return Id of the new or deduplicated existing instance
   */
  public static Id startOne(WorkflowEngine.StartRequest request) {
    return WorkflowScalarStartService.doStartGetOrStart(request).instanceId;
  }

  /**
   * @description startOrGet facade target: get-or-start a workflow instance and
   * report whether it was newly created.
   * @param workflowName developer name of the workflow definition to start
   * @param correlationKey dedup/correlation key for the instance
   * @param input start input payload passed to the first step
   * @return a StartResult carrying the instance Id and whether it was newly created
   */
  public static WorkflowEngine.StartResult startOrGetOne(
    String workflowName,
    String correlationKey,
    Object input
  ) {
    return WorkflowScalarStartService.doStartGetOrStart(
      new WorkflowEngine.StartRequest(workflowName, correlationKey, input)
    );
  }

  /**
   * @description startOrGet facade target from a fully-built request.
   * @param request the start request describing the instance to get-or-start
   * @return a StartResult carrying the instance Id and whether it was newly created
   */
  public static WorkflowEngine.StartResult startOrGetOne(
    WorkflowEngine.StartRequest request
  ) {
    return WorkflowScalarStartService.doStartGetOrStart(request);
  }

  /**
   * @description Bulk start facade target: start multiple instances and return
   * their Ids index-aligned with the requests.
   * @param requests the start requests to process
   * @return instance Ids index-aligned with requests (null per null request)
   */
  public static List<Id> startBulk(List<WorkflowEngine.StartRequest> requests) {
    List<Id> ids = new List<Id>();
    for (WorkflowEngine.StartResult r : startOrGetBulk(requests)) {
      ids.add(r == null ? null : r.instanceId);
    }
    return ids;
  }

  /**
   * Active-only get-or-start for engine-internal singleton workflows (e.g. the
   * watchdog). Never dedups against terminal instances, so a failed or
   * continued-as-new singleton is always restarted rather than resolving to a
   * dead terminal run within the dedup window.
   * @param workflowName developer name of the singleton workflow definition
   * @param correlationKey dedup/correlation key for the singleton
   * @param input start input payload passed to the first step
   * @return Id of the active instance (existing if one is live, otherwise newly created)
   */
  public static Id startSingleton(
    String workflowName,
    String correlationKey,
    Object input
  ) {
    return WorkflowScalarStartService.doStartSingleton(
        new WorkflowEngine.StartRequest(workflowName, correlationKey, input)
      )
      .instanceId;
  }

  /**
   * Arms a durable trailing-edge debounce timer for starting a workflow. Build
   * the request with workflowName, correlationKey, inputJson and debounceSeconds
   * (and optionally maxWaitSeconds, attributesJson and causationId). Replaces the
   * former positional startDebounced overloads.
   * @param request the debounce request describing the coalesced start
   */
  public static void startDebounced(WorkflowDebouncer.DebounceRequest request) {
    WorkflowDebouncer.startDebounced(
      new List<WorkflowDebouncer.DebounceRequest>{ request }
    );
  }

  /**
   * @description Bulk get-or-start pipeline (facade target for {@link
   * WorkflowEngine}). Returns a result per request (index-aligned) reporting the
   * resolved instance Id and whether it was newly created or deduped. Delegates
   * to {@link WorkflowBulkStartService}.
   * @param requests the start requests to process
   * @return StartResults index-aligned with requests (null per null request)
   */
  public static List<WorkflowEngine.StartResult> startOrGetBulk(
    List<WorkflowEngine.StartRequest> requests
  ) {
    return WorkflowBulkStartService.startOrGetBulk(requests);
  }

  /**
   * @description True when every error on the save result is a DUPLICATE_VALUE.
   * Public so the bulk start pipeline and the signal claim/consume paths on
   * {@link WorkflowEngine} share one duplicate-detection predicate.
   * @param sr the DML save result to classify
   * @return true when every error on the result is a DUPLICATE_VALUE
   */
  public static Boolean isDuplicateSaveError(Database.SaveResult sr) {
    for (Database.Error err : sr.getErrors()) {
      if (err.getStatusCode() == StatusCode.DUPLICATE_VALUE) {
        return true;
      }
    }
    return false;
  }
}
