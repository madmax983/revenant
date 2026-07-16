/**
 * @description Post-insert result and payload finalization for the bulk workflow
 * start pipeline ({@link WorkflowBulkStartService}). Persists search-attribute
 * rows for freshly-inserted instances, fills the remaining (intra-batch /
 * concurrent-loser) results from a resolved key->Id map, and resolves/persists
 * the input payloads. Extracted from `WorkflowStartService` so the bulk pipeline
 * keeps the mutable `StartOrGetRun` accumulator private to
 * `WorkflowBulkStartService`; these helpers receive the specific collections
 * they need rather than the accumulator. All DML runs in system mode with the
 * original all-or-none semantics preserved.
 */
public inherited sharing class WorkflowBulkStartFinalize {
  /**
   * @description §4b: insert search-attribute rows for the freshly inserted
   * instances.
   * @param insertedInstances the successfully inserted instances (index-aligned)
   * @param insertedReqIndexes the request index for each inserted instance
   * @param requests the original bulk start requests
   */
  public static void insertStartSearchAttributes(
    List<Workflow_Instance__c> insertedInstances,
    List<Integer> insertedReqIndexes,
    List<WorkflowEngine.StartRequest> requests
  ) {
    if (insertedInstances.isEmpty()) {
      return;
    }
    List<Workflow_Search_Attribute__c> attrsToInsert = new List<Workflow_Search_Attribute__c>();
    for (Integer j = 0; j < insertedInstances.size(); j++) {
      WorkflowEngine.StartRequest req = requests[insertedReqIndexes[j]];
      Workflow_Instance__c instance = insertedInstances[j];
      if (req.attributes != null && !req.attributes.isEmpty()) {
        for (String key : req.attributes.keySet()) {
          String val = req.attributes.get(key);
          attrsToInsert.add(
            new Workflow_Search_Attribute__c(
              Workflow_Instance__c = instance.Id,
              Key__c = key,
              Value__c = val,
              Key_Value__c = key + '=' + (val == null ? '' : val)
            )
          );
        }
      }
    }
    if (!attrsToInsert.isEmpty()) {
      Database.insert(attrsToInsert, true, AccessLevel.SYSTEM_MODE);
    }
  }

  /**
   * @description §5a: resolve remaining (intra-batch / concurrent-loser) results
   * by correlation key from the pre-built resolved-Id map.
   * @param requests the original bulk start requests (index-aligned with results)
   * @param results the accumulating results list to fill in place
   * @param resolvedIdByKey normalized key -> resolved instance Id
   */
  public static void fillRemainingStartResults(
    List<WorkflowEngine.StartRequest> requests,
    List<WorkflowEngine.StartResult> results,
    Map<String, Id> resolvedIdByKey
  ) {
    for (Integer i = 0; i < requests.size(); i++) {
      if (requests[i] == null || results[i] != null) {
        continue;
      }
      String normKey = WorkflowEngine.normalizeKey(requests[i].correlationKey);
      if (
        String.isNotBlank(requests[i].correlationKey) &&
        resolvedIdByKey.containsKey(normKey)
      ) {
        results[i] = new WorkflowEngine.StartResult(
          resolvedIdByKey.get(normKey)
        );
      }
    }
  }

  /**
   * @description §6: resolve/persist input payloads for the freshly inserted
   * instances.
   * @param insertedInstances the successfully inserted instances (index-aligned)
   * @param insertedReqIndexes the request index for each inserted instance
   * @param requests the original bulk start requests
   */
  public static void resolveStartInputPayloads(
    List<Workflow_Instance__c> insertedInstances,
    List<Integer> insertedReqIndexes,
    List<WorkflowEngine.StartRequest> requests
  ) {
    for (Integer j = 0; j < insertedInstances.size(); j++) {
      WorkflowEngine.StartRequest req = requests[insertedReqIndexes[j]];
      Workflow_Instance__c instance = insertedInstances[j];
      String inputJson = (req.inputJson != null)
        ? req.inputJson
        : ((req.input != null) ? JSON.serialize(req.input) : null);
      instance.Input__c = WorkflowPayloadOffload.savePayloadIfNeeded(
        instance.Id,
        inputJson,
        'Input_' + instance.Id
      );
    }
    if (!insertedInstances.isEmpty()) {
      Database.update(insertedInstances, true, AccessLevel.SYSTEM_MODE);
    }
  }
}
