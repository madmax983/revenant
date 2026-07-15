/**
 * @description Status-DTO projection and offloaded-output rehydration for the
 * Revenant read API. Fetches winner instances' DTO fields, resolves all offload
 * markers in one bounded ContentVersion query, rehydrates each terminal
 * instance's `Output__c`, and assembles the resident `WorkflowEngine.WorkflowStatus`
 * DTO. Extracted from `WorkflowEngine`; consumed by {@link WorkflowStatusRead} and
 * {@link WorkflowCausationLineage}. Read-only (zero DML); all SOQL runs in system
 * mode.
 */
public inherited sharing class WorkflowStatusProjection {
  /**
   * Fetches the winner instances' DTO fields (including Output__c) by id.
   * @param winnerIds the resolved winning instance ids
   * @return a map of instance id to its loaded record (empty when no winners)
   */
  public static Map<Id, Workflow_Instance__c> queryWinnerInstances(
    Set<Id> winnerIds
  ) {
    Map<Id, Workflow_Instance__c> instById = new Map<Id, Workflow_Instance__c>();
    if (winnerIds.isEmpty()) {
      return instById;
    }
    for (Workflow_Instance__c inst : [
      SELECT
        Id,
        Workflow_Name__c,
        Correlation_Key__c,
        Status__c,
        Error_Message__c,
        Output__c,
        Causation_Id__c
      FROM Workflow_Instance__c
      WHERE Id IN :winnerIds
      WITH SYSTEM_MODE
    ]) {
      instById.put(inst.Id, inst);
    }
    return instById;
  }

  /**
   * @description Builds a WorkflowStatus DTO from a queried instance, using the
   * pre-fetched offloaded-output map so no additional SOQL is issued per row.
   * Exposed for {@link WorkflowCausationLineage}, which assembles lineage status
   * DTOs through this method.
   * @param inst the queried instance row to project
   * @param resolvedOutputByDocId the pre-resolved offloaded-output map keyed by
   *        ContentDocumentId
   * @return the assembled status DTO
   */
  public static WorkflowEngine.WorkflowStatus buildStatus(
    Workflow_Instance__c inst,
    Map<Id, String> resolvedOutputByDocId
  ) {
    Boolean terminal = WorkflowStatusRead.TERMINAL_GETSTATUS_STATUSES.contains(
      inst.Status__c
    );
    String output = null;
    if (terminal) {
      output = rehydrateFromMap(inst.Output__c, resolvedOutputByDocId);
      // A terminal instance has definitively produced its output, so surface an
      // empty result as '' rather than null. (Salesforce coerces an empty text
      // field to null on insert.) This keeps output == null meaning exactly "not
      // terminal yet", so callers can distinguish "completed with no output" from
      // "still running" by output alone, per the documented contract.
      if (output == null) {
        output = '';
      }
    }
    return new WorkflowEngine.WorkflowStatus(inst, output);
  }

  /**
   * @description Resolves all offload markers found in a collection of instances
   * in one ContentVersion SOQL query. Exposed for {@link WorkflowCausationLineage},
   * which bulk-resolves ancestor outputs before assembling lineage status DTOs.
   * @param instances the instances whose offloaded outputs to resolve
   * @return a map from ContentDocumentId to resolved text (empty when none)
   */
  public static Map<Id, String> bulkResolveOffloadedOutputs(
    List<Workflow_Instance__c> instances
  ) {
    Set<Id> docIds = new Set<Id>();
    for (Workflow_Instance__c inst : instances) {
      Id docId = getOffloadDocId(inst.Output__c);
      if (docId != null) {
        docIds.add(docId);
      }
    }
    Map<Id, String> resolved = new Map<Id, String>();
    if (!docIds.isEmpty()) {
      for (ContentVersion cv : [
        SELECT ContentDocumentId, VersionData
        FROM ContentVersion
        WHERE ContentDocumentId IN :docIds AND IsLatest = TRUE
        WITH SYSTEM_MODE
      ]) {
        if (cv.VersionData != null) {
          resolved.put(cv.ContentDocumentId, cv.VersionData.toString());
        }
      }
    }
    return resolved;
  }

  // Extracts the ContentDocumentId from an offload marker, or null if not a marker.
  private static Id getOffloadDocId(String textValue) {
    if (
      String.isNotBlank(textValue) && textValue.startsWith('{"$attachmentId":')
    ) {
      try {
        Map<String, Object> marker = (Map<String, Object>) JSON.deserializeUntyped(
          textValue
        );
        return (Id) marker.get('$attachmentId');
      } catch (Exception ignored) {
        // Not a valid offload marker; treat as a non-offloaded value.
      }
    }
    return null;
  }

  // Rehydrates a single output string using the pre-fetched resolved map.
  private static String rehydrateFromMap(
    String textValue,
    Map<Id, String> resolvedOutputByDocId
  ) {
    Id docId = getOffloadDocId(textValue);
    if (docId != null && resolvedOutputByDocId.containsKey(docId)) {
      return resolvedOutputByDocId.get(docId);
    }
    return textValue;
  }
}
