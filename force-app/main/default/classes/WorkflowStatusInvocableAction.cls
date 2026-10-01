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
global inherited sharing class WorkflowStatusInvocableAction {
  /**
   * @description Blocks construction outside this class. Without an explicit
   * constructor, a global class gets a default constructor that subscribers
   * can call (issue #122).
   */
  private WorkflowStatusInvocableAction() {
    // No state to set.
  }

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
  global class StatusRequest {
    @InvocableVariable(
      label='Correlation Key or Workflow Instance ID'
      description='Either a Workflow Instance record Id or a Correlation Key identifying the workflow to read.'
      required=true
    )
    global String workflowKeyOrId;
  }

  /**
   * @description Invocable response reporting a workflow instance's resolved status, output,
   * progress, and failure detail, with payloads rehydrated from offloaded storage.
   */
  global class StatusResult {
    @InvocableVariable(
      label='Found'
      description='False when no workflow instance matched the supplied key or Id.'
    )
    global Boolean found;

    @InvocableVariable(
      label='Workflow Instance ID'
      description='The resolved current instance Id, following any ContinuedAsNew chain.'
    )
    global Id workflowInstanceId;

    @InvocableVariable(
      label='Status'
      description='The workflow instance Status value (e.g. Running, Completed, Failed).'
    )
    global String status;

    @InvocableVariable(
      label='Is Terminal'
      description='True when the workflow has finished (Completed, Failed, Compensated, or Cancelled).'
    )
    global Boolean isTerminal;

    @InvocableVariable(
      label='Is Success'
      description='True only when the workflow finished successfully (Completed).'
    )
    global Boolean isSuccess;

    @InvocableVariable(
      label='Output JSON'
      description='The workflow output, fully rehydrated from offloaded storage when applicable.'
    )
    global String outputJson;

    @InvocableVariable(
      label='Error Message'
      description='Failure detail sourced from the workflow Error Message field.'
    )
    global String errorMessage;

    @InvocableVariable(
      label='Progress JSON'
      description='The workflow progress snapshot, fully rehydrated from offloaded storage when applicable.'
    )
    global String progressJson;

    @InvocableVariable(
      label='Causation ID'
      description='Causation or trace identifier linking this instance to the upstream instance/event.'
    )
    global String causationId;

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
  global static List<StatusResult> getStatus(List<StatusRequest> requests) {
    if (requests == null || requests.isEmpty()) {
      return new List<StatusResult>();
    }

    List<String> keysOrIds = new List<String>();
    for (StatusRequest req : requests) {
      keysOrIds.add((req == null) ? null : req.workflowKeyOrId);
    }

    // 1-3. Resolve each request to its current instance (identity fields only).
    List<Workflow_Instance__c> resolved = loadPayloadFields(
      resolveInstances(keysOrIds)
    );

    // 4. Bulk-resolve offloaded output/progress payloads.
    Map<String, String> dataByAttachment = WorkflowStatusPayloadRehydrator.loadOffloadedPayloads(
      resolved
    );

    // 5. Assemble correspondingly-ordered results.
    return assembleResults(resolved, dataByAttachment);
  }

  /**
   * @description Resolves each value (instance Id or correlation key) to its current
   * instance. An Id reads that exact instance. A key selects the live, then the
   * latest, instance and follows the ContinuedAsNew chain. Read-only and bulk-safe.
   * Shared with the Cancel Workflow action (issue #107). Loads identity fields only
   * (Id, Status__c, Correlation_Key__c, Previous_Instance__c), not the payloads.
   * @param keysOrIds The instance Ids or correlation keys, in order (null items allowed).
   * @return One instance per value, in the same order (null where no match); empty for null input.
   */
  public static List<Workflow_Instance__c> resolveInstances(
    List<String> keysOrIds
  ) {
    if (keysOrIds == null || keysOrIds.isEmpty()) {
      return new List<Workflow_Instance__c>();
    }
    // 1. Bucket each raw input into an Id lookup and/or a Correlation Key lookup.
    LookupBuckets buckets = bucketRequests(keysOrIds);

    // 2. One bulk query for all direct matches, in any status (terminal included).
    WorkflowStatusChainResolver.MatchIndex index = loadDirectMatches(buckets);

    // 3. Resolve a starting instance per request, then forward-walk ContinuedAsNew.
    return WorkflowStatusChainResolver.resolveStartingInstances(
      buckets.reqIds,
      buckets.reqKeys,
      index
    );
  }

  /**
   * Buckets each raw input into an Id lookup and/or a Correlation Key lookup, kept in
   * request order. An id-shaped value is also retained as a key fallback in case a
   * caller used a correlation key that happens to look like an Id.
   *
   * @param keysOrIds The raw instance Ids or correlation keys to bucket, kept in order.
   * @return The populated lookup buckets holding per-request and de-duplicated Ids and keys.
   */
  private static LookupBuckets bucketRequests(List<String> keysOrIds) {
    String wflowPrefix = Workflow_Instance__c.SObjectType.getDescribe(
        SObjectDescribeOptions.DEFERRED
      )
      .getKeyPrefix();
    Pattern idPattern = Pattern.compile('^[a-zA-Z0-9]{15}([a-zA-Z0-9]{3})?$');

    LookupBuckets buckets = new LookupBuckets();
    for (String raw : keysOrIds) {
      Id parsedId = parseInstanceId(raw, wflowPrefix, idPattern);
      buckets.reqIds.add(parsedId);
      if (parsedId != null) {
        buckets.lookupIds.add(parsedId);
      }
      if (String.isNotBlank(raw)) {
        // Correlation_Key__c matches case-insensitively; Apex maps do not.
        buckets.reqKeys.add(WorkflowKeys.normalizeKey(raw));
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
   * @description Replaces each resolved instance with a copy that holds the payload
   * and failure fields, in one query. The lookup loads identity fields only, so a
   * key with many past runs does not load their payloads.
   * @param resolved The resolved instance per request (null where unmatched).
   * @return The same list, with payload fields loaded.
   */
  private static List<Workflow_Instance__c> loadPayloadFields(
    List<Workflow_Instance__c> resolved
  ) {
    Set<Id> ids = new Set<Id>();
    for (Workflow_Instance__c inst : resolved) {
      if (inst != null) {
        ids.add(inst.Id);
      }
    }
    if (ids.isEmpty()) {
      return resolved;
    }
    Map<Id, Workflow_Instance__c> full = new Map<Id, Workflow_Instance__c>(
      [
        SELECT
          Id,
          Status__c,
          Output__c,
          Error_Message__c,
          Progress__c,
          Causation_Id__c
        FROM Workflow_Instance__c
        WHERE Id IN :ids
        WITH SYSTEM_MODE
      ]
    );
    for (Integer i = 0; i < resolved.size(); i++) {
      if (resolved[i] != null && full.containsKey(resolved[i].Id)) {
        resolved[i] = full.get(resolved[i].Id);
      }
    }
    return resolved;
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
        Correlation_Key__c,
        Previous_Instance__c,
        CreatedDate
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
    String key = WorkflowKeys.normalizeKey(inst.Correlation_Key__c);
    Workflow_Instance__c existing = byKey.get(key);
    if (
      existing == null ||
      WorkflowStatusChainResolver.isPreferredCandidate(inst, existing)
    ) {
      byKey.put(key, inst);
    }
  }

  /**
   * @description Builds the correspondingly-ordered StatusResult list from resolved
   * instances, rehydrating offloaded output and progress payloads.
   * @param resolved The resolved instances, one per request in order (null where unmatched).
   * @param dataByAttachment The owned file text, keyed by WorkflowPayloadOffload.ownedKey.
   * @return One StatusResult per resolved instance, in the same order.
   */
  private static List<StatusResult> assembleResults(
    List<Workflow_Instance__c> resolved,
    Map<String, String> dataByAttachment
  ) {
    // The gate redacts encoded payloads of instances that the user cannot read
    // (issue #243).
    List<StatusResult> results = new List<StatusResult>();
    Set<Id> ids = new Set<Id>();
    for (Workflow_Instance__c inst : resolved) {
      if (inst != null) {
        ids.add(inst.Id);
      }
    }
    WorkflowPayloadAccess.Gate gate = new WorkflowPayloadAccess.Gate(ids);
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
          inst.Id,
          dataByAttachment,
          gate
        );
        res.progressJson = WorkflowStatusPayloadRehydrator.rehydrate(
          inst.Progress__c,
          inst.Id,
          dataByAttachment,
          gate
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
