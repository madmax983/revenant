/**
 * @description Resolves attachment-backed payload fields for the instance-detail view:
 * loads the verified ContentDocument bodies in bulk, substitutes the (possibly truncated)
 * display text back onto the instance/step records, and records download descriptors for
 * oversized attachment-backed payloads. Extracted from WorkflowDashboardController; all
 * SOQL runs WITH SYSTEM_MODE.
 */
public inherited sharing class WorkflowPayloadService {
  // Character length above which the dashboard shows a truncated preview. Payloads that
  // are attachment-backed AND exceed this get a download link to the full ContentDocument.
  @TestVisible
  private static final Integer PAYLOAD_DISPLAY_LIMIT = 50000;

  private static Id getAttachmentId(String textValue) {
    if (
      String.isNotBlank(textValue) && textValue.startsWith('{"$attachmentId":')
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

  private static String truncatePayload(String val) {
    if (val != null && val.length() > 50000) {
      return val.substring(0, 50000) + '... (truncated)';
    }
    return val;
  }

  /**
   * Carries the resolved attachment bodies plus the download descriptors accumulated
   * while resolving an instance's payload fields, so resolveAndRecordPayload can take a
   * single context object instead of a long parameter list.
   */
  private class PayloadResolution {
    Map<Id, String> attachmentIdToData;
    Map<String, Object> payloadFiles;

    PayloadResolution(Map<Id, String> attachmentIdToData) {
      this.attachmentIdToData = attachmentIdToData;
      this.payloadFiles = new Map<String, Object>();
    }
  }

  // Resolves a payload field for display: returns the (possibly truncated) text and, when
  // the value is attachment-backed and was truncated, records a download descriptor for
  // the full ContentDocument under fieldKey in res.payloadFiles so the UI can offer the
  // file.
  private static String resolveAndRecordPayload(
    String textValue,
    String fieldKey,
    PayloadResolution res
  ) {
    if (String.isBlank(textValue)) {
      return textValue;
    }
    Id attachmentId = getAttachmentId(textValue);
    if (
      attachmentId != null && res.attachmentIdToData.containsKey(attachmentId)
    ) {
      String full = res.attachmentIdToData.get(attachmentId);
      if (full != null && full.length() > PAYLOAD_DISPLAY_LIMIT) {
        res.payloadFiles.put(
          fieldKey,
          new Map<String, Object>{
            'contentDocumentId' => attachmentId,
            'downloadUrl' => '/sfc/servlet.shepherd/document/download/' +
            attachmentId,
            'fullLength' => full.length()
          }
        );
      }
      return truncatePayload(full);
    }
    return truncatePayload(textValue);
  }

  private static void addAttachmentId(Set<Id> attachmentIds, String textValue) {
    Id attachmentId = getAttachmentId(textValue);
    if (attachmentId != null) {
      attachmentIds.add(attachmentId);
    }
  }

  private static Set<Id> collectPayloadAttachmentIds(
    Workflow_Instance__c instance,
    List<Workflow_Step_Execution__c> steps
  ) {
    Set<Id> attachmentIds = new Set<Id>();
    addAttachmentId(attachmentIds, instance.Input__c);
    addAttachmentId(attachmentIds, instance.Output__c);
    addAttachmentId(attachmentIds, instance.Progress__c);
    for (Workflow_Step_Execution__c step : steps) {
      addAttachmentId(attachmentIds, step.Input__c);
      addAttachmentId(attachmentIds, step.Output__c);
    }
    return attachmentIds;
  }

  private static Set<Id> verifyAttachmentLinks(
    Set<Id> attachmentIds,
    Id linkedEntityId
  ) {
    Set<Id> verifiedAttachmentIds = new Set<Id>();
    for (ContentDocumentLink cdl : [
      SELECT ContentDocumentId
      FROM ContentDocumentLink
      WHERE
        ContentDocumentId IN :attachmentIds
        AND LinkedEntityId = :linkedEntityId
      WITH SYSTEM_MODE
    ]) {
      verifiedAttachmentIds.add(cdl.ContentDocumentId);
    }
    return verifiedAttachmentIds;
  }

  private static Map<Id, String> loadAttachmentData(
    Set<Id> attachmentIds,
    Id linkedEntityId
  ) {
    Map<Id, String> attachmentIdToData = new Map<Id, String>();
    if (attachmentIds.isEmpty()) {
      return attachmentIdToData;
    }
    Set<Id> verifiedAttachmentIds = verifyAttachmentLinks(
      attachmentIds,
      linkedEntityId
    );
    if (verifiedAttachmentIds.isEmpty()) {
      return attachmentIdToData;
    }
    for (ContentVersion cv : [
      SELECT ContentDocumentId, VersionData
      FROM ContentVersion
      WHERE ContentDocumentId IN :verifiedAttachmentIds AND IsLatest = TRUE
      WITH SYSTEM_MODE
    ]) {
      if (cv.VersionData != null) {
        attachmentIdToData.put(cv.ContentDocumentId, cv.VersionData.toString());
      }
    }
    return attachmentIdToData;
  }

  /**
   * @description Resolves every attachment-backed payload field on the instance and its
   * steps for display, mutating each record's Input/Output/Progress field to the
   * display text and returning the download descriptors for oversized payloads.
   * @param instance The instance whose payload fields are resolved (mutated in place).
   * @param steps The instance's step executions (Input/Output mutated in place).
   * @return A map of field key to download descriptor for oversized attachment payloads.
   */
  public static Map<String, Object> resolvePayloadsInBulk(
    Workflow_Instance__c instance,
    List<Workflow_Step_Execution__c> steps
  ) {
    Set<Id> attachmentIds = collectPayloadAttachmentIds(instance, steps);
    Map<Id, String> attachmentIdToData = loadAttachmentData(
      attachmentIds,
      instance.Id
    );
    PayloadResolution res = new PayloadResolution(attachmentIdToData);

    instance.Input__c = resolveAndRecordPayload(
      instance.Input__c,
      'instance.Input',
      res
    );
    instance.Output__c = resolveAndRecordPayload(
      instance.Output__c,
      'instance.Output',
      res
    );
    instance.Progress__c = resolveAndRecordPayload(
      instance.Progress__c,
      'instance.Progress',
      res
    );
    for (Workflow_Step_Execution__c step : steps) {
      step.Input__c = resolveAndRecordPayload(
        step.Input__c,
        'step.' + step.Id + '.Input',
        res
      );
      step.Output__c = resolveAndRecordPayload(
        step.Output__c,
        'step.' + step.Id + '.Output',
        res
      );
    }
    return res.payloadFiles;
  }
}
