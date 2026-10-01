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
 * It is also the codec seam. Resolve methods decode through
 * {@link WorkflowPayloadCodecs}. Callers encode author data before they call
 * `savePayloadIfNeeded`, so the offload check uses the encoded length.
 * Resolve methods read a file only when it is linked to the reading instance.
 * A forged marker stays as text.
 */
public inherited sharing class WorkflowPayloadOffload {
  // Key prefix of a ContentDocument Id.
  private static final String DOCUMENT_PREFIX = '069';
  private static final String MARKER_PREFIX = '{"$attachmentId":';

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
   * @description Throws when text starts with an offload marker. Use it at
   * public entry points: a caller must not send a marker, because it can point
   * at a file of another instance.
   * @param text the caller text to check
   * @param fieldName the field name for the error message
   */
  public static void rejectOffloadMarker(String text, String fieldName) {
    if (String.isNotBlank(text) && text.startsWith(MARKER_PREFIX)) {
      throw new WorkflowEngine.WorkflowException(
        fieldName + ' cannot start with an offload marker.'
      );
    }
  }

  /**
   * @description Returns the key of an owned file in the map that
   * {@link #loadOwned} returns.
   * @param ownerId the instance that owns the file
   * @param docId the ContentDocument Id of the file
   * @return the map key
   */
  public static String ownedKey(Id ownerId, Id docId) {
    return String.valueOf(ownerId) + ':' + String.valueOf(docId);
  }

  /**
   * @description Reads the Id from an offload marker.
   * @param textValue the stored value
   * @return the ContentDocument Id, or null when the value is not a marker
   */
  public static Id markerDocId(String textValue) {
    if (String.isBlank(textValue) || !textValue.startsWith(MARKER_PREFIX)) {
      return null;
    }
    try {
      Map<String, Object> marker = (Map<String, Object>) JSON.deserializeUntyped(
        textValue
      );
      Id docId = (Id) marker.get('$attachmentId');
      return String.valueOf(docId).startsWith(DOCUMENT_PREFIX) ? docId : null;
    } catch (Exception ignored) {
      return null; // Not a valid marker: the value passes through as-is.
    }
  }

  /**
   * @description Resolves a possibly-offloaded payload for one instance. A
   * marker resolves only when its file is linked to the owner. Any other
   * marker stays as text. Then it decodes the value with
   * {@link WorkflowPayloadCodecs#decode}.
   * @param textValue the raw (possibly marker) payload string
   * @param ownerId the instance that reads the value
   * @return the resolved and decoded payload text
   */
  public static String resolvePayload(String textValue, Id ownerId) {
    return resolvePayloads(new List<String>{ textValue }, ownerId)[0];
  }

  /**
   * @description Resolves a value only to read engine control markers (child,
   * approval and timeout waits). The engine never encodes these markers. An
   * encoded value is author data, so this returns null and does not decode it.
   * Operator views use this, so they never decode author payloads.
   * @param textValue the raw stored value
   * @param ownerId the instance that owns the value
   * @return the resolved control payload, or null for an encoded value
   */
  public static String resolveControlPayload(String textValue, Id ownerId) {
    return resolveControlPayloads(
      new List<String>{ textValue },
      new List<Id>{ ownerId }
    )[0];
  }

  /**
   * @description Like {@link #resolveControlPayload}, but it does not read an
   * offloaded body above `maxBytes`. The size comes from `ContentSize`, before the
   * read. It returns the marker text for such a body. Operator views use this to
   * keep the heap small.
   * @param textValue the raw stored value
   * @param ownerId the instance that owns the value
   * @param maxBytes the largest body to read, in bytes
   * @return the resolved control payload, the marker text for a large body, or
   * null for an encoded value
   */
  public static String resolveControlPayloadWithin(
    String textValue,
    Id ownerId,
    Integer maxBytes
  ) {
    Id docId = markerDocId(textValue);
    if (docId != null) {
      for (ContentVersion cv : [
        SELECT ContentSize
        FROM ContentVersion
        WHERE ContentDocumentId = :docId AND IsLatest = TRUE
        WITH SYSTEM_MODE
      ]) {
        if (cv.ContentSize != null && cv.ContentSize > maxBytes) {
          return textValue;
        }
      }
    }
    return resolveControlPayload(textValue, ownerId);
  }

  /**
   * @description Bulk variant of {@link #resolveControlPayload}. It never calls
   * the codec, so a value that cannot be decoded does not stop the batch.
   * @param rawValues the raw stored values
   * @param ownerIds the owner of each value, index-aligned
   * @return the control payloads (null for encoded values), index-aligned
   */
  public static List<String> resolveControlPayloads(
    List<String> rawValues,
    List<Id> ownerIds
  ) {
    List<String> out = resolveStoredForms(rawValues, ownerIds, false);
    for (Integer i = 0; i < out.size(); i++) {
      if (WorkflowPayloadCodecs.isEncoded(out[i])) {
        out[i] = null;
      }
    }
    return out;
  }

  /**
   * @description Bulk variant of resolvePayload for values of one instance.
   * @param rawValues the raw (possibly marker) payload strings
   * @param ownerId the instance that reads the values
   * @return the resolved payloads, index-aligned with rawValues
   */
  public static List<String> resolvePayloads(
    List<String> rawValues,
    Id ownerId
  ) {
    List<Id> ownerIds = new List<Id>();
    for (Integer i = 0; i < rawValues.size(); i++) {
      ownerIds.add(ownerId);
    }
    return resolvePayloads(rawValues, ownerIds);
  }

  /**
   * @description Bulk variant of resolvePayload. It reads every owned file with
   * one file query and one link query, not one query per value. A marker whose
   * file is not linked to its owner stays as text. The method decodes each
   * value with {@link WorkflowPayloadCodecs#decode}.
   * @param rawValues the raw (possibly marker) payload strings
   * @param ownerIds the instance that reads each value, index-aligned
   * @return the resolved payloads, index-aligned with rawValues
   */
  public static List<String> resolvePayloads(
    List<String> rawValues,
    List<Id> ownerIds
  ) {
    List<String> out = resolveStoredForms(rawValues, ownerIds, false);
    for (Integer i = 0; i < out.size(); i++) {
      out[i] = WorkflowPayloadCodecs.decode(out[i]);
    }
    return out;
  }

  /**
   * @description Resolves child-completion values for a parent. A marker
   * resolves when its file is linked to the parent or to a child of the parent.
   * The caller reads the value from the child record
   * (see StepChildOutcomes).
   * @param rawValues the raw (possibly marker) payload strings
   * @param parentId the parent instance that reads the values
   * @return the resolved payloads, index-aligned with rawValues
   */
  public static List<String> resolveChildPayloads(
    List<String> rawValues,
    Id parentId
  ) {
    List<Id> ownerIds = new List<Id>();
    for (Integer i = 0; i < rawValues.size(); i++) {
      ownerIds.add(parentId);
    }
    List<String> out = resolveStoredForms(rawValues, ownerIds, true);
    for (Integer i = 0; i < out.size(); i++) {
      out[i] = WorkflowPayloadCodecs.decode(out[i]);
    }
    return out;
  }

  /**
   * @description Reads the links of every file that the values name, with one
   * query. Give the result to
   * {@link #resolvePayloads(List, List, Map)} to resolve the values in batches
   * with no more link queries.
   * @param rawValues the raw (possibly marker) payload strings
   * @return the linked entity Ids by ContentDocument Id
   */
  public static Map<Id, Set<Id>> linksFor(List<String> rawValues) {
    Set<Id> docs = new Set<Id>();
    for (String raw : rawValues) {
      docs.add(markerDocId(raw));
    }
    docs.remove(null);
    return docs.isEmpty() ? new Map<Id, Set<Id>>() : linkedEntitiesByDoc(docs);
  }

  /**
   * @description Like {@link #resolvePayloads(List, List)}, but it uses links
   * that {@link #linksFor} read before. It runs no link query.
   * @param rawValues the raw (possibly marker) payload strings
   * @param ownerIds the instance that reads each value, index-aligned
   * @param linksByDoc the links from {@link #linksFor}
   * @return the resolved payloads, index-aligned with rawValues
   */
  public static List<String> resolvePayloads(
    List<String> rawValues,
    List<Id> ownerIds,
    Map<Id, Set<Id>> linksByDoc
  ) {
    List<String> out = resolveStoredForms(
      rawValues,
      ownerIds,
      false,
      linksByDoc
    );
    for (Integer i = 0; i < out.size(); i++) {
      out[i] = WorkflowPayloadCodecs.decode(out[i]);
    }
    return out;
  }

  private static List<String> resolveStoredForms(
    List<String> rawValues,
    List<Id> ownerIds,
    Boolean includeChildren
  ) {
    return resolveStoredForms(rawValues, ownerIds, includeChildren, null);
  }

  // Replaces each owned marker with its file text. It does not decode. Values
  // stay index-aligned with the input.
  private static List<String> resolveStoredForms(
    List<String> rawValues,
    List<Id> ownerIds,
    Boolean includeChildren,
    Map<Id, Set<Id>> knownLinks
  ) {
    List<Id> docIds = new List<Id>();
    for (String raw : rawValues) {
      docIds.add(markerDocId(raw));
    }
    Map<String, String> textByKey = loadOwned(
      docIds,
      ownerIds,
      includeChildren,
      knownLinks
    );
    List<String> out = new List<String>();
    for (Integer i = 0; i < rawValues.size(); i++) {
      String key = docIds[i] == null ||
        ownerIds[i] == null
        ? null
        : ownedKey(ownerIds[i], docIds[i]);
      out.add(
        key != null && textByKey.containsKey(key)
          ? textByKey.get(key)
          : rawValues[i]
      );
    }
    return out;
  }

  /**
   * @description Loads file text for (owner, file) pairs. A pair loads only
   * when the file is linked to the owner, or with includeChildren to a child of
   * the owner. It uses one link query, one file query, and one child query
   * only when a pair needs it.
   * @param docIds the ContentDocument Ids (null entries are skipped)
   * @param ownerIds the owner of each file, index-aligned with docIds
   * @param includeChildren true to accept a file linked to a child of the owner
   * @return the file text by {@link #ownedKey}; empty when no pair is owned
   */
  public static Map<String, String> loadOwned(
    List<Id> docIds,
    List<Id> ownerIds,
    Boolean includeChildren
  ) {
    return loadOwned(docIds, ownerIds, includeChildren, null);
  }

  private static Map<String, String> loadOwned(
    List<Id> docIds,
    List<Id> ownerIds,
    Boolean includeChildren,
    Map<Id, Set<Id>> knownLinks
  ) {
    Map<String, String> textByKey = new Map<String, String>();
    Set<Id> docs = new Set<Id>(docIds);
    docs.remove(null);
    if (docs.isEmpty() || allNull(ownerIds)) {
      return textByKey;
    }
    Map<Id, Set<Id>> linksByDoc = knownLinks != null
      ? knownLinks
      : linkedEntitiesByDoc(docs);
    List<Integer> owned = new List<Integer>();
    List<Integer> childCandidates = new List<Integer>();
    for (Integer i = 0; i < docIds.size(); i++) {
      Set<Id> links = docIds[i] == null ? null : linksByDoc.get(docIds[i]);
      if (links == null || ownerIds[i] == null) {
        continue;
      }
      if (links.contains(ownerIds[i])) {
        owned.add(i);
      } else if (includeChildren) {
        childCandidates.add(i);
      }
    }
    owned.addAll(
      ownedThroughChildren(childCandidates, docIds, ownerIds, linksByDoc)
    );
    Set<Id> ownedDocs = new Set<Id>();
    for (Integer i : owned) {
      ownedDocs.add(docIds[i]);
    }
    Map<Id, String> textByDoc = queryResolvedDocs(ownedDocs);
    for (Integer i : owned) {
      if (textByDoc.containsKey(docIds[i])) {
        textByKey.put(
          ownedKey(ownerIds[i], docIds[i]),
          textByDoc.get(docIds[i])
        );
      }
    }
    return textByKey;
  }

  private static Boolean allNull(List<Id> ids) {
    for (Id i : ids) {
      if (i != null) {
        return false;
      }
    }
    return true;
  }

  // The entities that each file links to, in one query.
  private static Map<Id, Set<Id>> linkedEntitiesByDoc(Set<Id> docIds) {
    Map<Id, Set<Id>> linksByDoc = new Map<Id, Set<Id>>();
    for (ContentDocumentLink cdl : [
      SELECT ContentDocumentId, LinkedEntityId
      FROM ContentDocumentLink
      WHERE ContentDocumentId IN :docIds
      WITH SYSTEM_MODE
    ]) {
      if (!linksByDoc.containsKey(cdl.ContentDocumentId)) {
        linksByDoc.put(cdl.ContentDocumentId, new Set<Id>());
      }
      linksByDoc.get(cdl.ContentDocumentId).add(cdl.LinkedEntityId);
    }
    return linksByDoc;
  }

  // The indexes whose file is linked to a child of the owner.
  private static List<Integer> ownedThroughChildren(
    List<Integer> candidates,
    List<Id> docIds,
    List<Id> ownerIds,
    Map<Id, Set<Id>> linksByDoc
  ) {
    List<Integer> owned = new List<Integer>();
    if (candidates.isEmpty()) {
      return owned;
    }
    Set<Id> owners = new Set<Id>();
    Set<Id> linked = new Set<Id>();
    for (Integer i : candidates) {
      owners.add(ownerIds[i]);
      linked.addAll(linksByDoc.get(docIds[i]));
    }
    Map<Id, Id> parentByChild = new Map<Id, Id>();
    for (Workflow_Instance__c child : [
      SELECT Id, Parent_Instance__c
      FROM Workflow_Instance__c
      WHERE Parent_Instance__c IN :owners AND Id IN :linked
      WITH SYSTEM_MODE
    ]) {
      parentByChild.put(child.Id, child.Parent_Instance__c);
    }
    for (Integer i : candidates) {
      for (Id entityId : linksByDoc.get(docIds[i])) {
        if (parentByChild.get(entityId) == ownerIds[i]) {
          owned.add(i);
          break;
        }
      }
    }
    return owned;
  }

  /**
   * @description Reads the checksum of each offloaded file that the stored
   * values name. It reads only files that are linked to the owner. A marker of
   * another instance gives no entry. The query does not load the file content.
   * @param storedValues the stored values, which can hold offload markers
   * @param ownerId the instance that must own each file
   * @return a map of document id to checksum. A file with no checksum is left
   * out. The map is empty, with no query, when no value is a marker or the
   * owner is null.
   */
  public static Map<Id, String> ownedChecksums(
    List<String> storedValues,
    Id ownerId
  ) {
    Map<Id, String> checksums = new Map<Id, String>();
    Set<Id> docs = new Set<Id>();
    for (String stored : storedValues) {
      Id docId = markerDocId(stored);
      if (docId != null) {
        docs.add(docId);
      }
    }
    if (docs.isEmpty() || ownerId == null) {
      return checksums;
    }
    Map<Id, Set<Id>> links = linkedEntitiesByDoc(docs);
    Set<Id> owned = new Set<Id>();
    for (Id docId : links.keySet()) {
      if (links.get(docId).contains(ownerId)) {
        owned.add(docId);
      }
    }
    if (owned.isEmpty()) {
      return checksums;
    }
    for (ContentVersion cv : [
      SELECT ContentDocumentId, Checksum
      FROM ContentVersion
      WHERE ContentDocumentId IN :owned AND IsLatest = TRUE
      WITH SYSTEM_MODE
    ]) {
      if (String.isNotBlank(cv.Checksum)) {
        checksums.put(cv.ContentDocumentId, cv.Checksum);
      }
    }
    return checksums;
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
      if (cv.VersionData != null) {
        resolvedByDoc.put(cv.ContentDocumentId, cv.VersionData.toString());
      }
    }
    return resolvedByDoc;
  }

  /**
   * @description Offloads an oversized stored value to a ContentVersion so it
   * fits within field limits: when the text exceeds the inline threshold it is
   * stored as a file and a `{"$attachmentId":...}` marker is returned; otherwise
   * the value is returned unchanged for inline storage. It does not encode. For
   * author data, pass `WorkflowPayloadCodecs.encode(text, kind)`: the offload
   * test then uses the encoded length, and the file holds ciphertext. The file
   * gets `Revenant_Payload_Offload__c = true`. The Storage Footprint panel counts
   * only these files.
   * @param instanceId Id of the owning instance (links the stored document)
   * @param textValue the stored text to offload
   * @param title title/filename for the offloaded ContentVersion
   * @return an offload marker string when stored as a file, else the original text
   */
  public static String savePayloadIfNeeded(
    Id instanceId,
    String textValue,
    String title
  ) {
    return WorkflowBulkOffload.save(
      new List<WorkflowBulkOffload.Item>{
        new WorkflowBulkOffload.Item(instanceId, textValue, title)
      }
    )[0];
  }

  /**
   * @description Links the file of a marker to a new owner, only when the
   * current owner already has the link. A marker that a caller forged does not
   * give access to another file.
   * @param marker the stored value (a non-marker is ignored)
   * @param fromOwnerId the instance that must own the file now
   * @param toOwnerId the instance that gets the link
   * @return true when the method added the link
   */
  public static Boolean shareIfOwned(
    String marker,
    Id fromOwnerId,
    Id toOwnerId
  ) {
    Id docId = markerDocId(marker);
    if (docId == null) {
      return false;
    }
    Set<Id> owners = linksFor(new List<String>{ marker }).get(docId);
    if (owners == null || !owners.contains(fromOwnerId)) {
      return false;
    }
    if (!owners.contains(toOwnerId)) {
      linkToOwner(docId, toOwnerId);
    }
    return true;
  }

  /**
   * @description Links an offloaded file to an instance, so the instance can
   * read it. Use it when a new instance inherits a marker.
   * @param docId the ContentDocument Id of the file
   * @param ownerId the instance that gets the link
   */
  public static void linkToOwner(Id docId, Id ownerId) {
    ContentDocumentLink cdl = new ContentDocumentLink();
    cdl.ContentDocumentId = docId;
    cdl.LinkedEntityId = ownerId;
    cdl.ShareType = 'V';
    cdl.Visibility = 'InternalUsers';
    try {
      Database.insert(cdl, true, AccessLevel.SYSTEM_MODE);
    } catch (DmlException ignored) {
      // Default visibility rejected; retry the link with AllUsers visibility.
      cdl.Visibility = 'AllUsers';
      Database.insert(cdl, true, AccessLevel.SYSTEM_MODE);
    }
  }
}
