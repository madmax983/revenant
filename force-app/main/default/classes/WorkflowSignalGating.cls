/**
 * @description Join-readiness gating for the durable-execution engine's signal
 * wake paths. A suspended parallel parent that is waiting on outstanding child
 * workflows must not be woken by a child-completion/failure signal until every
 * expected child has finished; this class computes that gate. It queries each
 * suspended parent's pending step execution (resolving any offloaded output),
 * groups the parent's children, and reports the parents still gated behind a
 * non-ready join so the caller can suppress their wake and enqueue. Shared by
 * the bulk signal router and the signal-or-start service; all SOQL runs in
 * system mode.
 */
public inherited sharing class WorkflowSignalGating {
  /**
   * @description Holder for the queried/resolved data needed to evaluate whether
   * suspended parents are gated on outstanding children: the pending step
   * execution per parent, the resolved pending-step output per parent, and the
   * child instances grouped by parent.
   */
  private class GatedParentScan {
    Map<Id, Workflow_Step_Execution__c> pendingStepExecs = new Map<Id, Workflow_Step_Execution__c>();
    Map<Id, String> resolvedOutputsByParentId = new Map<Id, String>();
    Map<Id, List<Workflow_Instance__c>> childrenByParentId = new Map<Id, List<Workflow_Instance__c>>();
  }

  /**
   * @description Determines which suspended parents from the candidate set are
   * still gated behind a non-ready parallel join, i.e. are waiting on
   * outstanding child workflows and were signalled only by child
   * completion/failure signals. Such parents must not be woken yet.
   * @param instances the candidate parent instances (may be null/empty)
   * @param signalsByInstanceId the signal names pending per instance this call
   * @return the ids of parents still gated behind a non-ready join
   */
  public static Set<Id> getGatedNonReadyParents(
    List<Workflow_Instance__c> instances,
    Map<Id, Set<String>> signalsByInstanceId
  ) {
    Set<Id> gatedNonReadyParents = new Set<Id>();
    if (instances == null || instances.isEmpty()) {
      return gatedNonReadyParents;
    }

    Set<Id> parentIdsToCheck = collectSuspendedParentIds(instances);
    if (parentIdsToCheck.isEmpty()) {
      return gatedNonReadyParents;
    }

    GatedParentScan scan = queryGatedParentScan(parentIdsToCheck);
    Set<Id> nonReadyParents = collectNonReadyParents(parentIdsToCheck, scan);

    for (Id parentId : nonReadyParents) {
      if (
        WorkflowSignalChildGate.isAllChildSignals(
          signalsByInstanceId.get(parentId)
        )
      ) {
        gatedNonReadyParents.add(parentId);
      }
    }

    return gatedNonReadyParents;
  }

  /**
   * @description Collects the ids of the suspended instances that must be
   * checked for child gating.
   * @param instances the candidate parent instances
   * @return the ids of instances currently in the Suspended status
   */
  private static Set<Id> collectSuspendedParentIds(
    List<Workflow_Instance__c> instances
  ) {
    Set<Id> parentIdsToCheck = new Set<Id>();
    for (Workflow_Instance__c inst : instances) {
      if (inst != null && inst.Status__c == 'Suspended') {
        parentIdsToCheck.add(inst.Id);
      }
    }
    return parentIdsToCheck;
  }

  /**
   * @description Queries and resolves the data needed to evaluate child gating
   * for the given suspended parents: their pending step executions (with
   * resolved outputs) and their child instances grouped by parent.
   * @param parentIdsToCheck the suspended parent ids to scan
   * @return the populated scan holder
   */
  private static GatedParentScan queryGatedParentScan(
    Set<Id> parentIdsToCheck
  ) {
    GatedParentScan scan = new GatedParentScan();
    for (Workflow_Step_Execution__c se : [
      SELECT Id, Workflow_Instance__c, Step_Name__c, Output__c
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c IN :parentIdsToCheck AND Status__c = 'Pending'
      WITH SYSTEM_MODE
    ]) {
      scan.pendingStepExecs.put(se.Workflow_Instance__c, se);
    }

    if (!scan.pendingStepExecs.isEmpty()) {
      List<Id> parentIds = new List<Id>();
      List<String> rawOutputs = new List<String>();
      for (Workflow_Step_Execution__c se : scan.pendingStepExecs.values()) {
        parentIds.add(se.Workflow_Instance__c);
        rawOutputs.add(se.Output__c);
      }
      List<String> resolved = WorkflowPayloadOffload.resolvePayloads(
        rawOutputs
      );
      for (Integer i = 0; i < parentIds.size(); i++) {
        scan.resolvedOutputsByParentId.put(parentIds[i], resolved[i]);
      }
    }

    for (Workflow_Instance__c child : [
      SELECT Id, Parent_Instance__c, Correlation_Key__c, Status__c
      FROM Workflow_Instance__c
      WHERE Parent_Instance__c IN :parentIdsToCheck
      WITH SYSTEM_MODE
    ]) {
      if (!scan.childrenByParentId.containsKey(child.Parent_Instance__c)) {
        scan.childrenByParentId.put(
          child.Parent_Instance__c,
          new List<Workflow_Instance__c>()
        );
      }
      scan.childrenByParentId.get(child.Parent_Instance__c).add(child);
    }

    return scan;
  }

  /**
   * @description Determines which suspended parents still have outstanding
   * (non-finished) expected children, i.e. are not yet ready to wake.
   * @param parentIdsToCheck the suspended parent ids to evaluate
   * @param scan the queried/resolved gating data
   * @return the ids of parents still gated on outstanding children
   */
  private static Set<Id> collectNonReadyParents(
    Set<Id> parentIdsToCheck,
    GatedParentScan scan
  ) {
    Set<Id> nonReadyParents = new Set<Id>();
    for (Id parentId : parentIdsToCheck) {
      Workflow_Step_Execution__c se = scan.pendingStepExecs.get(parentId);
      if (se == null) {
        continue;
      }
      String resolvedOutput = scan.resolvedOutputsByParentId.get(parentId);
      if (String.isBlank(resolvedOutput)) {
        continue;
      }
      Set<String> expectedKeys = WorkflowSignalChildGate.extractExpectedChildKeys(
        resolvedOutput
      );
      if (expectedKeys == null) {
        continue;
      }
      Set<String> finishedKeys = WorkflowSignalChildGate.collectFinishedChildKeys(
        scan.childrenByParentId.get(parentId),
        expectedKeys
      );
      if (!finishedKeys.containsAll(expectedKeys)) {
        nonReadyParents.add(parentId);
      }
    }
    return nonReadyParents;
  }
}
