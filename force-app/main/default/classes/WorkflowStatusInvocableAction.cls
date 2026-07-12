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

  // Statuses representing a workflow that is still live (not finished and not a
  // ContinuedAsNew hand-off). Used to prefer the current run when a non-unique
  // correlation key maps to several instances.
  private static final Set<String> ACTIVE_STATUSES = new Set<String>{
    'Pending',
    'Running',
    'Suspended',
    'Compensating',
    'Cancelling'
  };

  // Upper bound on ContinuedAsNew links walked forward, bounding SOQL usage so a
  // pathological/cyclic chain cannot exhaust query governor limits.
  @TestVisible
  private static Integer maxChainDepth = 50;

  private static final String OFFLOAD_MARKER_PREFIX = '{"$attachmentId":';

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

  // Direct-match index from the bulk query: by Id and by (preferred) correlation key.
  private class MatchIndex {
    Map<Id, Workflow_Instance__c> byId = new Map<Id, Workflow_Instance__c>();
    Map<String, Workflow_Instance__c> byKey = new Map<String, Workflow_Instance__c>();
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
    MatchIndex index = loadDirectMatches(buckets);

    // 3. Resolve a starting instance per request, then forward-walk ContinuedAsNew.
    List<Workflow_Instance__c> resolved = resolveStartingInstances(
      requests,
      buckets,
      index
    );

    // 4. Bulk-resolve offloaded output/progress payloads.
    Map<Id, String> dataByAttachment = loadOffloadedPayloads(resolved);

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
  private static MatchIndex loadDirectMatches(LookupBuckets buckets) {
    MatchIndex index = new MatchIndex();
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
    if (existing == null || isPreferredCandidate(inst, existing)) {
      byKey.put(inst.Correlation_Key__c, inst);
    }
  }

  /**
   * Resolves a starting instance per request (Id matches are precise handles; key
   * matches are walked forward through ContinuedAsNew) and returns the per-request
   * list after the chain walk, correspondingly ordered.
   *
   * @param requests The status requests, used only for their count and order.
   * @param buckets The lookup buckets holding the per-request parsed Ids and keys.
   * @param index The direct-match index to resolve each request against.
   * @return The per-request resolved instances (null where unmatched), after the chain walk.
   */
  private static List<Workflow_Instance__c> resolveStartingInstances(
    List<StatusRequest> requests,
    LookupBuckets buckets,
    MatchIndex index
  ) {
    List<Workflow_Instance__c> resolved = new List<Workflow_Instance__c>();
    List<Boolean> walkChain = new List<Boolean>();
    for (Integer i = 0; i < requests.size(); i++) {
      Workflow_Instance__c match = null;
      Boolean byKey = false;
      if (buckets.reqIds[i] != null) {
        match = index.byId.get(buckets.reqIds[i]);
      }
      if (match == null && buckets.reqKeys[i] != null) {
        match = index.byKey.get(buckets.reqKeys[i]);
        byKey = (match != null);
      }
      resolved.add(match);
      walkChain.add(byKey);
    }
    walkContinuedAsNewChains(resolved, walkChain);
    return resolved;
  }

  /**
   * Forward-walks ContinuedAsNew chains for key-resolved requests whose start instance
   * is still a predecessor. Same-key chains are already resolved to the live generation
   * by the active/latest preference; this walk covers chains whose successor took a
   * different key (e.g. the default `_runN` scheme). Bulk-safe: one SOQL per chain
   * generation, never per row. Bounded by maxChainDepth because SOQL limits make an
   * unbounded link-by-link walk impossible; if a (typically perpetual, different-key)
   * chain exceeds the bound we stop on the furthest generation reached, which is still
   * a ContinuedAsNew row and is therefore reported as non-terminal / non-success --
   * never as a false completed outcome.
   *
   * @param resolved The per-request resolved instances, advanced in place to successors.
   * @param walkChain Per-request flags marking which requests should be forward-walked.
   */
  private static void walkContinuedAsNewChains(
    List<Workflow_Instance__c> resolved,
    List<Boolean> walkChain
  ) {
    for (Integer depth = 0; depth < maxChainDepth; depth++) {
      if (!advanceChainGeneration(resolved, walkChain)) {
        break;
      }
    }
  }

  /**
   * Advances every still-predecessor request by one ContinuedAsNew generation using a
   * single query. Returns false when there is nothing left to advance (no predecessors
   * remain, or no successor was found), signalling the walk to stop.
   *
   * @param resolved The per-request resolved instances, advanced in place to successors.
   * @param walkChain Per-request flags marking which requests should be forward-walked.
   * @return True if any request advanced a generation, false when nothing remains to advance.
   */
  private static Boolean advanceChainGeneration(
    List<Workflow_Instance__c> resolved,
    List<Boolean> walkChain
  ) {
    Set<Id> predecessorIds = collectPredecessors(resolved, walkChain);
    if (predecessorIds.isEmpty()) {
      return false;
    }
    Map<Id, Workflow_Instance__c> successorByPrev = querySuccessors(
      predecessorIds
    );
    return applySuccessors(resolved, walkChain, successorByPrev);
  }

  /**
   * @description Collects the Ids of requests still sitting on a ContinuedAsNew predecessor.
   * @param resolved The per-request resolved instances to inspect.
   * @param walkChain Per-request flags marking which requests should be forward-walked.
   * @return The set of predecessor instance Ids to advance in the next generation.
   */
  private static Set<Id> collectPredecessors(
    List<Workflow_Instance__c> resolved,
    List<Boolean> walkChain
  ) {
    Set<Id> predecessorIds = new Set<Id>();
    for (Integer i = 0; i < resolved.size(); i++) {
      Workflow_Instance__c cur = resolved[i];
      if (walkChain[i] && cur != null && cur.Status__c == 'ContinuedAsNew') {
        predecessorIds.add(cur.Id);
      }
    }
    return predecessorIds;
  }

  /**
   * @description Runs one bulk query mapping each predecessor Id to its ContinuedAsNew successor.
   * @param predecessorIds The predecessor instance Ids whose successors are being sought.
   * @return A map from each predecessor Id to its successor instance.
   */
  private static Map<Id, Workflow_Instance__c> querySuccessors(
    Set<Id> predecessorIds
  ) {
    Map<Id, Workflow_Instance__c> successorByPrev = new Map<Id, Workflow_Instance__c>();
    for (Workflow_Instance__c succ : [
      SELECT
        Id,
        Status__c,
        Output__c,
        Error_Message__c,
        Correlation_Key__c,
        Previous_Instance__c,
        Progress__c,
        Causation_Id__c
      FROM Workflow_Instance__c
      WHERE Previous_Instance__c IN :predecessorIds
      WITH SYSTEM_MODE
    ]) {
      successorByPrev.put(succ.Previous_Instance__c, succ);
    }
    return successorByPrev;
  }

  /**
   * Replaces each still-predecessor request with its successor where one exists.
   * Returns true if any request advanced.
   *
   * @param resolved The per-request resolved instances, updated in place to successors.
   * @param walkChain Per-request flags marking which requests should be forward-walked.
   * @param successorByPrev The predecessor-to-successor map from the current generation query.
   * @return True if any request was advanced to a successor, otherwise false.
   */
  private static Boolean applySuccessors(
    List<Workflow_Instance__c> resolved,
    List<Boolean> walkChain,
    Map<Id, Workflow_Instance__c> successorByPrev
  ) {
    Boolean advanced = false;
    for (Integer i = 0; i < resolved.size(); i++) {
      Workflow_Instance__c cur = resolved[i];
      if (walkChain[i] && cur != null && cur.Status__c == 'ContinuedAsNew') {
        Workflow_Instance__c succ = successorByPrev.get(cur.Id);
        if (succ != null) {
          resolved[i] = succ;
          advanced = true;
        }
      }
    }
    return advanced;
  }

  /**
   * Bulk-resolves offloaded output/progress payloads in a single ContentVersion query.
   * Honoring the contract that outputJson is the full rehydrated payload means large
   * (>100k) offloaded outputs are materialized in full, so a Flow batch that
   * simultaneously polls many instances whose outputs are all offloaded can approach
   * the Apex heap limit. We do not truncate (that would break the identical-to-Apex-
   * caller guarantee); callers polling many very large outputs at once should use
   * smaller Flow batch sizes.
   *
   * @param resolved The resolved instances whose offloaded output/progress payloads to load.
   * @return A map from each offload attachment (ContentDocument) Id to its payload text.
   */
  private static Map<Id, String> loadOffloadedPayloads(
    List<Workflow_Instance__c> resolved
  ) {
    Set<Id> attachmentIds = collectAttachmentIds(resolved);
    Map<Id, String> dataByAttachment = new Map<Id, String>();
    if (attachmentIds.isEmpty()) {
      return dataByAttachment;
    }
    for (ContentVersion cv : [
      SELECT ContentDocumentId, VersionData
      FROM ContentVersion
      WHERE ContentDocumentId IN :attachmentIds AND IsLatest = TRUE
      WITH SYSTEM_MODE
    ]) {
      if (cv.VersionData != null) {
        dataByAttachment.put(cv.ContentDocumentId, cv.VersionData.toString());
      }
    }
    return dataByAttachment;
  }

  /**
   * @description Gathers the offload attachment Ids referenced by any resolved instance's
   * output or progress fields.
   * @param resolved The resolved instances to scan for offload markers.
   * @return The set of referenced offload attachment (ContentDocument) Ids.
   */
  private static Set<Id> collectAttachmentIds(
    List<Workflow_Instance__c> resolved
  ) {
    Set<Id> attachmentIds = new Set<Id>();
    for (Workflow_Instance__c inst : resolved) {
      if (inst != null) {
        Id attachmentId = getAttachmentId(inst.Output__c);
        if (attachmentId != null) {
          attachmentIds.add(attachmentId);
        }
        Id progressAttachmentId = getAttachmentId(inst.Progress__c);
        if (progressAttachmentId != null) {
          attachmentIds.add(progressAttachmentId);
        }
      }
    }
    return attachmentIds;
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
        res.outputJson = rehydrate(inst.Output__c, dataByAttachment);
        res.progressJson = rehydrate(inst.Progress__c, dataByAttachment);
        res.causationId = WorkflowEngine.cleanCausationId(inst.Causation_Id__c);
      }
      results.add(res);
    }
    return results;
  }

  /**
   * Chooses the better of two instances sharing a correlation key: a live (active)
   * run wins over a finished/handed-off one; among equals, the most recently
   * created wins. This keeps getStatus reporting the current run when a key has
   * been reused across terminal runs or ContinuedAsNew generations.
   *
   * @param candidate The newly-seen instance sharing the correlation key.
   * @param existing The instance already indexed for that correlation key.
   * @return True when the candidate should replace the existing entry.
   */
  private static Boolean isPreferredCandidate(
    Workflow_Instance__c candidate,
    Workflow_Instance__c existing
  ) {
    Boolean candidateActive = ACTIVE_STATUSES.contains(candidate.Status__c);
    Boolean existingActive = ACTIVE_STATUSES.contains(existing.Status__c);
    if (candidateActive != existingActive) {
      return candidateActive;
    }
    return candidate.CreatedDate > existing.CreatedDate;
  }

  private static Id getAttachmentId(String textValue) {
    if (
      String.isNotBlank(textValue) &&
      textValue.startsWith(OFFLOAD_MARKER_PREFIX)
    ) {
      try {
        Map<String, Object> marker = (Map<String, Object>) JSON.deserializeUntyped(
          textValue
        );
        return (Id) marker.get('$attachmentId');
      } catch (Exception ignored) {
      }
    }
    return null;
  }

  private static String rehydrate(
    String textValue,
    Map<Id, String> dataByAttachment
  ) {
    Id attachmentId = getAttachmentId(textValue);
    if (attachmentId != null && dataByAttachment.containsKey(attachmentId)) {
      return dataByAttachment.get(attachmentId);
    }
    return textValue;
  }
}
