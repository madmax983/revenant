/**
 * @description Append-only `_Compensate` step-execution log management: seeds a
 * fresh Pending retry attempt for a resumed rollback (`appendCompensationRetryStep`,
 * guarded so an in-flight attempt is never duplicated) and, during a live drive,
 * locks the latest attempt `FOR UPDATE` and builds (or reuses) the step-execution
 * for the current top-of-stack step (`prepareCompensationStepExec`), deriving the
 * capture-once visit count in Apex. All DML and SOQL run in system mode.
 */
public inherited sharing class WorkflowCompensationStepLog {
  /**
   * Inserts a new Pending compensation step-execution log for the current top of the
   * rollback stack, unless a non-terminal (Pending/Running/Retrying) attempt already
   * exists. Unlike preCreateFirstCompensationStep, it does NOT short-circuit on a
   * prior terminal (Failed) attempt — that record is preserved and a fresh attempt is
   * appended, keeping the audit trail append-only while letting the rollback resume.
   * @param instance the instance whose compensation is being retried
   * @param stack the compensation stack whose top step is re-logged
   */
  public static void appendCompensationRetryStep(
    Workflow_Instance__c instance,
    List<String> stack
  ) {
    if (stack == null || stack.isEmpty()) {
      return;
    }
    String activeStepName = stack[stack.size() - 1];
    String compensationStepLogName = activeStepName + '_Compensate';

    // Nothing to append when there is no instance to log against or no step
    // name to compensate; a resumed rollback with missing context is a no-op.
    // These guards also dominate the SOQL binds in insertCompensationRetryStep,
    // which is only reachable from here.
    if (instance.Id == null) {
      return;
    }
    if (activeStepName == null) {
      return;
    }
    if (compensationStepLogName == null) {
      return;
    }

    // Only the latest attempt is read (existing[0]) for idempotency and to seed
    // the next retry, so LIMIT 1 avoids loading every historical attempt's inline
    // Captured_Values__c payload into heap on a repeatedly operator-resumed
    // compensation.
    List<Workflow_Step_Execution__c> existing = [
      SELECT Id, Status__c, Input__c, Output__c, Captured_Values__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :instance.Id
        AND Step_Name__c = :compensationStepLogName
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC, Id DESC
      LIMIT 1
    ];

    // If an attempt is already in flight, do not stack a duplicate (idempotency).
    if (isCompensationAttemptInFlight(existing)) {
      return;
    }

    insertCompensationRetryStep(instance, activeStepName, existing);
  }

  /**
   * Determines whether the latest compensation-step attempt is still in flight.
   * @param existing the latest compensation-step attempt (LIMIT 1, may be empty)
   * @return true when the latest attempt is Pending/Running/Retrying (in flight)
   */
  private static Boolean isCompensationAttemptInFlight(
    List<Workflow_Step_Execution__c> existing
  ) {
    if (existing.isEmpty()) {
      return false;
    }
    String latestStatus = existing[0].Status__c;
    return latestStatus == 'Pending' ||
      latestStatus == 'Running' ||
      latestStatus == 'Retrying';
  }

  /**
   * Seeds and inserts the appended compensation retry step. Prefers any checkpoint
   * the failed compensation already saved (a YIELD stores progress in its own
   * Output__c) so a resumed compensation continues from where it left off, falling
   * back to the original forward execution's input/output (the initial undo
   * context) when the failed attempt has no saved state. Carries the failed
   * attempt's capture-once values forward (append-only) so a resumed compensation
   * replays the same once() values instead of re-invoking their producers.
   * @param instance the compensating instance
   * @param activeStepName the forward step name being compensated
   * @param existing the latest compensation-step attempt (LIMIT 1, may be empty)
   */
  private static void insertCompensationRetryStep(
    Workflow_Instance__c instance,
    String activeStepName,
    List<Workflow_Step_Execution__c> existing
  ) {
    List<Workflow_Step_Execution__c> originalExecs = [
      SELECT Input__c, Output__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :instance.Id
        AND Step_Name__c = :activeStepName
        AND Status__c = 'Completed'
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC, Id DESC
      LIMIT 1
    ];
    Database.insert(
      buildCompensationRetryStep(
        instance.Id,
        activeStepName,
        existing.isEmpty() ? null : existing[0],
        originalExecs.isEmpty() ? null : originalExecs[0]
      ),
      true,
      AccessLevel.SYSTEM_MODE
    );
  }

  /**
   * Builds the appended compensation retry step. Seeding rules are documented on
   * insertCompensationRetryStep.
   * @param instanceId the compensating instance
   * @param activeStepName the forward step name being compensated
   * @param latest the latest compensation-step attempt, or null
   * @param forward the latest forward execution, or null
   * @return the new Pending compensation step log (not inserted)
   */
  private static Workflow_Step_Execution__c buildCompensationRetryStep(
    Id instanceId,
    String activeStepName,
    Workflow_Step_Execution__c latest,
    Workflow_Step_Execution__c forward
  ) {
    String forwardInput = forward != null ? forward.Input__c : null;
    String forwardOutput = forward != null ? forward.Output__c : null;

    String priorInput = (latest != null && String.isNotBlank(latest.Input__c))
      ? latest.Input__c
      : forwardInput;
    String checkpointOutput = (latest != null &&
      String.isNotBlank(latest.Output__c))
      ? latest.Output__c
      : forwardOutput;
    String priorCaptures = (latest != null &&
      String.isNotBlank(latest.Captured_Values__c))
      ? latest.Captured_Values__c
      : null;

    Workflow_Step_Execution__c compStepExec = new Workflow_Step_Execution__c();
    compStepExec.Workflow_Instance__c = instanceId;
    compStepExec.Step_Name__c = activeStepName + '_Compensate';
    compStepExec.Status__c = 'Pending';
    compStepExec.Input__c = priorInput;
    compStepExec.Output__c = checkpointOutput;
    compStepExec.Captured_Values__c = priorCaptures;
    compStepExec.Retry_Count__c = 0;
    return compStepExec;
  }

  /**
   * Set-based appendCompensationRetryStep (issue #94): for each instance, appends a
   * fresh Pending attempt for the top of its compensation stack with the same
   * rules. The SOQL/DML cost is constant in the instance count. It reads the
   * payload of the latest attempt only, as the single-instance path does.
   * @param instances the instances whose stalled rollback resumes
   */
  public static void appendCompensationRetrySteps(
    List<Workflow_Instance__c> instances
  ) {
    Map<Id, String> activeById = new Map<Id, String>();
    for (Workflow_Instance__c instance : instances) {
      if (
        instance.Id == null || String.isBlank(instance.Compensation_Stack__c)
      ) {
        continue;
      }
      List<String> stack = (List<String>) JSON.deserialize(
        instance.Compensation_Stack__c,
        List<String>.class
      );
      if (!stack.isEmpty() && stack[stack.size() - 1] != null) {
        activeById.put(instance.Id, stack[stack.size() - 1]);
      }
    }
    if (activeById.isEmpty()) {
      return;
    }

    Set<String> compNames = new Set<String>();
    for (String active : activeById.values()) {
      compNames.add(active + '_Compensate');
    }
    Map<String, Workflow_Step_Execution__c> latestAttempt = latestExecs(
      activeById.keySet(),
      compNames,
      false
    );
    Map<String, Workflow_Step_Execution__c> latestForward = latestExecs(
      activeById.keySet(),
      new Set<String>(activeById.values()),
      true
    );

    List<Workflow_Step_Execution__c> toInsert = new List<Workflow_Step_Execution__c>();
    for (Id instanceId : activeById.keySet()) {
      String active = activeById.get(instanceId);
      Workflow_Step_Execution__c latest = latestAttempt.get(
        instanceId + '|' + active + '_Compensate'
      );
      // If an attempt is already in flight, do not stack a duplicate (idempotency).
      if (
        latest != null &&
        isCompensationAttemptInFlight(
          new List<Workflow_Step_Execution__c>{ latest }
        )
      ) {
        continue;
      }
      toInsert.add(
        buildCompensationRetryStep(
          instanceId,
          active,
          latest,
          latestForward.get(instanceId + '|' + active)
        )
      );
    }
    if (!toInsert.isEmpty()) {
      Database.insert(toInsert, true, AccessLevel.SYSTEM_MODE);
    }
  }

  /**
   * @description Latest step execution per (instance | step name). It reads the
   * Ids of all attempts first. Then it reads the payload of the latest attempt
   * only. Shared with WorkflowCompensation.preCreateFirstCompensationSteps.
   * @param instanceIds the instances to read
   * @param stepNames the step names to read
   * @param completedOnly true to consider only Completed executions
   * @return the latest execution by "instanceId|stepName"
   */
  public static Map<String, Workflow_Step_Execution__c> latestExecs(
    Set<Id> instanceIds,
    Set<String> stepNames,
    Boolean completedOnly
  ) {
    Map<String, Id> latestIdByKey = new Map<String, Id>();
    for (
      Workflow_Step_Execution__c exec : completedOnly
        ? completedIdRows(instanceIds, stepNames)
        : allIdRows(instanceIds, stepNames)
    ) {
      String key = exec.Workflow_Instance__c + '|' + exec.Step_Name__c;
      if (!latestIdByKey.containsKey(key)) {
        latestIdByKey.put(key, exec.Id);
      }
    }
    Map<String, Workflow_Step_Execution__c> latestByKey = new Map<String, Workflow_Step_Execution__c>();
    if (latestIdByKey.isEmpty()) {
      return latestByKey;
    }
    Set<Id> latestIds = new Set<Id>(latestIdByKey.values());
    for (Workflow_Step_Execution__c exec : [
      SELECT
        Workflow_Instance__c,
        Step_Name__c,
        Status__c,
        Input__c,
        Output__c,
        Captured_Values__c
      FROM Workflow_Step_Execution__c
      WHERE Id IN :latestIds
      WITH SYSTEM_MODE
    ]) {
      latestByKey.put(
        exec.Workflow_Instance__c + '|' + exec.Step_Name__c,
        exec
      );
    }
    return latestByKey;
  }

  // Id-only rows of every execution, newest first.
  private static List<Workflow_Step_Execution__c> allIdRows(
    Set<Id> instanceIds,
    Set<String> stepNames
  ) {
    return [
      SELECT Id, Workflow_Instance__c, Step_Name__c
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c IN :instanceIds AND Step_Name__c IN :stepNames
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC, Id DESC
    ];
  }

  // Id-only rows of the Completed executions, newest first.
  private static List<Workflow_Step_Execution__c> completedIdRows(
    Set<Id> instanceIds,
    Set<String> stepNames
  ) {
    return [
      SELECT Id, Workflow_Instance__c, Step_Name__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c IN :instanceIds
        AND Step_Name__c IN :stepNames
        AND Status__c = 'Completed'
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC, Id DESC
    ];
  }

  /**
   * @description Loads/locks the compensation step execution `FOR UPDATE`,
   * re-queries the instance under the lock, and builds (or short-circuits) the
   * step exec. Returns false when an early-exit branch handled the run and the
   * caller should stop. Public so the runner's drive can prepare the locked
   * step-exec before invoking compensate().
   * @param run the compensation run accumulator that receives the prepared step-exec
   * @return true when a step-exec is ready to execute; false when an early-exit
   * branch already handled the run
   */
  public static Boolean prepareCompensationStepExec(
    WorkflowCompensationRunner.CompensationRun run
  ) {
    Workflow_Instance__c instance = run.instance;
    String compensationStepLogName = run.compensationStepLogName;
    // Load all executions (no long text) so compensateVisit can be derived in Apex
    // without an extra COUNT() SOQL query. The locked requery reads the long text.
    // Captured_Values__c is selected only on the single-row FOR UPDATE requery
    // below, not on this all-rows visit-count read, to avoid loading every
    // historical capture payload into heap (see the forward runStep path).
    List<Workflow_Step_Execution__c> stepExecs = [
      SELECT Id, Status__c, Retry_Count__c, Step_Name__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :instance.Id
        AND Step_Name__c = :compensationStepLogName
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC, Id DESC
    ];

    run.compensateVisit = countCompensateVisits(stepExecs);

    if (!stepExecs.isEmpty()) {
      stepExecs = [
        SELECT
          Id,
          Workflow_Instance__c,
          Status__c,
          Input__c,
          Output__c,
          Retry_Count__c,
          Step_Name__c,
          Captured_Values__c
        FROM Workflow_Step_Execution__c
        WHERE Id = :stepExecs[0].Id
        WITH SYSTEM_MODE
        FOR UPDATE
      ];
    }
    run.stepExecs = stepExecs;

    // Re-query the instance after acquiring the lock on the step execution to get the most up-to-date committed state
    List<Workflow_Instance__c> freshInstances = [
      SELECT
        Id,
        Status__c,
        Compensation_Stack__c,
        Definition_Version__c,
        Workflow_Name__c,
        Input__c,
        Correlation_Key__c,
        Root_Correlation_Key__c,
        Error_Message__c,
        Previous_Run_At__c
      FROM Workflow_Instance__c
      WHERE Id = :instance.Id
      WITH SYSTEM_MODE
      LIMIT 1
    ];
    if (freshInstances.isEmpty()) {
      throw new WorkflowEngine.WorkflowException(
        'Workflow instance not found: ' + instance.Id
      );
    }
    instance = freshInstances[0];
    run.instance = instance;

    // A signal-resumed compensation: runStep detected the rollback but DEFERRED
    // the Suspended/Running -> Compensating status DML (so a CalloutStep callout
    // stays legal), so the re-queried status is still Suspended/Running. Restore
    // the in-memory compensating phase runStep computed so the guard below and the
    // terminal-status decisions use the correct phase; the DML is committed later
    // (before compensate() for an ordinary step, after it for a CalloutStep). Only
    // restore from Suspended/Running -- a status another transaction drove to a
    // terminal/failed value is left intact so the guard can early-exit on it.
    if (
      run.reassertedStatus != null &&
      (instance.Status__c == 'Suspended' ||
      instance.Status__c == 'Running')
    ) {
      instance.Status__c = run.reassertedStatus;
      instance.Async_Job_Id__c = null;
    }

    // Check early exit conditions for instance status
    if (
      instance.Status__c != 'Compensating' &&
      instance.Status__c != 'Cancelling'
    ) {
      return false; // Already completed compensation or aborted
    }

    return buildCompensationStepExec(run);
  }

  // Count prior compensate visits (Compensated/Completed executions) in Apex.
  private static Integer countCompensateVisits(
    List<Workflow_Step_Execution__c> stepExecs
  ) {
    Integer compensateVisit = 0;
    for (Workflow_Step_Execution__c exec : stepExecs) {
      if (exec.Status__c == 'Compensated' || exec.Status__c == 'Completed') {
        compensateVisit++;
      }
    }
    return compensateVisit;
  }

  // Build a fresh compensation step exec, or reuse the locked one. Returns false
  // when the locked exec is already terminal and the run was advanced/enqueued.
  private static Boolean buildCompensationStepExec(
    WorkflowCompensationRunner.CompensationRun run
  ) {
    Workflow_Instance__c instance = run.instance;
    List<Workflow_Step_Execution__c> stepExecs = run.stepExecs;
    Workflow_Step_Execution__c stepExec;
    if (stepExecs.isEmpty()) {
      stepExec = new Workflow_Step_Execution__c();
      stepExec.Workflow_Instance__c = instance.Id;
      stepExec.Step_Name__c = run.compensationStepLogName;
      stepExec.Status__c = 'Running';
      stepExec.Retry_Count__c = 0;

      // Retrieve the original step execution to get inputs/outputs
      List<Workflow_Step_Execution__c> originalExecs = [
        SELECT Input__c, Output__c
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :run.forwardSourceInstanceId
          AND Step_Name__c = :run.activeStepName
          AND Status__c = 'Completed'
        WITH SYSTEM_MODE
        ORDER BY CreatedDate DESC, Id DESC
        LIMIT 1
      ];

      stepExec.Input__c = !originalExecs.isEmpty()
        ? originalExecs[0].Input__c
        : null;
      stepExec.Output__c = !originalExecs.isEmpty()
        ? originalExecs[0].Output__c
        : null;
    } else {
      stepExec = stepExecs[0];
      if (
        stepExec.Status__c == 'Completed' ||
        stepExec.Status__c == 'Compensated' ||
        stepExec.Status__c == 'Failed' ||
        stepExec.Status__c == 'Cancelled'
      ) {
        WorkflowCompensationRunner.finalizeAlreadyCompensatedStep(run);
        return false;
      }
      stepExec.Status__c = 'Running';
    }
    run.stepExec = stepExec;
    return true;
  }
}
