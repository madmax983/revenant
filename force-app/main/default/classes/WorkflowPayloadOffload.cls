/**
 * @description Payload big-object offload and reserved-key JSON utilities for the
 * Revenant engine. Oversized payload strings are stored as `ContentVersion`
 * files behind a `{"$attachmentId":...}` marker and rehydrated on read, keeping
 * `Workflow_Instance__c` / `Workflow_Step_Execution__c` text fields within their
 * storage limits. This is a widely-called, stateless utility: nearly every other
 * engine phase resolves or saves payloads through it, and validates correlation
 * keys through {@link WorkflowPayloadOffload#validateCorrelationKey}. Extracted
 * from `WorkflowEngine`; all SOQL and DML execute in system mode so offload and
 * rehydration proceed regardless of the invoking user's object permissions.
 */
public inherited sharing class WorkflowPayloadOffload {
  /**
   * @description Validates a correlation key: it must be present and at most 200
   * characters. Throws {@link WorkflowEngine.WorkflowException} otherwise.
   * @param correlationKey the correlation key to validate
   */
  public static void validateCorrelationKey(String correlationKey) {
    if (String.isBlank(correlationKey)) {
      throw new WorkflowEngine.WorkflowException(
        'Correlation key is required.'
      );
    }
    if (correlationKey.length() > 200) {
      throw new WorkflowEngine.WorkflowException(
        'Correlation key length cannot exceed 200 characters.'
      );
    }
  }

  /**
   * @description Returns the String value of a reserved `$`-key from a JSON-object
   * string, or null for blank input, non-object JSON, a missing key, and parse
   * failures.
   * @param jsonText the JSON-object string to read
   * @param key the reserved `$`-key to extract
   * @return the string value for the key, or null when absent/unparseable
   */
  public static String readJsonMapKey(String jsonText, String key) {
    if (String.isBlank(jsonText)) {
      return null;
    }
    try {
      Object parsed = JSON.deserializeUntyped(jsonText);
      if (!(parsed instanceof Map<String, Object>)) {
        return null;
      }
      Object value = ((Map<String, Object>) parsed).get(key);
      if (value == null) {
        return null;
      }
      String strValue = String.valueOf(value);
      return String.isBlank(strValue) ? null : strValue;
    } catch (Exception e) {
      return null;
    }
  }

  /**
   * @description Resolves a possibly-offloaded payload string: when the value is a
   * `{"$attachmentId":...}` marker it fetches and returns the linked
   * ContentVersion body, otherwise the value is returned unchanged. Falls back to
   * the raw value if the offloaded document cannot be read.
   * @param textValue the raw (possibly marker) payload string
   * @return the resolved payload text, or the original value when not offloaded
   */
  public static String resolvePayload(String textValue) {
    if (
      String.isNotBlank(textValue) && textValue.startsWith('{"$attachmentId":')
    ) {
      try {
        Map<String, Object> marker = (Map<String, Object>) JSON.deserializeUntyped(
          textValue
        );
        Id attachmentId = (Id) marker.get('$attachmentId');
        List<ContentVersion> cvs = [
          SELECT VersionData
          FROM ContentVersion
          WHERE ContentDocumentId = :attachmentId AND IsLatest = TRUE
          WITH SYSTEM_MODE
        ];
        if (!cvs.isEmpty()) {
          return cvs[0].VersionData.toString();
        }
      } catch (Exception ignored) {
        // Offload resolution is best-effort; fall back to the raw stored value.
      }
    }
    return textValue;
  }

  /**
   * @description Bulk variant of resolvePayload: resolves a list of payload
   * strings, fetching every offloaded ContentVersion in ONE query rather than one
   * per row. A list accessor (e.g. a parent reading a backlog of child-completion
   * signals with large offloaded outputs) would otherwise issue a ContentVersion
   * query per offloaded payload and hit the SOQL-query governor limit after
   * ~100-200 rows, defeating the accessor's design of loading thousands in one
   * call. Inline (non-marker) payloads and unresolved markers pass through
   * unchanged, index for index with the input.
   * @param rawValues the raw (possibly marker) payload strings to resolve
   * @return the resolved payloads, index-aligned with rawValues
   */
  public static List<String> resolvePayloads(List<String> rawValues) {
    Map<Integer, Id> markerDocByIndex = new Map<Integer, Id>();
    Set<Id> docIds = collectOffloadMarkers(rawValues, markerDocByIndex);
    Map<Id, String> resolvedByDoc = queryResolvedDocs(docIds);
    List<String> out = new List<String>();
    for (Integer i = 0; i < rawValues.size(); i++) {
      Id docId = markerDocByIndex.get(i);
      out.add(
        (docId != null && resolvedByDoc.containsKey(docId))
          ? resolvedByDoc.get(docId)
          : rawValues[i]
      );
    }
    return out;
  }

  /**
   * @description Scans raw values for `{"$attachmentId":...}` offload markers,
   * recording each marker's document id by index and collecting the distinct
   * document ids.
   * @param rawValues the raw payload values (inline or offload markers)
   * @param markerDocByIndex out-param mapping each marker's index to its doc id
   * @return the distinct offloaded ContentDocument ids to resolve
   */
  private static Set<Id> collectOffloadMarkers(
    List<String> rawValues,
    Map<Integer, Id> markerDocByIndex
  ) {
    Set<Id> docIds = new Set<Id>();
    for (Integer i = 0; i < rawValues.size(); i++) {
      String v = rawValues[i];
      if (!(String.isNotBlank(v) && v.startsWith('{"$attachmentId":'))) {
        continue;
      }
      try {
        Map<String, Object> marker = (Map<String, Object>) JSON.deserializeUntyped(
          v
        );
        Id docId = (Id) marker.get('$attachmentId');
        markerDocByIndex.put(i, docId);
        docIds.add(docId);
      } catch (Exception ignored) {
        // Not a valid offload marker; leave this entry to pass through as-is.
      }
    }
    return docIds;
  }

  /**
   * @description Bulk-resolves the latest ContentVersion text for the given
   * document ids.
   * @param docIds the offloaded ContentDocument ids to resolve
   * @return a map of document id to its resolved payload text (empty when none)
   */
  private static Map<Id, String> queryResolvedDocs(Set<Id> docIds) {
    Map<Id, String> resolvedByDoc = new Map<Id, String>();
    if (docIds.isEmpty()) {
      return resolvedByDoc;
    }
    for (ContentVersion cv : [
      SELECT ContentDocumentId, VersionData
      FROM ContentVersion
      WHERE ContentDocumentId IN :docIds AND IsLatest = TRUE
      WITH SYSTEM_MODE
    ]) {
      resolvedByDoc.put(cv.ContentDocumentId, cv.VersionData.toString());
    }
    return resolvedByDoc;
  }

  /**
   * @description Offloads an oversized payload to a ContentVersion so it fits
   * within field limits: when the text exceeds the inline threshold it is stored
   * as a file and a `{"$attachmentId":...}` marker is returned; otherwise the
   * value is returned unchanged for inline storage.
   * @param instanceId Id of the owning instance (links the stored document)
   * @param textValue the payload text to store
   * @param title title/filename for the offloaded ContentVersion
   * @return an offload marker string when stored as a file, else the original text
   */
  public static String savePayloadIfNeeded(
    Id instanceId,
    String textValue,
    String title
  ) {
    if (String.isNotBlank(textValue) && textValue.length() > 100000) {
      ContentVersion cv = new ContentVersion();
      cv.Title = title;
      cv.PathOnClient = title + '.json';
      cv.VersionData = Blob.valueOf(textValue);
      Database.insert(cv, true, AccessLevel.SYSTEM_MODE);

      Id docId = [
        SELECT ContentDocumentId
        FROM ContentVersion
        WHERE Id = :cv.Id
        WITH SYSTEM_MODE
      ]
      .ContentDocumentId;

      ContentDocumentLink cdl = new ContentDocumentLink();
      cdl.ContentDocumentId = docId;
      cdl.LinkedEntityId = instanceId;
      cdl.ShareType = 'V';
      cdl.Visibility = 'InternalUsers';
      try {
        Database.insert(cdl, true, AccessLevel.SYSTEM_MODE);
      } catch (DmlException ignored) {
        // Default visibility rejected; retry the link with AllUsers visibility.
        cdl.Visibility = 'AllUsers';
        Database.insert(cdl, true, AccessLevel.SYSTEM_MODE);
      }

      return JSON.serialize(
        new Map<String, String>{ '$attachmentId' => docId }
      );
    }
    return textValue;
  }
}
