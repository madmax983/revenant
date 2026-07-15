/**
 * @description Bulk child-workflow spawn orchestrator for the Revenant engine.
 * Drives the bulk-start flow end to end: delegates request validation, correlated
 * dedup and instance insertion to `WorkflowChildBulkPlanner`, then applies input
 * payloads and initial steps and schedules/enqueues or pauses each fresh child.
 * Extracted from `WorkflowEngine`; the resident `WorkflowEngine.normalizeKey` helper
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
          WorkflowEngine.normalizeKey(req.correlationKey)
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

  private static List<Workflow_Instance__c> applyChildInputPayloads(
    ChildStartPlan plan
  ) {
    List<Workflow_Instance__c> instancesToUpdate = new List<Workflow_Instance__c>();
    for (Integer i = 0; i < plan.instances.size(); i++) {
      Workflow_Instance__c inst = plan.instances[i];
      StepResult.ChildRequest req = plan.requests[i];
      inst.Input__c = WorkflowPayloadOffload.savePayloadIfNeeded(
        inst.Id,
        req.inputJson,
        'Input_Child_' + inst.Id
      );
      instancesToUpdate.add(inst);
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
