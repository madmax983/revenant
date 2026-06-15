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
  private static Integer MAX_CHAIN_DEPTH = 50;

  private static final String OFFLOAD_MARKER_PREFIX = '{"$attachmentId":';

  public class StatusRequest {
    @InvocableVariable(
      label='Correlation Key or Workflow Instance ID'
      description='Either a Workflow Instance record Id or a Correlation Key identifying the workflow to read.'
      required=true
    )
    public String workflowKeyOrId;
  }

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

    public StatusResult() {
      this.found = false;
      this.isTerminal = false;
      this.isSuccess = false;
    }
  }

  @InvocableMethod(
    label='Get Workflow Status'
    category='Revenant Workflows'
    description='Reads a Revenant durable workflow instance current status, output, and failure detail (read-only).'
  )
  public static List<StatusResult> getStatus(List<StatusRequest> requests) {
    if (requests == null || requests.isEmpty()) {
      return new List<StatusResult>();
    }

    String wflowPrefix = Workflow_Instance__c.SObjectType.getDescribe()
      .getKeyPrefix();
    Pattern idPattern = Pattern.compile('^[a-zA-Z0-9]{15}([a-zA-Z0-9]{3})?$');

    // 1. Bucket each raw input into an Id lookup and/or a Correlation Key lookup.
    //    An id-shaped value is also retained as a key fallback in case a caller
    //    used a correlation key that happens to look like an Id.
    List<Id> reqIds = new List<Id>();
    List<String> reqKeys = new List<String>();
    Set<Id> lookupIds = new Set<Id>();
    Set<String> lookupKeys = new Set<String>();

    for (StatusRequest req : requests) {
      String raw = (req == null) ? null : req.workflowKeyOrId;
      Id parsedId = null;
      if (
        String.isNotBlank(raw) &&
        idPattern.matcher(raw).matches() &&
        raw.startsWith(wflowPrefix)
      ) {
        try {
          parsedId = (Id) raw;
        } catch (Exception ex) {
          // Malformed Id (e.g. bad checksum): fall back to a key lookup.
          parsedId = null;
        }
      }
      reqIds.add(parsedId);
      if (parsedId != null) {
        lookupIds.add(parsedId);
      }
      if (String.isNotBlank(raw)) {
        reqKeys.add(raw);
        lookupKeys.add(raw);
      } else {
        reqKeys.add(null);
      }
    }

    // 2. One bulk query for all direct matches, in any status (terminal included).
    Map<Id, Workflow_Instance__c> instById = new Map<Id, Workflow_Instance__c>();
    Map<String, Workflow_Instance__c> instByKey = new Map<String, Workflow_Instance__c>();
    if (!lookupIds.isEmpty() || !lookupKeys.isEmpty()) {
      for (Workflow_Instance__c inst : [
        SELECT
          Id,
          Status__c,
          Output__c,
          Error_Message__c,
          Correlation_Key__c,
          Previous_Instance__c,
          CreatedDate
        FROM Workflow_Instance__c
        WHERE Id IN :lookupIds OR Correlation_Key__c IN :lookupKeys
        WITH SYSTEM_MODE
      ]) {
        instById.put(inst.Id, inst);
        if (String.isNotBlank(inst.Correlation_Key__c)) {
          Workflow_Instance__c existing = instByKey.get(
            inst.Correlation_Key__c
          );
          // Correlation_Key__c is not unique: a key can be reused after a run goes
          // terminal, and a ContinuedAsNew hand-off can reuse a custom key. When a
          // key maps to several rows, prefer the live run (active status), then the
          // most recent, so we report the current run rather than stale history.
          if (existing == null || isPreferredCandidate(inst, existing)) {
            instByKey.put(inst.Correlation_Key__c, inst);
          }
        }
      }
    }

    // 3. Resolve a starting instance per request. Id matches are precise handles
    //    (no chain walk); key matches are walked forward through ContinuedAsNew.
    List<Workflow_Instance__c> resolved = new List<Workflow_Instance__c>();
    List<Boolean> walkChain = new List<Boolean>();
    for (Integer i = 0; i < requests.size(); i++) {
      Workflow_Instance__c match = null;
      Boolean byKey = false;
      if (reqIds[i] != null) {
        match = instById.get(reqIds[i]);
      }
      if (match == null && reqKeys[i] != null) {
        match = instByKey.get(reqKeys[i]);
        byKey = (match != null);
      }
      resolved.add(match);
      walkChain.add(byKey);
    }

    // 4. Forward-walk ContinuedAsNew chains for key-resolved requests whose start
    //    instance is still a predecessor. Same-key chains are already resolved to
    //    the live generation by the active/latest preference above; this walk
    //    covers chains whose successor took a different key (e.g. the default
    //    `_runN` scheme). Bulk-safe: one SOQL per chain generation, never per row.
    //    The walk is bounded by MAX_CHAIN_DEPTH because SOQL limits make an
    //    unbounded link-by-link walk impossible; if a (typically perpetual,
    //    different-key) chain exceeds the bound we stop on the furthest generation
    //    reached, which is still a ContinuedAsNew row and is therefore reported as
    //    non-terminal / non-success -- never as a false completed outcome.
    for (Integer depth = 0; depth < MAX_CHAIN_DEPTH; depth++) {
      Set<Id> predecessorIds = new Set<Id>();
      for (Integer i = 0; i < requests.size(); i++) {
        Workflow_Instance__c cur = resolved[i];
        if (walkChain[i] && cur != null && cur.Status__c == 'ContinuedAsNew') {
          predecessorIds.add(cur.Id);
        }
      }
      if (predecessorIds.isEmpty()) {
        break;
      }
      Map<Id, Workflow_Instance__c> successorByPrev = new Map<Id, Workflow_Instance__c>();
      for (Workflow_Instance__c succ : [
        SELECT
          Id,
          Status__c,
          Output__c,
          Error_Message__c,
          Correlation_Key__c,
          Previous_Instance__c
        FROM Workflow_Instance__c
        WHERE Previous_Instance__c IN :predecessorIds
        WITH SYSTEM_MODE
      ]) {
        successorByPrev.put(succ.Previous_Instance__c, succ);
      }
      Boolean advanced = false;
      for (Integer i = 0; i < requests.size(); i++) {
        Workflow_Instance__c cur = resolved[i];
        if (walkChain[i] && cur != null && cur.Status__c == 'ContinuedAsNew') {
          Workflow_Instance__c succ = successorByPrev.get(cur.Id);
          if (succ != null) {
            resolved[i] = succ;
            advanced = true;
          }
        }
      }
      if (!advanced) {
        break;
      }
    }

    // 5. Bulk-resolve offloaded outputs in a single ContentVersion query.
    //    Honoring the contract that outputJson is the full rehydrated payload means
    //    large (>100k) offloaded outputs are materialized in full, so a Flow batch
    //    that simultaneously polls many instances whose outputs are all offloaded
    //    can approach the Apex heap limit. We do not truncate (that would break the
    //    identical-to-Apex-caller guarantee); callers polling many very large
    //    outputs at once should use smaller Flow batch sizes.
    Set<Id> attachmentIds = new Set<Id>();
    for (Workflow_Instance__c inst : resolved) {
      if (inst != null) {
        Id attachmentId = getAttachmentId(inst.Output__c);
        if (attachmentId != null) {
          attachmentIds.add(attachmentId);
        }
      }
    }
    Map<Id, String> dataByAttachment = new Map<Id, String>();
    if (!attachmentIds.isEmpty()) {
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
    }

    // 6. Assemble correspondingly-ordered results.
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
      } catch (Exception ex) {
        System.debug(
          LoggingLevel.FINE,
          'Get Workflow Status: offload marker parse fallback: ' +
          ex.getMessage()
        );
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
