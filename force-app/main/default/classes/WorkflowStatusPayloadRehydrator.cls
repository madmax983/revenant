/**
 * Rehydrates offloaded workflow output/progress payloads for
 * WorkflowStatusInvocableAction. It reuses the engine's payload offload convention
 * so an offloaded (>100k) value stored as an attachment marker is materialized back
 * to the full payload an Apex caller would observe.
 *
 * Extracted from WorkflowStatusInvocableAction to keep the action's class-level
 * complexity within thresholds. It is strictly read-only: the only SOQL it performs
 * is the single bulk ContentVersion query used to load offloaded payloads.
 */
public inherited sharing class WorkflowStatusPayloadRehydrator {
  private static final String OFFLOAD_MARKER_PREFIX = '{"$attachmentId":';

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
  public static Map<Id, String> loadOffloadedPayloads(
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
   * @description Returns the full payload for a stored text value: the rehydrated
   * attachment contents when the value is an offload marker whose attachment was
   * loaded, otherwise the original text value unchanged.
   * @param textValue The stored field value (an offload marker or an inline payload).
   * @param dataByAttachment The map of offload attachment Ids to rehydrated payload text.
   * @return The rehydrated payload text, or the original text value when not offloaded.
   */
  public static String rehydrate(
    String textValue,
    Map<Id, String> dataByAttachment
  ) {
    Id attachmentId = getAttachmentId(textValue);
    if (attachmentId != null && dataByAttachment.containsKey(attachmentId)) {
      return dataByAttachment.get(attachmentId);
    }
    return textValue;
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
   * @description Parses the offload attachment Id out of a stored value when the value is
   * an offload marker, returning null for inline payloads or malformed markers.
   * @param textValue The stored field value to inspect for an offload marker.
   * @return The referenced attachment (ContentDocument) Id, or null when not offloaded.
   */
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
}
