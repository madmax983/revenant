/**
 * @description Post-insert activation for the bulk workflow start pipeline
 * ({@link WorkflowBulkStartService}). Applies the operator pause gate and the
 * concurrency-bounded timeout-deferral gate to freshly-inserted instances,
 * seeds their initial `Workflow_Step_Execution__c` logs, and schedules timeout
 * jobs plus enqueues orchestrators for the eligible (non-parked) instances.
 * Mirrors the scalar admission gates in `WorkflowScalarStartService.doStart`.
 * Extracted from `WorkflowStartService` so the bulk pipeline keeps the mutable
 * `StartOrGetRun` accumulator private to `WorkflowBulkStartService`; these
 * helpers receive the specific collections they need. All DML runs in system
 * mode.
 */
public inherited sharing class WorkflowBulkStartActivation {
  /**
   * @description Operator pause gate (bulk path): instances whose definition is
   * paused are parked at start. They get a Pending initial step with NO timeout
   * clock and are excluded from timeout scheduling and the initial enqueue,
   * mirroring the scalar doStart.
   * @param insertedInstances the freshly-inserted instances to gate
   * @param parkedIds out: Ids of instances parked by the pause gate
   * @param instancesToPark out: instances whose parked status must be persisted
   */
  public static void applyStartPauseGate(
    List<Workflow_Instance__c> insertedInstances,
    Set<Id> parkedIds,
    List<Workflow_Instance__c> instancesToPark
  ) {
    if (!WorkflowPauseGate.anyPaused()) {
      return;
    }
    for (Workflow_Instance__c instance : insertedInstances) {
      if (WorkflowPauseGate.isDefinitionPaused(instance.Workflow_Name__c)) {
        instance.Status__c = 'Paused';
        parkedIds.add(instance.Id);
        instancesToPark.add(instance);
      }
    }
  }

  /**
   * @description Concurrency-bounded workflows defer the initial timeout clock
   * until the admission gate wins a slot (mirrors doStart). A bounded first step
   * is enqueued so its RUN_STEP reaches the gate, but a still-Pending overflow
   * item sitting in the event/queue backlog during a burst would be failed by the
   * timeout sweep before it ever reaches the gate to park. Admission re-arms the
   * timeout via reArmTimeoutsForResume. isConfigured is memoized per name, so
   * this is bulk-safe.
   * @param insertedInstances the freshly-inserted instances to gate
   * @param parkedIds Ids already parked by the pause gate (skip re-marking)
   * @param deferTimeoutIds out: Ids whose initial timeout is deferred to admission
   */
  public static void applyStartConcurrencyGate(
    List<Workflow_Instance__c> insertedInstances,
    Set<Id> parkedIds,
    Set<Id> deferTimeoutIds
  ) {
    List<Workflow_Instance__c> deferredToMark = new List<Workflow_Instance__c>();
    for (Workflow_Instance__c instance : insertedInstances) {
      if (ConcurrencyGate.isConfigured(instance.Workflow_Name__c)) {
        deferTimeoutIds.add(instance.Id);
        // Durable awaiting-admission marker (see doStart): the pre-start watchdog
        // keys its null-deadline skip off this, not the live CMDT, so a ceiling added
        // later cannot silence a genuine unbounded pre-start watchdog. Cleared on
        // admission. Parked-at-start instances are handled by instancesToPark below.
        if (!parkedIds.contains(instance.Id)) {
          deferredToMark.add(
            new Workflow_Instance__c(
              Id = instance.Id,
              Concurrency_Parked__c = true
            )
          );
        }
      }
    }
    if (!deferredToMark.isEmpty()) {
      Database.update(deferredToMark, true, AccessLevel.SYSTEM_MODE);
    }
  }

  /**
   * @description §7: construct initial Step Execution logs for the inserted
   * instances, arming the timeout clock only for non-parked, non-deferred starts.
   * @param insertedInstances the freshly-inserted instances to seed
   * @param parkedIds Ids parked by the pause gate (no timeout clock)
   * @param deferTimeoutIds Ids deferred by the concurrency gate (no timeout clock)
   */
  public static void buildInitialStepExecs(
    List<Workflow_Instance__c> insertedInstances,
    Set<Id> parkedIds,
    Set<Id> deferTimeoutIds
  ) {
    List<Workflow_Step_Execution__c> stepExecs = new List<Workflow_Step_Execution__c>();
    for (Workflow_Instance__c instance : insertedInstances) {
      if (String.isBlank(instance.Current_Step__c)) {
        continue;
      }
      Workflow_Step_Execution__c stepExec = new Workflow_Step_Execution__c();
      stepExec.Workflow_Instance__c = instance.Id;
      stepExec.Step_Name__c = instance.Current_Step__c;
      stepExec.Status__c = 'Pending';
      stepExec.Input__c = instance.Input__c;
      stepExec.Retry_Count__c = 0;
      // No timeout clock for a parked step (see doStart) or a bounded start awaiting
      // admission — either would otherwise pollute the watchdog timeout batch or fail
      // a still-Pending bounded start before admission. Resume/admission re-establishes it.
      if (
        !parkedIds.contains(instance.Id) &&
        !deferTimeoutIds.contains(instance.Id)
      ) {
        Integer timeout = WorkflowStepTimeoutConfig.getStepTimeoutSeconds(
          instance.Current_Step__c,
          WorkflowTypeResolver.extractNamespace(instance.Workflow_Name__c)
        );
        if (timeout != null && timeout > 0) {
          stepExec.Timeout_At__c = DateTime.now().addSeconds(timeout);
        }
      }
      stepExecs.add(stepExec);
    }
    if (!stepExecs.isEmpty()) {
      Database.insert(stepExecs, true, AccessLevel.SYSTEM_MODE);
    }
  }

  /**
   * @description §8: schedule timeout jobs for non-parked, non-deferred instances
   * and enqueue orchestrators for all non-parked instances.
   * @param insertedInstances the freshly-inserted instances to activate
   * @param parkedIds Ids parked by the pause gate (skipped entirely)
   * @param deferTimeoutIds Ids whose timeout is deferred to admission
   */
  public static void scheduleAndEnqueueStarts(
    List<Workflow_Instance__c> insertedInstances,
    Set<Id> parkedIds,
    Set<Id> deferTimeoutIds
  ) {
    List<Workflow_Instance__c> instancesToSchedule = new List<Workflow_Instance__c>();
    List<Id> instanceIds = new List<Id>();
    for (Workflow_Instance__c instance : insertedInstances) {
      if (parkedIds.contains(instance.Id)) {
        continue;
      }
      instanceIds.add(instance.Id);
      if (!deferTimeoutIds.contains(instance.Id)) {
        instancesToSchedule.add(instance);
      }
    }
    if (!instancesToSchedule.isEmpty()) {
      WorkflowTimeoutArming.scheduleTimeoutJobsForInstances(
        instancesToSchedule
      );
    }
    if (!instanceIds.isEmpty()) {
      WorkflowOrchestratorEnqueue.enqueueOrchestrators(instanceIds);
    }
  }
}
