/**
 * @description Bulk child-workflow spawn orchestrator for the Revenant engine.
 * Drives the bulk-start flow end to end: delegates request validation, correlated
 * dedup and instance insertion to `WorkflowChildBulkPlanner`, then applies input
 * payloads and initial steps and schedules/enqueues or pauses each fresh child.
 * Extracted from `WorkflowEngine`; the resident `WorkflowKeys.normalizeKey` helper
 * and the shared `WorkflowChildService.resolveParentNamespace` lookup are referenced
 * fully qualified. All SOQL/DML executes in system mode.
 */
public inherited sharing class WorkflowChildBulkService {
  /**
   * Parallel arrays pairing each freshly built child instance with the
   * originating ChildRequest, so payload resolution can re-associate them
   * positionally after the bulk insert assigns Ids.
   */
  public class ChildStartPlan {
    public List<Workflow_Instance__c> instances = new List<Workflow_Instance__c>();
    public List<StepResult.ChildRequest> requests = new List<StepResult.ChildRequest>();
  }

  /**
   * @description Starts multiple child workflows under a parent instance in bulk,
   * validating requests, skipping already-existing correlated children, and
   * inserting/scheduling/enqueuing the fresh children.
   * @param parentId the requesting parent instance id
   * @param requests the child requests to start
   */
  public static void startChildWorkflows(
    Id parentId,
    List<StepResult.ChildRequest> requests
  ) {
    if (requests == null || requests.isEmpty()) {
      return;
    }

    String parentNamespace = WorkflowChildService.resolveParentNamespace(
      parentId
    );
    Set<String> correlationKeys = WorkflowChildBulkPlanner.validateChildRequests(
      requests,
      parentNamespace
    );
    Map<String, Workflow_Instance__c> existingByCorrKey = WorkflowChildBulkPlanner.findExistingChildren(
      parentId,
      correlationKeys
    );

    ChildStartPlan plan = new ChildStartPlan();
    for (StepResult.ChildRequest req : requests) {
      if (
        String.isNotBlank(req.correlationKey) &&
        existingByCorrKey.containsKey(
          WorkflowKeys.normalizeKey(req.correlationKey)
        )
      ) {
        continue;
      }
      plan.instances.add(
        WorkflowChildBulkPlanner.buildChildInstance(
          req,
          parentId,
          parentNamespace
        )
      );
      plan.requests.add(req);
    }

    if (plan.instances.isEmpty()) {
      return;
    }

    // Only new children reach this point. If one child breaks its contract,
    // the engine rejects all children (issue #227).
    try {
      WorkflowInputValidator.validateChildStarts(
        plan.requests,
        parentNamespace
      );
    } catch (WorkflowInputException ex) {
      // A sibling that won a race owns its key, and this input is never saved.
      // Drop such children, then check the rest again.
      if (!removeRacedSiblings(plan, parentId)) {
        throw ex;
      }
      if (plan.instances.isEmpty()) {
        return;
      }
      WorkflowInputValidator.validateChildStarts(
        plan.requests,
        parentNamespace
      );
    }

    if (
      !WorkflowChildBulkPlanner.insertChildInstances(plan.instances, parentId)
    ) {
      return;
    }

    List<Workflow_Instance__c> instancesToUpdate = applyChildInputPayloads(
      plan
    );
    insertChildInitialSteps(instancesToUpdate);
    scheduleOrPauseChildren(instancesToUpdate);
    enqueueChildOrchestrators(instancesToUpdate);
  }

  // Drops the children whose key now belongs to a sibling of this parent.
  // Returns true when it dropped at least one child.
  private static Boolean removeRacedSiblings(ChildStartPlan plan, Id parentId) {
    Set<String> keys = new Set<String>();
    for (StepResult.ChildRequest req : plan.requests) {
      if (String.isNotBlank(req.correlationKey)) {
        keys.add(req.correlationKey);
      }
    }
    Map<String, Workflow_Instance__c> existing = WorkflowChildBulkPlanner.findExistingChildren(
      parentId,
      keys
    );
    if (existing.isEmpty()) {
      return false;
    }
    ChildStartPlan kept = new ChildStartPlan();
    for (Integer i = 0; i < plan.requests.size(); i++) {
      String key = plan.requests[i].correlationKey;
      if (
        String.isNotBlank(key) &&
        existing.containsKey(WorkflowKeys.normalizeKey(key))
      ) {
        continue;
      }
      kept.instances.add(plan.instances[i]);
      kept.requests.add(plan.requests[i]);
    }
    Boolean dropped = kept.requests.size() < plan.requests.size();
    plan.instances = kept.instances;
    plan.requests = kept.requests;
    return dropped;
  }

  private static List<Workflow_Instance__c> applyChildInputPayloads(
    ChildStartPlan plan
  ) {
    List<WorkflowBulkOffload.Item> items = new List<WorkflowBulkOffload.Item>();
    for (Integer i = 0; i < plan.instances.size(); i++) {
      Workflow_Instance__c inst = plan.instances[i];
      items.add(
        new WorkflowBulkOffload.Item(
          inst.Id,
          WorkflowPayloadCodecs.encode(
            plan.requests[i].inputJson,
            CodecContext.PayloadKind.WORKFLOW_INPUT
          ),
          'Input_Child_' + inst.Id
        )
      );
    }
    List<String> stored = WorkflowBulkOffload.save(items);
    List<Workflow_Instance__c> instancesToUpdate = new List<Workflow_Instance__c>();
    for (Integer i = 0; i < plan.instances.size(); i++) {
      plan.instances[i].Input__c = stored[i];
      instancesToUpdate.add(plan.instances[i]);
    }
    Database.update(instancesToUpdate, true, AccessLevel.SYSTEM_MODE);
    return instancesToUpdate;
  }

  private static void insertChildInitialSteps(
    List<Workflow_Instance__c> instancesToUpdate
  ) {
    List<Workflow_Step_Execution__c> stepExecsToInsert = new List<Workflow_Step_Execution__c>();
    for (Workflow_Instance__c inst : instancesToUpdate) {
      if (String.isNotBlank(inst.Current_Step__c)) {
        Workflow_Step_Execution__c stepExec = new Workflow_Step_Execution__c();
        stepExec.Workflow_Instance__c = inst.Id;
        stepExec.Step_Name__c = inst.Current_Step__c;
        stepExec.Status__c = 'Pending';
        stepExec.Input__c = inst.Input__c;
        stepExec.Retry_Count__c = 0;
        stepExecsToInsert.add(stepExec);
      }
    }
    if (!stepExecsToInsert.isEmpty()) {
      Database.insert(stepExecsToInsert, true, AccessLevel.SYSTEM_MODE);
    }
  }

  private static void scheduleOrPauseChildren(
    List<Workflow_Instance__c> instancesToUpdate
  ) {
    List<Workflow_Instance__c> instancesToSchedule = new List<Workflow_Instance__c>();
    List<Workflow_Instance__c> instancesToPause = new List<Workflow_Instance__c>();
    Boolean checkPause = WorkflowPauseGate.anyPaused();

    for (Workflow_Instance__c inst : instancesToUpdate) {
      if (
        checkPause &&
        WorkflowPauseGate.isDefinitionPaused(inst.Workflow_Name__c)
      ) {
        inst.Status__c = 'Paused';
        instancesToPause.add(inst);
      } else {
        if (!ConcurrencyGate.isConfigured(inst.Workflow_Name__c)) {
          instancesToSchedule.add(inst);
        } else {
          inst.Concurrency_Parked__c = true;
          instancesToPause.add(inst);
        }
      }
    }

    if (!instancesToPause.isEmpty()) {
      Database.update(instancesToPause, true, AccessLevel.SYSTEM_MODE);
    }

    if (!instancesToSchedule.isEmpty()) {
      WorkflowTimeoutArming.scheduleTimeoutJobsForInstances(
        instancesToSchedule
      );
    }
  }

  private static void enqueueChildOrchestrators(
    List<Workflow_Instance__c> instancesToUpdate
  ) {
    if (Test.isRunningTest()) {
      return;
    }
    List<Id> instanceIdsToEnqueue = new List<Id>();
    for (Workflow_Instance__c inst : instancesToUpdate) {
      if (inst.Status__c != 'Paused') {
        instanceIdsToEnqueue.add(inst.Id);
      }
    }
    if (!instanceIdsToEnqueue.isEmpty()) {
      WorkflowOrchestratorEnqueue.enqueueOrchestrators(instanceIdsToEnqueue);
    }
  }
}
