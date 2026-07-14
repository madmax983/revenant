/**
 * Read-only Invocable Action that returns a Revenant durable workflow instance's
 * current status, output, and failure detail to Salesforce Flow.
 *
 * It is strictly read-only: it performs no status transition, enqueue, signal,
 * schedule, or DML. It reuses the engine's payload offload convention so that an
 * offloaded (>100k) output is rehydrated to the full payload an Apex caller would
 * observe, and it follows ContinuedAsNew chains so a lookup by correlation key
 * reports the live/terminal successor rather than a stale predecessor.
 */
public inherited sharing class WorkflowStatusInvocableAction {
  // Statuses that represent a finished workflow. ContinuedAsNew is deliberately
  // excluded: it is a hand-off, not a terminal outcome, so the action resolves it
  // forward to a successor rather than reporting it as terminal.
  private static final Set<String> TERMINAL_STATUSES = new Set<String>{
    'Completed',
    'Failed',
    'Compensated',
    'Cancelled'
  };

  /**
   * @description Invocable request identifying the workflow instance to read, by either its
   * record Id or its correlation key.
   */
  public class StatusRequest {
    @InvocableVariable(
      label='Correlation Key or Workflow Instance ID'
      description='Either a Workflow Instance record Id or a Correlation Key identifying the workflow to read.'
      required=true
    )
    public String workflowKeyOrId;
  }

  /**
   * @description Invocable response reporting a workflow instance's resolved status, output,
   * progress, and failure detail, with payloads rehydrated from offloaded storage.
   */
  public class StatusResult {
    @InvocableVariable(
      label='Found'
      description='False when no workflow instance matched the supplied key or Id.'
    )
    public Boolean found;

    @InvocableVariable(
      label='Workflow Instance ID'
      description='The resolved current instance Id, following any ContinuedAsNew chain.'
    )
    public Id workflowInstanceId;

    @InvocableVariable(
      label='Status'
      description='The workflow instance Status value (e.g. Running, Completed, Failed).'
    )
    public String status;

    @InvocableVariable(
      label='Is Terminal'
      description='True when the workflow has finished (Completed, Failed, Compensated, or Cancelled).'
    )
    public Boolean isTerminal;

    @InvocableVariable(
      label='Is Success'
      description='True only when the workflow finished successfully (Completed).'
    )
    public Boolean isSuccess;

    @InvocableVariable(
      label='Output JSON'
      description='The workflow output, fully rehydrated from offloaded storage when applicable.'
    )
    public String outputJson;

    @InvocableVariable(
      label='Error Message'
      description='Failure detail sourced from the workflow Error Message field.'
    )
    public String errorMessage;

    @InvocableVariable(
      label='Progress JSON'
      description='The workflow progress snapshot, fully rehydrated from offloaded storage when applicable.'
    )
    public String progressJson;

    @InvocableVariable(
      label='Causation ID'
      description='Causation or trace identifier linking this instance to the upstream instance/event.'
    )
    public String causationId;

    /**
     * @description Initializes the result to a not-found, non-terminal, non-success state.
     */
    public StatusResult() {
      this.found = false;
      this.isTerminal = false;
      this.isSuccess = false;
    }
  }

  // Per-request lookup buckets: the parsed Id (or null) and raw key kept in request
  // order, plus the de-duplicated Id/key sets for the single bulk query.
  private class LookupBuckets {
    List<Id> reqIds = new List<Id>();
    List<String> reqKeys = new List<String>();
    Set<Id> lookupIds = new Set<Id>();
    Set<String> lookupKeys = new Set<String>();
  }

  @InvocableMethod(
    label='Get Workflow Status'
    category='Revenant Workflows'
    description='Reads a Revenant durable workflow instance current status, output, and failure detail (read-only).'
  )
  /**
   * @description Bulk, read-only lookup that resolves each request to its current workflow
   * instance (following ContinuedAsNew chains), rehydrates offloaded payloads, and returns
   * one correspondingly-ordered status result per request.
   * @param requests The status requests to resolve; null or empty yields an empty list.
   * @return A StatusResult per input request, in the same order.
   */
  public static List<StatusResult> getStatus(List<StatusRequest> requests) {
    if (requests == null || requests.isEmpty()) {
      return new List<StatusResult>();
    }

    // 1. Bucket each raw input into an Id lookup and/or a Correlation Key lookup.
    LookupBuckets buckets = bucketRequests(requests);

    // 2. One bulk query for all direct matches, in any status (terminal included).
    WorkflowStatusChainResolver.MatchIndex index = loadDirectMatches(buckets);

    // 3. Resolve a starting instance per request, then forward-walk ContinuedAsNew.
    List<Workflow_Instance__c> resolved = WorkflowStatusChainResolver.resolveStartingInstances(
      buckets.reqIds,
      buckets.reqKeys,
      index
    );

    // 4. Bulk-resolve offloaded output/progress payloads.
    Map<Id, String> dataByAttachment = WorkflowStatusPayloadRehydrator.loadOffloadedPayloads(
      resolved
    );

    // 5. Assemble correspondingly-ordered results.
    return assembleResults(resolved, dataByAttachment);
  }

  /**
   * Buckets each raw input into an Id lookup and/or a Correlation Key lookup, kept in
   * request order. An id-shaped value is also retained as a key fallback in case a
   * caller used a correlation key that happens to look like an Id.
   *
   * @param requests The raw status requests to bucket, kept in order.
   * @return The populated lookup buckets holding per-request and de-duplicated Ids and keys.
   */
  private static LookupBuckets bucketRequests(List<StatusRequest> requests) {
    String wflowPrefix = Workflow_Instance__c.SObjectType.getDescribe(
        SObjectDescribeOptions.DEFERRED
      )
      .getKeyPrefix();
    Pattern idPattern = Pattern.compile('^[a-zA-Z0-9]{15}([a-zA-Z0-9]{3})?$');

    LookupBuckets buckets = new LookupBuckets();
    for (StatusRequest req : requests) {
      String raw = (req == null) ? null : req.workflowKeyOrId;
      Id parsedId = parseInstanceId(raw, wflowPrefix, idPattern);
      buckets.reqIds.add(parsedId);
      if (parsedId != null) {
        buckets.lookupIds.add(parsedId);
      }
      if (String.isNotBlank(raw)) {
        buckets.reqKeys.add(raw);
        buckets.lookupKeys.add(raw);
      } else {
        buckets.reqKeys.add(null);
      }
    }
    return buckets;
  }

  /**
   * @description Parses an id-shaped, correctly-prefixed raw value into an Id.
   * @param raw The raw request value to interpret.
   * @param wflowPrefix The 3-character key prefix for Workflow_Instance__c.
   * @param idPattern The compiled pattern matching 15- or 18-character Salesforce Ids.
   * @return The parsed instance Id, or null when the value is not a valid instance Id.
   */
  private static Id parseInstanceId(
    String raw,
    String wflowPrefix,
    Pattern idPattern
  ) {
    if (raw == null) {
      return null;
    }
    if (
      String.isNotBlank(raw) &&
      idPattern.matcher(raw).matches() &&
      raw.startsWith(wflowPrefix)
    ) {
      try {
        return (Id) raw;
      } catch (Exception ex) {
        // Malformed Id (e.g. bad checksum): fall back to a key lookup.
        return null;
      }
    }
    return null;
  }

  /**
   * @description Runs a single bulk query for all direct matches, in any status (terminal
   * included), and indexes them by Id and by preferred correlation key.
   * @param buckets The lookup buckets supplying the de-duplicated Id and key sets to query.
   * @return A match index of instances keyed by Id and by correlation key.
   */
  private static WorkflowStatusChainResolver.MatchIndex loadDirectMatches(
    LookupBuckets buckets
  ) {
    WorkflowStatusChainResolver.MatchIndex index = new WorkflowStatusChainResolver.MatchIndex();
    if (buckets.lookupIds.isEmpty() && buckets.lookupKeys.isEmpty()) {
      return index;
    }
    for (Workflow_Instance__c inst : [
      SELECT
        Id,
        Status__c,
        Output__c,
        Error_Message__c,
        Correlation_Key__c,
        Previous_Instance__c,
        CreatedDate,
        Progress__c,
        Causation_Id__c
      FROM Workflow_Instance__c
      WHERE
        Id IN :buckets.lookupIds
        OR Correlation_Key__c IN :buckets.lookupKeys
      WITH SYSTEM_MODE
    ]) {
      index.byId.put(inst.Id, inst);
      mergeByKey(inst, index.byKey);
    }
    return index;
  }

  /**
   * Adds an instance to the by-key index, preferring the live run. Correlation_Key__c
   * is not unique: a key can be reused after a run goes terminal, and a ContinuedAsNew
   * hand-off can reuse a custom key. When a key maps to several rows, prefer the live
   * run (active status), then the most recent, so we report the current run.
   *
   * @param inst The instance to consider adding to the by-key index.
   * @param byKey The correlation-key index to update in place.
   */
  private static void mergeByKey(
    Workflow_Instance__c inst,
    Map<String, Workflow_Instance__c> byKey
  ) {
    if (String.isBlank(inst.Correlation_Key__c)) {
      return;
    }
    Workflow_Instance__c existing = byKey.get(inst.Correlation_Key__c);
    if (
      existing == null ||
      WorkflowStatusChainResolver.isPreferredCandidate(inst, existing)
    ) {
      byKey.put(inst.Correlation_Key__c, inst);
    }
  }

  /**
   * @description Builds the correspondingly-ordered StatusResult list from resolved
   * instances, rehydrating offloaded output and progress payloads.
   * @param resolved The resolved instances, one per request in order (null where unmatched).
   * @param dataByAttachment The map of offload attachment Ids to rehydrated payload text.
   * @return One StatusResult per resolved instance, in the same order.
   */
  private static List<StatusResult> assembleResults(
    List<Workflow_Instance__c> resolved,
    Map<Id, String> dataByAttachment
  ) {
    List<StatusResult> results = new List<StatusResult>();
    for (Workflow_Instance__c inst : resolved) {
      StatusResult res = new StatusResult();
      if (inst != null) {
        res.found = true;
        res.workflowInstanceId = inst.Id;
        res.status = inst.Status__c;
        res.isTerminal = TERMINAL_STATUSES.contains(inst.Status__c);
        res.isSuccess = (inst.Status__c == 'Completed');
        res.errorMessage = inst.Error_Message__c;
        res.outputJson = WorkflowStatusPayloadRehydrator.rehydrate(
          inst.Output__c,
          dataByAttachment
        );
        res.progressJson = WorkflowStatusPayloadRehydrator.rehydrate(
          inst.Progress__c,
          dataByAttachment
        );
        res.causationId = WorkflowCausationParser.cleanCausationId(
          inst.Causation_Id__c
        );
      }
      results.add(res);
    }
    return results;
  }
}
