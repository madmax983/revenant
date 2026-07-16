/**
 * @description Wake-and-enqueue phase for the durable-execution engine's bulk
 * signal-or-start. Computes the join-readiness gate for the active existing
 * instances that received a fresh signal, flips the eligible suspended
 * (admitted, non-gated) instances to Running (persisting that update and
 * disarming their wait deadline), and enqueues the woken instances exactly once:
 * a forward parallel instance goes through the bulk resume path, everything else
 * via the orchestrator, both under the resident enqueue guards. Join readiness is
 * delegated to `WorkflowSignalGating`; the resume/enqueue core and enqueue guards
 * stay resident on `WorkflowEngine`. All DML/SOQL runs in system mode.
 */
public inherited sharing class WorkflowSignalOrStartWake {
  /**
   * @description Computes the join-readiness gate, flips eligible suspended
   * instances to Running, and enqueues the woken instances.
   * @param run the signal-or-start accumulator (wake sets populated/consumed)
   */
  public static void wakeSignalOrStartInstances(
    WorkflowSignalOrStartService.SignalOrStartRun run
  ) {
    Map<Id, Set<String>> signalsByInstanceId = buildSignalsByInstanceId(run);

    List<Workflow_Instance__c> activeInstancesList = new List<Workflow_Instance__c>();
    for (Id instId : run.activeInstIdsToWake) {
      Workflow_Instance__c inst = run.existingInstances.get(instId);
      if (inst != null) {
        activeInstancesList.add(inst);
      }
    }
    run.gatedNonReadyParents = WorkflowSignalGating.getGatedNonReadyParents(
      activeInstancesList,
      signalsByInstanceId
    );

    collectSignalOrStartWakes(run);
    enqueueSignalOrStartWakes(run);
  }

  // Map each request's instance to the set of signal names it received.
  private static Map<Id, Set<String>> buildSignalsByInstanceId(
    WorkflowSignalOrStartService.SignalOrStartRun run
  ) {
    Map<Id, Set<String>> signalsByInstanceId = new Map<Id, Set<String>>();
    List<WorkflowEngine.SignalOrStartRequest> requests = run.requests;
    List<WorkflowEngine.StartResult> startResults = run.startResults;
    for (Integer i = 0; i < requests.size(); i++) {
      WorkflowEngine.SignalOrStartRequest req = requests[i];
      WorkflowEngine.StartResult res = startResults[i];
      if (res == null) {
        continue;
      }
      Id instanceId = res.instanceId;
      if (!signalsByInstanceId.containsKey(instanceId)) {
        signalsByInstanceId.put(instanceId, new Set<String>());
      }
      if (String.isNotBlank(req.signalName)) {
        signalsByInstanceId.get(instanceId).add(req.signalName);
      }
    }
    return signalsByInstanceId;
  }

  // Determine which woken instances flip to Running (persisting that update) and
  // which are eligible to enqueue, honoring the join-readiness gate.
  private static void collectSignalOrStartWakes(
    WorkflowSignalOrStartService.SignalOrStartRun run
  ) {
    for (Id instId : run.activeInstIdsToWake) {
      collectSignalOrStartWakeForInstance(run, instId);
    }
    if (!run.instancesToUpdate.isEmpty()) {
      Database.update(run.instancesToUpdate, true, AccessLevel.SYSTEM_MODE);
    }
  }

  // Wake decision for a single active instance: only a fresh signal wakes it; a
  // suspended, admitted, non-gated instance flips to Running.
  private static void collectSignalOrStartWakeForInstance(
    WorkflowSignalOrStartService.SignalOrStartRun run,
    Id instId
  ) {
    // Only wake if a fresh signal actually landed (i.e. not a duplicate signal)
    if (!run.instancesWithFreshSignal.contains(instId)) {
      return;
    }
    Workflow_Instance__c inst = run.existingInstances.get(instId);
    if (inst == null) {
      return;
    }

    // If the instance is suspended, change status to Running and clear Sleep_Until__c
    if (inst.Status__c == 'Suspended') {
      // Skip if concurrency-parked and doesn't hold slot
      if (isConcurrencyParkedUnadmitted(inst)) {
        return;
      }
      if (run.gatedNonReadyParents.contains(instId)) {
        return;
      }
      inst.Status__c = 'Running';
      inst.Sleep_Until__c = null;
      run.instancesToUpdate.add(inst);
    }
    if (!run.gatedNonReadyParents.contains(instId)) {
      run.instancesToWake.add(inst);
    }
  }

  // Enqueue the woken instances exactly once (parallel instances via bulk resume).
  private static void enqueueSignalOrStartWakes(
    WorkflowSignalOrStartService.SignalOrStartRun run
  ) {
    List<Id> instanceIdsToEnqueue = new List<Id>();
    List<Workflow_Instance__c> parallelInstances = new List<Workflow_Instance__c>();

    for (Workflow_Instance__c inst : run.instancesToWake) {
      Boolean isCompensatingInst =
        inst.Status__c == 'Compensating' ||
        inst.Status__c == 'Cancelling';

      if (
        !isCompensatingInst &&
        String.isNotBlank(inst.Current_Step__c) &&
        inst.Current_Step__c.contains(',')
      ) {
        parallelInstances.add(inst);
      } else if (!WorkflowEngine.enqueuedInstanceIds.contains(inst.Id)) {
        WorkflowEngine.enqueuedInstanceIds.add(inst.Id);
        instanceIdsToEnqueue.add(inst.Id);
      }
    }

    if (!instanceIdsToEnqueue.isEmpty()) {
      WorkflowOrchestratorEnqueue.enqueueOrchestrators(instanceIdsToEnqueue);
    }
    if (!parallelInstances.isEmpty()) {
      WorkflowEngine.enqueueResumeBulk(parallelInstances);
    }
  }

  // True when an instance is concurrency-parked without holding a slot.
  private static Boolean isConcurrencyParkedUnadmitted(
    Workflow_Instance__c inst
  ) {
    return inst.Concurrency_Parked__c == true &&
      inst.Concurrency_Slot_Held__c != true;
  }
}
