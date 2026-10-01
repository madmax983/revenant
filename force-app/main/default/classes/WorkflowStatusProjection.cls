/**
 * @description Status-DTO projection and offloaded-output rehydration for the
 * Revenant read API. Fetches winner instances' DTO fields, resolves the offload
 * markers that each instance owns in one bounded query pair, rehydrates each terminal
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
   * pre-fetched owned-output map so no additional SOQL is issued per row.
   * Exposed for {@link WorkflowCausationLineage}, which assembles lineage status
   * DTOs through this method.
   * @param inst the queried instance row to project
   * @param resolvedOutputByKey the owned file text, keyed by
   *        {@link WorkflowPayloadOffload#ownedKey}
   * @return the assembled status DTO
   */
  public static WorkflowEngine.WorkflowStatus buildStatus(
    Workflow_Instance__c inst,
    Map<String, String> resolvedOutputByKey
  ) {
    Boolean terminal = WorkflowStatusRead.TERMINAL_GETSTATUS_STATUSES.contains(
      inst.Status__c
    );
    String output = null;
    if (terminal) {
      output = rehydrateFromMap(inst, resolvedOutputByKey);
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
   * @description Loads the offloaded outputs that each instance owns, with one
   * link query and one file query. A marker whose file is not linked to its own
   * instance does not load. Exposed for {@link WorkflowCausationLineage}, which
   * bulk-resolves ancestor outputs before assembling lineage status DTOs.
   * @param instances the instances whose offloaded outputs to load
   * @return the file text by {@link WorkflowPayloadOffload#ownedKey} (empty when none)
   */
  public static Map<String, String> bulkResolveOffloadedOutputs(
    List<Workflow_Instance__c> instances
  ) {
    List<Id> docIds = new List<Id>();
    List<Id> ownerIds = new List<Id>();
    for (Workflow_Instance__c inst : instances) {
      Id docId = WorkflowPayloadOffload.markerDocId(inst.Output__c);
      if (docId != null) {
        docIds.add(docId);
        ownerIds.add(inst.Id);
      }
    }
    return WorkflowPayloadOffload.loadOwned(docIds, ownerIds, false);
  }

  // Rehydrates the output of one instance from the owned map, then decodes it
  // with the payload codec.
  private static String rehydrateFromMap(
    Workflow_Instance__c inst,
    Map<String, String> resolvedOutputByKey
  ) {
    Id docId = WorkflowPayloadOffload.markerDocId(inst.Output__c);
    if (docId != null) {
      String key = WorkflowPayloadOffload.ownedKey(inst.Id, docId);
      if (resolvedOutputByKey.containsKey(key)) {
        return WorkflowPayloadCodecs.decode(resolvedOutputByKey.get(key));
      }
    }
    return WorkflowPayloadCodecs.decode(inst.Output__c);
  }
}
