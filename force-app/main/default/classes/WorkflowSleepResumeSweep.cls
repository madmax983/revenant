/**
 * @description Sleep-resume sweep for the watchdog heartbeat (§2). Resumes
 * suspended instances whose sleep time has elapsed (bounded per heartbeat;
 * backlog drains on subsequent heartbeats), honoring the operator pause gate and
 * concurrency parking, detecting fired timed-waits, and re-driving parallel
 * transient-retry branches.
 *
 * Extracted from WorkflowEngine as part of the watchdog decomposition; driven by
 * WorkflowHeartbeatService. All DML and SOQL run in system mode so the engine can
 * drive workflows regardless of the invoking user's object permissions.
 */
public inherited sharing class WorkflowSleepResumeSweep {
  // Max number of sleeping instances a single heartbeat resumes, to bound the
  // heartbeat's governor usage. Remaining sleepers drain on the next heartbeat.
  @TestVisible
  private static Integer watchdogResumeBatchSize = 200;

  // Mutable accumulator for the sleep-resumption section (§2).
  private class SleepResumeBatch {
    Map<Id, Workflow_Step_Execution__c> latestStepByInstId = new Map<Id, Workflow_Step_Execution__c>();
    List<Id> instanceIds = new List<Id>();
    List<Workflow_Instance__c> instancesToUpdate = new List<Workflow_Instance__c>();
    List<Id> parallelResumeIds = new List<Id>();
    List<Workflow_Step_Execution__c> timedWaitFallbackExecs = new List<Workflow_Step_Execution__c>();
  }

  /**
   * @description Read-accessor for the shared resume batch-size limit so the
   * orphan-reclaim sweep can bound its re-drive query with the same value,
   * called qualified.
   * @return the bounded per-heartbeat resume batch size
   */
  public static Integer resumeBatchSize() {
    return watchdogResumeBatchSize;
  }

  /**
   * @description §2. Process Sleep Resumptions (bounded per heartbeat; backlog
   * drains on subsequent heartbeats so an unbounded suspended-instance backlog
   * cannot blow row/heap limits). Paused definitions are excluded at the SOQL
   * level so paused sleepers cannot fill the bounded batch and starve resumable
   * rows from other workflows (they would be re-selected and skipped every
   * heartbeat). An org-wide '*' pause means nothing is resumable, so the phase is
   * skipped entirely.
   * @param now the heartbeat evaluation instant
   */
  public static void processSleepResumptions(Datetime now) {
    List<Workflow_Instance__c> readyToResume = new List<Workflow_Instance__c>();
    if (!WorkflowPauseGate.wildcardPaused()) {
      Set<String> pausedDefNames = WorkflowPauseGate.pausedNames();
      readyToResume = [
        SELECT
          Id,
          Status__c,
          Sleep_Until__c,
          Async_Job_Id__c,
          Error_Message__c,
          Workflow_Name__c,
          Current_Step__c,
          Concurrency_Parked__c,
          Concurrency_Slot_Held__c,
          (
            SELECT Workflow_Instance__c, Step_Name__c, Output__c, Id, Status__c
            FROM Workflow_Step_Executions__r
            ORDER BY CreatedDate DESC, Id DESC
            LIMIT 1
          )
        FROM Workflow_Instance__c
        WHERE
          Status__c = 'Suspended'
          AND Sleep_Until__c <= :now
          AND Workflow_Name__c NOT IN :pausedDefNames
        WITH SYSTEM_MODE
        LIMIT :watchdogResumeBatchSize
        FOR UPDATE
      ];
    }

    if (readyToResume.isEmpty()) {
      return;
    }

    SleepResumeBatch b = new SleepResumeBatch();
    for (Workflow_Instance__c inst : readyToResume) {
      if (
        inst.Workflow_Step_Executions__r != null &&
        !inst.Workflow_Step_Executions__r.isEmpty()
      ) {
        b.latestStepByInstId.put(inst.Id, inst.Workflow_Step_Executions__r[0]);
      }
    }

    for (Workflow_Instance__c inst : readyToResume) {
      resumeSuspendedInstance(inst, b);
    }

    flushSleepResumptions(b);
  }

  // Persist the resume batch: insert timed-wait fallbacks, flip instances to
  // their resumed status, enqueue orchestrators, and re-drive parallel branches.
  private static void flushSleepResumptions(SleepResumeBatch b) {
    if (!b.timedWaitFallbackExecs.isEmpty()) {
      Database.insert(b.timedWaitFallbackExecs, true, AccessLevel.SYSTEM_MODE);
    }
    if (!b.instancesToUpdate.isEmpty()) {
      for (Workflow_Instance__c inst : b.instancesToUpdate) {
        WorkflowEngine.resumedInstanceIds.add(inst.Id);
      }
      Database.update(b.instancesToUpdate, true, AccessLevel.SYSTEM_MODE);
    }
    // Honor the test opt-out (mirrors the timed-out-step enqueue above) so a
    // suite asserting only the Suspended -> Running wake transition is not
    // carried to completion by a worker draining at Test.stopTest().
    if (!(Test.isRunningTest() && WorkflowEngine.disableQueueableInTest)) {
      WorkflowOrchestratorEnqueue.enqueueOrchestrators(b.instanceIds);
    }
    // For a resumed parallel instance the blank-stepName orchestrator above is a
    // no-op (runStep ignores it for a comma-separated Current_Step__c), so
    // re-drive each branch parked for a transient row-lock retry BY NAME. Scoped
    // to Pending/Running steps carrying Transient_Retry_Count__c > 0 — the
    // durable target the transient-lock backoff persists. handleCrash leaves the
    // row Pending after a rollback, or Running when the synchronous harness calls
    // it without one, so both statuses are matched; genuinely in-flight branches
    // (count 0) and ordinary fan-out steps are left untouched. The actual enqueue
    // honors the test opt-out internally (like the bulk signal path) so the
    // query/re-arm still run under it.
    if (!b.parallelResumeIds.isEmpty()) {
      WorkflowTimeoutReArm.reDriveTransientRetryBranches(
        [
          SELECT
            Id,
            Workflow_Instance__c,
            Step_Name__c,
            Workflow_Instance__r.Workflow_Name__c
          FROM Workflow_Step_Execution__c
          WHERE
            Workflow_Instance__c IN :b.parallelResumeIds
            AND Status__c IN ('Pending', 'Running')
            AND Transient_Retry_Count__c > 0
          WITH SYSTEM_MODE
        ]
      );
    }
  }

  // A suspended instance's resume is held when its definition is paused.
  private static Boolean isDefinitionResumeHeld(Workflow_Instance__c inst) {
    return WorkflowPauseGate.anyPaused() &&
      WorkflowPauseGate.isDefinitionPaused(inst.Workflow_Name__c);
  }

  // Resume a single suspended instance: honor the pause gate and concurrency
  // parking, then flip to the appropriate running/compensating status.
  private static void resumeSuspendedInstance(
    Workflow_Instance__c inst,
    SleepResumeBatch b
  ) {
    // Hold, not drop: if the definition is paused, leave the instance Suspended
    // with Sleep_Until__c intact so it re-fires on the next heartbeat after resume.
    if (isDefinitionResumeHeld(inst)) {
      return;
    }
    // A concurrency-parked sleeper has not yet won an admission slot. Do NOT flip
    // it to Running here: that would leave Running rows holding no slot (violating
    // the status/cap invariant) and hide them from the parked count. Drive it back
    // through the admission gate while leaving it Suspended/parked — the gate flips
    // it to Running on a successful acquire, or re-parks it (bumping Sleep_Until__c
    // into the future) on denial. Leave Sleep_Until__c/Async_Job_Id__c intact so
    // the gate owns the transition; the next heartbeat will not re-select it once
    // a re-park has pushed Sleep_Until__c forward, and a duplicate delivery before
    // then is idempotent at the gate's locked re-read.
    if (
      inst.Concurrency_Parked__c == true &&
      inst.Concurrency_Slot_Held__c != true
    ) {
      b.instanceIds.add(inst.Id);
      return;
    }
    Workflow_Step_Execution__c latestStep = b.latestStepByInstId.get(inst.Id);
    if (
      latestStep != null &&
      latestStep.Step_Name__c != null &&
      latestStep.Step_Name__c.endsWith('_Compensate')
    ) {
      if (
        inst.Error_Message__c != null &&
        inst.Error_Message__c.contains('Cancelled by user')
      ) {
        inst.Status__c = 'Cancelling';
      } else {
        inst.Status__c = 'Compensating';
      }
    } else {
      routeNonCompensatingResume(inst, latestStep, b);
    }
    inst.Sleep_Until__c = null;
    inst.Async_Job_Id__c = null;
    b.instanceIds.add(inst.Id);
    b.instancesToUpdate.add(inst);
  }

  // Non-compensating resume path: detect a fired timed-wait and route to the
  // fallback step, otherwise flip to Running and track parallel branches.
  private static void routeNonCompensatingResume(
    Workflow_Instance__c inst,
    Workflow_Step_Execution__c latestStep,
    SleepResumeBatch b
  ) {
    // Timed-wait detection (issue #35): if the latest step exec carries a
    // $timeoutStep key in its Output, the timer fired for a timed suspend/
    // approval wait. Route to the fallback step instead of re-running the
    // current step. Non-compensating, serial instances only.
    String timedWaitTarget = extractTimedWaitTarget(latestStep);
    Boolean isSerial =
      String.isBlank(inst.Current_Step__c) ||
      !inst.Current_Step__c.contains(',');
    if (String.isNotBlank(timedWaitTarget) && isSerial) {
      // Route to the fallback step: create a new Pending exec (append-only)
      // and advance Current_Step__c. The prior wait exec is never mutated.
      Workflow_Step_Execution__c fallbackExec = new Workflow_Step_Execution__c();
      fallbackExec.Workflow_Instance__c = inst.Id;
      fallbackExec.Step_Name__c = timedWaitTarget;
      fallbackExec.Status__c = 'Pending';
      fallbackExec.Input__c = '{"$timeoutResume":true}';
      fallbackExec.Retry_Count__c = 0;
      fallbackExec.Transient_Retry_Count__c = 0;
      b.timedWaitFallbackExecs.add(fallbackExec);
      inst.Current_Step__c = timedWaitTarget;
    }
    inst.Status__c = 'Running';
    if (
      String.isNotBlank(inst.Current_Step__c) &&
      inst.Current_Step__c.contains(',')
    ) {
      b.parallelResumeIds.add(inst.Id);
    }
  }

  // Extracts the $timeoutStep value from a step exec's Output__c if it is a
  // timed-wait state envelope (issue #35). Returns null for plain SLEEP state,
  // author-supplied JSON, null/blank, and any parse failure.
  private static String extractTimedWaitTarget(
    Workflow_Step_Execution__c stepExec
  ) {
    if (stepExec == null || String.isBlank(stepExec.Output__c)) {
      return null;
    }
    // Cheap gate: the timed-wait marker is always inline (the {"$timeoutStep":..}
    // envelope is tiny and never offloaded), so the raw field already contains
    // the key without needing resolvePayload. This avoids a ContentVersion SOQL
    // per plain-sleeper instance inside the watchdog resume loop.
    if (!stepExec.Output__c.contains('$timeoutStep')) {
      return null;
    }
    return WorkflowPayloadOffload.readJsonMapKey(
      WorkflowPayloadOffload.resolvePayload(stepExec.Output__c),
      '$timeoutStep'
    );
  }
}
