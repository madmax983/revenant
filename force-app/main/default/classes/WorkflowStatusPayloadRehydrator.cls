/**
 * Rehydrates offloaded workflow output/progress payloads for
 * WorkflowStatusInvocableAction. A marker resolves only when its file is linked
 * to the instance that holds the marker. A forged marker stays as text.
 *
 * Extracted from WorkflowStatusInvocableAction to keep the action's class-level
 * complexity within thresholds. It is strictly read-only.
 */
public inherited sharing class WorkflowStatusPayloadRehydrator {
  /**
   * Bulk-loads the offloaded output/progress payloads that each instance owns.
   * It uses one link query and one file query for all instances. Large outputs
   * load in full, so a Flow batch that polls many large outputs can approach the
   * Apex heap limit. Use smaller batches in that case.
   *
   * @param resolved The resolved instances whose offloaded payloads to load.
   * @return The file text by {@link WorkflowPayloadOffload#ownedKey}.
   */
  public static Map<String, String> loadOffloadedPayloads(
    List<Workflow_Instance__c> resolved
  ) {
    List<Id> docIds = new List<Id>();
    List<Id> ownerIds = new List<Id>();
    for (Workflow_Instance__c inst : resolved) {
      if (inst != null) {
        addPair(docIds, ownerIds, inst.Id, inst.Output__c);
        addPair(docIds, ownerIds, inst.Id, inst.Progress__c);
      }
    }
    return WorkflowPayloadOffload.loadOwned(docIds, ownerIds, false);
  }

  /**
   * @description Returns the full payload for a stored text value. When the value
   * is a marker and its file is owned by the instance, it uses the file text.
   * Otherwise it uses the original text. Then the gate decodes the value, or
   * redacts it when the user cannot read the instance.
   * @param textValue The stored field value (an offload marker or an inline payload).
   * @param ownerId The instance that holds the value.
   * @param dataByAttachment The owned file text, keyed by ownedKey.
   * @param gate The record-access gate.
   * @return The rehydrated and decoded payload text, or the redaction placeholder.
   */
  public static String rehydrate(
    String textValue,
    Id ownerId,
    Map<String, String> dataByAttachment,
    WorkflowPayloadAccess.Gate gate
  ) {
    String stored = textValue;
    Id docId = WorkflowPayloadOffload.markerDocId(textValue);
    if (docId != null && ownerId != null) {
      String key = WorkflowPayloadOffload.ownedKey(ownerId, docId);
      if (dataByAttachment.containsKey(key)) {
        stored = dataByAttachment.get(key);
      }
    }
    return gate.decode(stored, ownerId);
  }

  // Adds one (file, owner) pair when the value is a marker.
  private static void addPair(
    List<Id> docIds,
    List<Id> ownerIds,
    Id ownerId,
    String textValue
  ) {
    Id docId = WorkflowPayloadOffload.markerDocId(textValue);
    if (docId != null) {
      docIds.add(docId);
      ownerIds.add(ownerId);
    }
  }
}
