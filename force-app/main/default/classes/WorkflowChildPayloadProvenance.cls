/**
 * @description Checks child-completion payloads before a parent decodes them.
 * Any caller can send a signal named `ChildCompleted:<key>` or
 * `ChildFailed:<key>`, so the signal name proves nothing. A child payload that
 * is still a stored form (an envelope or an offload marker) is trusted only
 * when it is exactly the `Output__c` of a child of the reading instance. A
 * forged stored form (for example ciphertext or a file marker copied from
 * another record) is not resolved or decoded.
 *
 * It queries only when a payload is still a stored form.
 */
public inherited sharing class WorkflowChildPayloadProvenance {
  /**
   * @description Returns the payloads that are safe to resolve and decode. An
   * untrusted stored form becomes null in the output list.
   * @param rawPayloads the child payloads after the signal read
   * @param signalIds the signal row Ids, index-aligned
   * @param childKeys the child keys, index-aligned
   * @return the payloads to resolve, index-aligned; null means do not decode
   */
  public static List<String> trustedOnly(
    List<String> rawPayloads,
    List<Id> signalIds,
    List<String> childKeys
  ) {
    List<String> out = new List<String>(rawPayloads);
    Set<Id> sigIds = new Set<Id>();
    Set<String> keys = new Set<String>();
    for (Integer i = 0; i < rawPayloads.size(); i++) {
      if (isStoredForm(rawPayloads[i])) {
        sigIds.add(signalIds[i]);
        keys.add(childKeys[i]);
      }
    }
    sigIds.remove(null);
    if (keys.isEmpty()) {
      return out;
    }
    Map<String, String> outputByKey = childOutputs(sigIds, keys);
    for (Integer i = 0; i < rawPayloads.size(); i++) {
      String expected = outputByKey.get(normalize(childKeys[i]));
      if (isStoredForm(rawPayloads[i]) && !rawPayloads[i].equals(expected)) {
        out[i] = null;
      }
    }
    return out;
  }

  // Loads the stored outputs of the reading instance's children for the keys.
  // A child key is the child's correlation key, or its Id when the key is
  // blank. Apex String == ignores case, so callers use equals() on the values.
  private static Map<String, String> childOutputs(
    Set<Id> sigIds,
    Set<String> keys
  ) {
    Map<String, String> outputByKey = new Map<String, String>();
    if (sigIds.isEmpty()) {
      return outputByKey;
    }
    Set<Id> idKeys = idsOf(keys);
    for (Workflow_Instance__c child : [
      SELECT Id, Correlation_Key__c, Output__c
      FROM Workflow_Instance__c
      WHERE
        Parent_Instance__c IN (
          SELECT Workflow_Instance__c
          FROM Workflow_Signal__c
          WHERE Id IN :sigIds
        )
        AND (Correlation_Key__c IN :keys
        OR Id IN :idKeys)
      WITH SYSTEM_MODE
    ]) {
      outputByKey.put(normalize(child.Id), child.Output__c);
      if (String.isNotBlank(child.Correlation_Key__c)) {
        outputByKey.put(normalize(child.Correlation_Key__c), child.Output__c);
      }
    }
    return outputByKey;
  }

  // An envelope or an offload marker. Signal reads decode external input one
  // time, so a value that is still a stored form claims to be a child output.
  private static Boolean isStoredForm(String value) {
    return WorkflowPayloadCodecs.isEncoded(value) ||
      (value != null && value.startsWith(WorkflowPayloadCodecs.OFFLOAD_PREFIX));
  }

  private static Set<Id> idsOf(Set<String> keys) {
    Set<Id> ids = new Set<Id>();
    for (String key : keys) {
      if (key != null && key instanceof Id) {
        ids.add(key);
      }
    }
    return ids;
  }

  private static String normalize(String key) {
    return key == null ? null : key.toLowerCase();
  }
}
