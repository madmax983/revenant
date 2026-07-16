/**
 * @description Admission phase of the durable step-execution sequence: the
 * guarded gates a delivery passes before its step-execution row is locked. Routes
 * a live compensation drive to the resident saga logic, parks an operator-paused
 * instance, and enforces the concurrency ceiling by re-reading the instance
 * `FOR UPDATE` and either acquiring a slot (then re-driving) or parking for a
 * later admission re-attempt. This instance `FOR UPDATE` re-read is the FIRST of
 * the two ordered locks (admission before execution). All DML and SOQL run in
 * system mode.
 */
public inherited sharing class WorkflowStepAdmission {
  /**
   * @description Detects a live compensation drive and routes it to the resident
   * `runCompensationStep`. Returns true when the instance was routed so the
   * caller must stop the forward path.
   * @param instance the instance being driven
   * @return true when the delivery was routed to compensation
   */
  public static Boolean routeIfCompensating(Workflow_Instance__c instance) {
    if (!isLiveCompensation(instance)) {
      return false;
    }
    String reassertedStatus = WorkflowCompensationRunner.reassertCompensatingStatus(
      instance
    );
    WorkflowCompensationRunner.runCompensationStep(instance, reassertedStatus);
    return true;
  }

  // A compensation step that SUSPENDed (e.g. waiting on a signal) leaves the
  // instance Suspended; signal() then flips it to Running before re-enqueueing.
  // In either state a latest step ending in '_Compensate' whose base name is on
  // the compensation stack means the instance is still compensating and must
  // route to runCompensationStep, not the forward path.
  private static Boolean isLiveCompensation(Workflow_Instance__c instance) {
    if (
      instance.Status__c == 'Compensating' ||
      instance.Status__c == 'Cancelling'
    ) {
      return true;
    }
    if (instance.Status__c != 'Suspended' && instance.Status__c != 'Running') {
      return false;
    }
    // Only treat a trailing-'_Compensate' latest step as a live compensation
    // when the instance's compensation stack actually holds the matching base
    // step. A normal forward step that happens to be named '<x>_Compensate' and
    // is resumed by signal() (with no -- or unrelated -- stack) must NOT be
    // misrouted. The forward execution of compensatable steps grows the stack
    // too, so a non-empty stack alone is not enough; require the base name on it.
    List<String> compStack = String.isNotBlank(instance.Compensation_Stack__c)
      ? (List<String>) JSON.deserialize(
          instance.Compensation_Stack__c,
          List<String>.class
        )
      : new List<String>();
    if (compStack.isEmpty()) {
      return false;
    }
    return latestStepIsOnCompensationStack(instance.Id, compStack);
  }

  // True when the instance's most recent step execution is a '_Compensate' step
  // whose base name is on the compensation stack.
  private static Boolean latestStepIsOnCompensationStack(
    Id instanceId,
    List<String> compStack
  ) {
    List<Workflow_Step_Execution__c> latestSteps = [
      SELECT Step_Name__c
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c = :instanceId
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC, Id DESC
      LIMIT 1
    ];
    return !latestSteps.isEmpty() &&
      latestSteps[0].Step_Name__c != null &&
      latestSteps[0].Step_Name__c.endsWith('_Compensate') &&
      compStack.contains(latestSteps[0].Step_Name__c.removeEnd('_Compensate'));
  }

  /**
   * @description §2a. Operator pause gate — park at the chain handoff instead of
   * proceeding. Returns true when the instance is parked/paused so the caller
   * must stop.
   * @param instance the instance being driven
   * @return true when the delivery was parked/paused
   */
  public static Boolean parkIfPaused(Workflow_Instance__c instance) {
    Boolean definitionPaused =
      WorkflowPauseGate.anyPaused() &&
      WorkflowPauseGate.isDefinitionPaused(instance.Workflow_Name__c);

    if (!(definitionPaused || instance.Status__c == 'Paused')) {
      return false;
    }
    // Park a not-yet-parked instance whose definition is paused; an
    // already-Paused row is just a no-op until the drain flips it to Running.
    if (definitionPaused && instance.Status__c != 'Paused') {
      instance.Status__c = 'Paused';
      Database.update(instance, true, AccessLevel.SYSTEM_MODE);
    }

    return true;
  }

  /**
   * @description §2b. Concurrency admission gate. Returns true when the delivery
   * was handled here (no-op, parked, or re-driven after acquiring a slot).
   * @param instance the instance being admitted
   * @return true when the delivery was handled by the admission gate
   */
  public static Boolean admitOrParkForConcurrency(
    Workflow_Instance__c instance
  ) {
    if (instance.Concurrency_Slot_Held__c) {
      return false;
    }
    if (ConcurrencyGate.isConfigured(instance.Workflow_Name__c)) {
      return admitConfiguredInstance(instance);
    }
    // Otherwise unbounded (no ceiling): fall through and run exactly as today. If
    // this instance was parked under a ceiling that an admin has since removed or
    // disabled, clear the stale admission-retry markers before running.
    if (instance.Concurrency_Parked__c) {
      instance.Concurrency_Parked__c = false;
      instance.Sleep_Until__c = null;
      instance.Async_Job_Id__c = null;
      Database.update(instance, true, AccessLevel.SYSTEM_MODE);
      // Re-arm the pending step's watchdog deadline that parkForConcurrency cleared,
      // mirroring the successful-admission path above. Without this a re-drive that
      // is delayed or lost (and a CalloutStep, whose pre-exec bookkeeping relies on
      // the watchdog already being armed) would run with no pre-start timeout net.
      // reArmTimeoutsForResume re-arms here because the workflow is now unbounded
      // (isConfigured is false), so it is not treated as a deferred admission.
      WorkflowTimeoutReArm.reArmTimeoutsForResume(
        new List<Workflow_Instance__c>{ instance }
      );
      // Re-drive in a fresh transaction instead of executing the step now: the
      // marker-clear DML above is uncommitted, and a CalloutStep cannot run while
      // uncommitted DML is pending (Salesforce forbids it) — the same reason the
      // admission-acquire path above re-hops. A fresh RUN_STEP re-reads this row
      // (now unparked) and runs the step cleanly.
      if (!(Test.isRunningTest() && WorkflowEngine.disableQueueableInTest)) {
        WorkflowEngine.enqueueResume(instance.Id);
      }

      return true;
    }
    return false;
  }

  // Configured (bounded) admission: re-read under a lock, then acquire a slot and
  // re-drive, or park for a later re-attempt. Always handles the delivery.
  private static Boolean admitConfiguredInstance(
    Workflow_Instance__c instance
  ) {
    Workflow_Instance__c locked = [
      SELECT Concurrency_Slot_Held__c, Status__c
      FROM Workflow_Instance__c
      WHERE Id = :instance.Id
      WITH SYSTEM_MODE
      FOR UPDATE
    ];
    if (locked.Concurrency_Slot_Held__c) {
      // A concurrent delivery already admitted this instance; its re-hop drives
      // the step. This delivery is a safe no-op.
      return true;
    }
    // A concurrent cancel/terminal transition may have landed between the
    // unlocked instance query above and this locked re-read. Acquiring a slot
    // and writing Status__c = 'Running' off the stale forward state would
    // resurrect a finished/cancelled instance, so bail unless it is still
    // forward-runnable. (Compensating/Cancelling/Paused are driven by their own
    // paths, never the admission gate.)
    if (
      locked.Status__c != 'Pending' &&
      locked.Status__c != 'Running' &&
      locked.Status__c != 'Suspended'
    ) {
      return true;
    }

    String resolvedStep = resolveStepForAdmission(instance);

    ConcurrencyGate.AdmissionResult admission = ConcurrencyGate.tryAcquire(
      instance.Workflow_Name__c
    );
    if (admission.admitted) {
      commitSlotAcquisitionAndRedrive(instance, resolvedStep);
      return true;
    }
    // Ceiling full: park and re-attempt admission automatically through the
    // existing sleep/watchdog resume plumbing.
    WorkflowEngine.parkForConcurrency(instance, resolvedStep);
    return true;
  }

  // Resolve the initial step for a fresh start BEFORE consuming a slot, so an
  // unresolvable workflow class fails cleanly here instead of holding a slot that
  // reconciliation would count forever.
  private static String resolveStepForAdmission(Workflow_Instance__c instance) {
    String resolvedStep = instance.Current_Step__c;
    if (String.isNotBlank(resolvedStep)) {
      return resolvedStep;
    }
    Type wfType = WorkflowTypeResolver.resolve(
      instance.Workflow_Name__c,
      WorkflowTypeResolver.extractNamespace(instance.Workflow_Name__c)
    );
    if (wfType == null) {
      throw new WorkflowEngine.WorkflowException(
        'Could not resolve workflow definition class: ' +
        instance.Workflow_Name__c
      );
    }
    return ((WorkflowDefinition) wfType.newInstance()).getInitialStep();
  }

  // Slot acquired: commit the acquire + flag, clear admission-retry markers,
  // re-arm the step's watchdog deadline, and re-drive in a fresh transaction.
  private static void commitSlotAcquisitionAndRedrive(
    Workflow_Instance__c instance,
    String resolvedStep
  ) {
    instance.Concurrency_Slot_Held__c = true;
    instance.Concurrency_Parked__c = false;
    instance.Current_Step__c = resolvedStep;
    instance.Status__c = 'Running';
    instance.Sleep_Until__c = null;
    instance.Async_Job_Id__c = null;
    Database.update(instance, true, AccessLevel.SYSTEM_MODE);
    WorkflowTimeoutReArm.reArmTimeoutsForResume(
      new List<Workflow_Instance__c>{ instance }
    );
    if (!(Test.isRunningTest() && WorkflowEngine.disableQueueableInTest)) {
      WorkflowEngine.enqueueResume(instance.Id);
    }
  }
}
