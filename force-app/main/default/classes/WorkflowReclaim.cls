/**
 * @description Orphan-instance reclaim phase for the Revenant engine. When the
 * watchdog heartbeat confirms a set of `Workflow_Instance__c` runs whose async
 * jobs are gone, this class resets their in-flight step executions to `Pending`,
 * clears the stale async job id, writes operator-intervention audit logs and
 * re-enqueues orchestrators so the runs resume. All DML and SOQL execute in
 * system mode so reclaim proceeds regardless of the invoking user's object
 * permissions. Extracted from `WorkflowEngine`; the watchdog calls
 * {@link WorkflowReclaim#reclaimOrphanedInstances} directly. The pure planning
 * helpers live on {@link WorkflowReclaimPlanner} so each cohesive phase stays
 * within its own complexity budget.
 */
public inherited sharing class WorkflowReclaim {
  /**
   * @description Mutable accumulator threaded through the reclaim phase helpers
   * (across `WorkflowReclaim` and `WorkflowReclaimPlanner`) so each helper stays
   * within the parameter and complexity budgets.
   */
  public class ReclaimState {
    /** @description Ids of the orphaned instances being reclaimed. */
    public Set<Id> instanceIds = new Set<Id>();
    /** @description Union of every target step name to be reset. */
    public Set<String> allTargetStepNames = new Set<String>();
    /** @description Target step names to reset, keyed by instance id. */
    public Map<Id, List<String>> targetStepsByInstanceId = new Map<Id, List<String>>();
    /** @description Whether each instance carries pending compensations. */
    public Map<Id, Boolean> hasCompensationsByInstanceId = new Map<Id, Boolean>();
    /** @description Latest step execution per instance:step name key. */
    public Map<String, Workflow_Step_Execution__c> latestStepByName = new Map<String, Workflow_Step_Execution__c>();
    /** @description Instances whose step-execution reset failed to persist. */
    public Set<Id> failedInstanceIds = new Set<Id>();
    /** @description Instances whose async-job clear persisted successfully. */
    public Set<Id> succeededInstanceIds = new Set<Id>();
  }

  /**
   * @description Reclaims a batch of orphaned instances: plans the target steps,
   * locks and resets the latest step executions, clears the async job id, writes
   * audit logs and re-enqueues orchestrators. Called by the watchdog heartbeat
   * once orphans have been confirmed as locked.
   * @param orphanedInstances the confirmed orphaned instances to reclaim
   */
  public static void reclaimOrphanedInstances(
    List<Workflow_Instance__c> orphanedInstances
  ) {
    ReclaimState state = new ReclaimState();
    WorkflowReclaimPlanner.buildReclaimPlan(orphanedInstances, state);
    lockLatestReclaimSteps(state);
    Map<Id, Workflow_Step_Execution__c> stepsToResetMap = collectReclaimStepsToReset(
      orphanedInstances,
      state
    );
    resetReclaimSteps(stepsToResetMap, state);
    clearReclaimAsyncJobIds(orphanedInstances, state);
    writeReclaimAuditLogs(orphanedInstances, state);
    enqueueReclaimOrchestrators(orphanedInstances, state);
  }

  /**
   * @description Query the latest step executions for the target steps and lock
   * them FOR UPDATE, storing the resolved map on the shared state.
   * @param state the shared reclaim accumulator to populate
   */
  private static void lockLatestReclaimSteps(ReclaimState state) {
    if (state.allTargetStepNames.isEmpty()) {
      return;
    }
    Set<Id> instanceIds = state.instanceIds;
    Set<String> allTargetStepNames = state.allTargetStepNames;
    // Query step executions to reset: first identify latest step execution IDs
    for (Workflow_Step_Execution__c se : [
      SELECT
        Id,
        Workflow_Instance__c,
        Step_Name__c,
        Status__c,
        Retry_Count__c,
        Error_Details__c,
        Timeout_At__c,
        CPU_Time_Ms__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c IN :instanceIds
        AND Step_Name__c IN :allTargetStepNames
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC, Id DESC
    ]) {
      String key = se.Workflow_Instance__c + ':' + se.Step_Name__c;
      if (!state.latestStepByName.containsKey(key)) {
        state.latestStepByName.put(key, se);
      }
    }

    // Then lock those specific records using FOR UPDATE
    Set<Id> stepIdsToLock = new Set<Id>();
    for (Workflow_Step_Execution__c se : state.latestStepByName.values()) {
      stepIdsToLock.add(se.Id);
    }
    if (!stepIdsToLock.isEmpty()) {
      for (Workflow_Step_Execution__c se : [
        SELECT
          Id,
          Workflow_Instance__c,
          Step_Name__c,
          Status__c,
          Retry_Count__c,
          Error_Details__c,
          Timeout_At__c,
          CPU_Time_Ms__c
        FROM Workflow_Step_Execution__c
        WHERE Id IN :stepIdsToLock
        WITH SYSTEM_MODE
        FOR UPDATE
      ]) {
        String key = se.Workflow_Instance__c + ':' + se.Step_Name__c;
        state.latestStepByName.put(key, se);
      }
    }
  }

  /**
   * @description Build the map of step executions whose status must be reset to
   * Pending.
   * @param orphanedInstances the orphaned instances being reclaimed
   * @param state the shared reclaim accumulator
   * @return step executions to reset, keyed by their id
   */
  private static Map<Id, Workflow_Step_Execution__c> collectReclaimStepsToReset(
    List<Workflow_Instance__c> orphanedInstances,
    ReclaimState state
  ) {
    Map<Id, Workflow_Step_Execution__c> stepsToResetMap = new Map<Id, Workflow_Step_Execution__c>();
    for (Workflow_Instance__c inst : orphanedInstances) {
      List<String> targetStepNames = state.targetStepsByInstanceId.get(inst.Id);
      for (String targetStepName : targetStepNames) {
        String key = inst.Id + ':' + targetStepName;
        Workflow_Step_Execution__c stepExec = state.latestStepByName.get(key);
        if (
          stepExec != null &&
          stepExec.Status__c != 'Completed' &&
          stepExec.Status__c != 'OperatorSkipped'
        ) {
          stepExec.Status__c = 'Pending';
          stepExec.Retry_Count__c = 0;
          stepExec.Error_Details__c = null;
          stepExec.Timeout_At__c = null;
          stepExec.CPU_Time_Ms__c = null;
          stepsToResetMap.put(stepExec.Id, stepExec);
        }
      }
    }
    return stepsToResetMap;
  }

  /**
   * @description Persist the step-execution resets, recording instances whose
   * reset failed.
   * @param stepsToResetMap step executions to reset, keyed by id
   * @param state the shared reclaim accumulator to populate with failures
   */
  private static void resetReclaimSteps(
    Map<Id, Workflow_Step_Execution__c> stepsToResetMap,
    ReclaimState state
  ) {
    if (stepsToResetMap.isEmpty()) {
      return;
    }
    List<Workflow_Step_Execution__c> stepsList = stepsToResetMap.values();
    Database.SaveResult[] stepSRs = Database.update(
      stepsList,
      false,
      AccessLevel.SYSTEM_MODE
    );
    for (Integer i = 0; i < stepSRs.size(); i++) {
      if (!stepSRs[i].isSuccess()) {
        state.failedInstanceIds.add(stepsList[i].Workflow_Instance__c);
      }
    }
  }

  /**
   * @description Clear the async job id on reclaimable instances, tracking which
   * persisted.
   * @param orphanedInstances the orphaned instances being reclaimed
   * @param state the shared reclaim accumulator to populate with successes
   */
  private static void clearReclaimAsyncJobIds(
    List<Workflow_Instance__c> orphanedInstances,
    ReclaimState state
  ) {
    List<Workflow_Instance__c> instancesToUpdate = new List<Workflow_Instance__c>();
    for (Workflow_Instance__c inst : orphanedInstances) {
      if (!state.failedInstanceIds.contains(inst.Id)) {
        inst.Async_Job_Id__c = null;
        instancesToUpdate.add(inst);
      }
    }
    if (instancesToUpdate.isEmpty()) {
      return;
    }
    Database.SaveResult[] instSRs = Database.update(
      instancesToUpdate,
      false,
      AccessLevel.SYSTEM_MODE
    );
    for (Integer i = 0; i < instSRs.size(); i++) {
      if (instSRs[i].isSuccess()) {
        state.succeededInstanceIds.add(instancesToUpdate[i].Id);
      }
    }
  }

  /**
   * @description Emit operator-intervention audit logs for successfully
   * reclaimed instances.
   * @param orphanedInstances the orphaned instances being reclaimed
   * @param state the shared reclaim accumulator identifying successes
   */
  private static void writeReclaimAuditLogs(
    List<Workflow_Instance__c> orphanedInstances,
    ReclaimState state
  ) {
    List<Workflow_Log__c> auditLogs = new List<Workflow_Log__c>();
    for (Workflow_Instance__c inst : orphanedInstances) {
      if (!state.succeededInstanceIds.contains(inst.Id)) {
        continue;
      }
      String stepDetail = String.isNotBlank(inst.Current_Step__c)
        ? inst.Current_Step__c
        : '(initial step)';
      auditLogs.add(
        new Workflow_Log__c(
          Workflow_Instance__c = inst.Id,
          Workflow_Name__c = inst.Workflow_Name__c,
          Correlation_Key__c = inst.Correlation_Key__c,
          Log_Type__c = 'OperatorIntervention',
          Message__c = 'Auto-reclaimed orphaned instance from step: ' +
            stepDetail,
          Outcome__c = 'Success',
          Level__c = 'INFO',
          Fire_Time__c = DateTime.now()
        )
      );
    }
    if (!auditLogs.isEmpty()) {
      Database.insert(auditLogs, false, AccessLevel.SYSTEM_MODE);
    }
  }

  /**
   * @description Re-enqueue orchestrators for reclaimed instances in a bulk
   * fashion.
   * @param orphanedInstances the orphaned instances being reclaimed
   * @param state the shared reclaim accumulator identifying successes
   */
  private static void enqueueReclaimOrchestrators(
    List<Workflow_Instance__c> orphanedInstances,
    ReclaimState state
  ) {
    List<WorkflowEngine.OrchestratorRequest> requests = new List<WorkflowEngine.OrchestratorRequest>();
    for (Workflow_Instance__c inst : orphanedInstances) {
      if (!state.succeededInstanceIds.contains(inst.Id)) {
        continue;
      }
      requests.addAll(
        WorkflowReclaimPlanner.buildReclaimOrchestratorRequests(inst, state)
      );
    }

    if (!requests.isEmpty()) {
      try {
        WorkflowEngine.enqueueOrchestrators(requests);
      } catch (Exception ignored) {
        // Best-effort re-enqueue; the next watchdog heartbeat re-drives on failure.
      }
    }
  }
}
