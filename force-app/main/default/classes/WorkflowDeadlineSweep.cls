/**
 * @description Deadline-expiry sweep for the watchdog heartbeat (§1b). Selects
 * the bounded batch of instances whose execution deadline has passed, aborts
 * their scheduled jobs, appends the audit step, and routes each to compensation
 * or terminal failure — preserving the transition-then-DML batch order and the
 * bounded LIMIT.
 *
 * Extracted from WorkflowEngine; the watchdog entry stays on WorkflowEngine as a
 * thin facade and this sweep is driven by WorkflowHeartbeatService. All DML and
 * SOQL run in system mode so the engine can drive workflows regardless of the
 * invoking user's object permissions.
 */
public inherited sharing class WorkflowDeadlineSweep {
  // Max number of expired instances a single heartbeat fails/compensates, to
  // bound the heartbeat's governor usage. Remaining expiries drain on the next
  // heartbeat.
  @TestVisible
  private static Integer watchdogDeadlineBatchSize = 100;

  // Mutable accumulator for the exceeded-deadline section (§1b).
  private class DeadlineBatch {
    List<Workflow_Step_Execution__c> deadlineStepsToInsert = new List<Workflow_Step_Execution__c>();
    List<Workflow_Instance__c> instancesToFail = new List<Workflow_Instance__c>();
    List<Id> deadlineOrchestratorIds = new List<Id>();
  }

  /**
   * The per-instance plan for pre-creating first compensation steps: the valid
   * instances (those with a parseable, non-empty compensation stack) and, per
   * instance id, the top-of-stack active step name and its derived compensation
   * step log name.
   */
  private class CompStepPlan {
    Set<Id> instanceIds = new Set<Id>();
    List<Workflow_Instance__c> validInstances = new List<Workflow_Instance__c>();
    Map<Id, String> activeStepNames = new Map<Id, String>();
    Map<Id, String> compStepNames = new Map<Id, String>();
  }

  /**
   * @description §1b. Process Exceeded Execution Deadlines (bounded per
   * heartbeat).
   * @param now the heartbeat evaluation instant
   * @param watchdogTerminalInstances accumulates instances transitioned to a
   * terminal state, for the deferred end-of-heartbeat lifecycle publish
   */
  public static void processExceededDeadlines(
    Datetime now,
    List<Workflow_Instance__c> watchdogTerminalInstances
  ) {
    List<Workflow_Instance__c> expiredInstances = [
      SELECT
        Id,
        Name,
        Status__c,
        Deadline_At__c,
        Compensation_Stack__c,
        Error_Message__c,
        Workflow_Name__c,
        Correlation_Key__c,
        Root_Correlation_Key__c,
        Current_Step__c,
        Failure_Category__c
      FROM Workflow_Instance__c
      WHERE
        Status__c IN ('Pending', 'Running', 'Suspended')
        AND Deadline_At__c <= :now
      WITH SYSTEM_MODE
      LIMIT :watchdogDeadlineBatchSize
      FOR UPDATE
    ];

    if (expiredInstances.isEmpty()) {
      return;
    }

    DeadlineBatch batch = new DeadlineBatch();

    // Bulk abort all scheduled jobs for all expired instances
    Set<Id> expiredInstanceIds = new Set<Id>();
    for (Workflow_Instance__c inst : expiredInstances) {
      expiredInstanceIds.add(inst.Id);
    }
    WorkflowOrchestratorEnqueue.abortScheduledJobs(expiredInstanceIds);

    for (Workflow_Instance__c inst : expiredInstances) {
      applyDeadlineExpiry(inst, batch, watchdogTerminalInstances);
    }

    if (!batch.deadlineStepsToInsert.isEmpty()) {
      Database.insert(
        batch.deadlineStepsToInsert,
        true,
        AccessLevel.SYSTEM_MODE
      );
    }

    preCreateFirstCompensationSteps(expiredInstances);

    if (!batch.instancesToFail.isEmpty()) {
      Database.update(batch.instancesToFail, true, AccessLevel.SYSTEM_MODE);
      WorkflowTimeoutSupport.notifyTerminalFailures(batch.instancesToFail);
    }

    alertDeadlineFailures(batch.instancesToFail);

    WorkflowTimeoutSupport.enqueueOrchestratorsBounded(
      batch.deadlineOrchestratorIds
    );
  }

  // Alert on exactly the deadline-expired instances that reached terminal Failed.
  private static void alertDeadlineFailures(
    List<Workflow_Instance__c> instancesToFail
  ) {
    for (Workflow_Instance__c inst : instancesToFail) {
      if (inst.Status__c == 'Failed') {
        WorkflowAlertManager.sendAlert(inst, inst.Error_Message__c);
      }
    }
  }

  // Apply the deadline-exceeded transition to a single instance: append the
  // audit step and route to compensation or terminal failure.
  private static void applyDeadlineExpiry(
    Workflow_Instance__c inst,
    DeadlineBatch batch,
    List<Workflow_Instance__c> watchdogTerminalInstances
  ) {
    inst.Sleep_Until__c = null;
    inst.Async_Job_Id__c = null;

    // Check if there are compensations to run
    Boolean hasCompensations = false;
    List<String> stack = new List<String>();
    if (String.isNotBlank(inst.Compensation_Stack__c)) {
      stack = (List<String>) JSON.deserialize(
        inst.Compensation_Stack__c,
        List<String>.class
      );
      hasCompensations = !stack.isEmpty();
    }

    // Append a new failed step execution record (audit trail)
    Workflow_Step_Execution__c deadlineStep = new Workflow_Step_Execution__c(
      Workflow_Instance__c = inst.Id,
      Step_Name__c = 'Workflow_Deadline',
      Status__c = 'Failed',
      Error_Details__c = 'Execution deadline exceeded',
      Retry_Count__c = 0
    );
    batch.deadlineStepsToInsert.add(deadlineStep);

    if (hasCompensations) {
      inst.Status__c = 'Compensating';
      inst.Error_Message__c = 'Execution deadline exceeded';
      batch.instancesToFail.add(inst);
      batch.deadlineOrchestratorIds.add(inst.Id);
    } else {
      inst.Status__c = 'Failed';
      inst.Failure_Category__c = WorkflowEngine.CAT_TIMEOUT;
      inst.Error_Message__c = 'Execution deadline exceeded';
      batch.instancesToFail.add(inst);
      watchdogTerminalInstances.add(inst);
    }
  }

  // Pre-create the first compensation step-exec logs (bulk) for the deadline-
  // expired instances entering compensation.
  private static void preCreateFirstCompensationSteps(
    List<Workflow_Instance__c> instances
  ) {
    if (instances == null || instances.isEmpty()) {
      return;
    }

    CompStepPlan plan = planCompensationSteps(instances);
    if (plan.instanceIds.isEmpty()) {
      return;
    }

    // Query existing compensation steps in bulk to avoid duplicates.
    Set<String> existingKeys = queryExistingCompKeys(plan.instanceIds);

    // Query original executions to map Input/Output in bulk.
    Map<String, Workflow_Step_Execution__c> latestOrigExecs = buildLatestOrigExecs(
      plan.instanceIds
    );

    List<Workflow_Step_Execution__c> stepsToInsert = buildCompStepsToInsert(
      plan,
      existingKeys,
      latestOrigExecs
    );

    if (!stepsToInsert.isEmpty()) {
      Database.insert(stepsToInsert, true, AccessLevel.SYSTEM_MODE);
    }
  }

  /**
   * Builds the compensation-step plan from the candidate instances, skipping any
   * with a blank, unparseable, or empty compensation stack. For each valid
   * instance it records the top-of-stack active step and its '_Compensate' log
   * name.
   * @param instances the candidate instances entering compensation
   * @return the per-instance compensation-step plan
   */
  private static CompStepPlan planCompensationSteps(
    List<Workflow_Instance__c> instances
  ) {
    CompStepPlan plan = new CompStepPlan();
    for (Workflow_Instance__c instance : instances) {
      if (String.isBlank(instance.Compensation_Stack__c)) {
        continue;
      }
      List<String> stack;
      try {
        stack = (List<String>) JSON.deserialize(
          instance.Compensation_Stack__c,
          List<String>.class
        );
      } catch (Exception ex) {
        continue;
      }
      if (stack == null || stack.isEmpty()) {
        continue;
      }
      String activeStepName = stack[stack.size() - 1];
      String compensationStepLogName = activeStepName + '_Compensate';

      plan.instanceIds.add(instance.Id);
      plan.validInstances.add(instance);
      plan.activeStepNames.put(instance.Id, activeStepName);
      plan.compStepNames.put(instance.Id, compensationStepLogName);
    }
    return plan;
  }

  /**
   * Queries existing compensation step executions for the instances in bulk and
   * returns their '{instanceId}:{stepName}' keys, used to avoid creating
   * duplicate compensation steps.
   * @param instanceIds the instances whose existing compensation steps are read
   * @return the set of existing '{instanceId}:{stepName}' keys
   */
  private static Set<String> queryExistingCompKeys(Set<Id> instanceIds) {
    // Bind the LIKE pattern so the escaped underscore ('\_', matching a literal
    // '_') lives in an Apex string literal rather than inline SOQL.
    String compensateSuffixPattern = '%\\_Compensate';
    List<Workflow_Step_Execution__c> existingCompSteps = [
      SELECT Workflow_Instance__c, Step_Name__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c IN :instanceIds
        AND Step_Name__c LIKE :compensateSuffixPattern
      WITH SYSTEM_MODE
    ];
    Set<String> existingKeys = new Set<String>();
    for (Workflow_Step_Execution__c step : existingCompSteps) {
      existingKeys.add(step.Workflow_Instance__c + ':' + step.Step_Name__c);
    }
    return existingKeys;
  }

  /**
   * Queries the step executions for the instances in bulk and maps the latest
   * (newest-first) execution per '{instanceId}:{stepName}' key, used to carry
   * the original step's Input/Output onto its compensation step.
   * @param instanceIds the instances whose step executions are read
   * @return the latest execution per '{instanceId}:{stepName}' key
   */
  private static Map<String, Workflow_Step_Execution__c> buildLatestOrigExecs(
    Set<Id> instanceIds
  ) {
    List<Workflow_Step_Execution__c> originalExecs = [
      SELECT Workflow_Instance__c, Step_Name__c, Input__c, Output__c
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c IN :instanceIds
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC, Id DESC
    ];

    Map<String, Workflow_Step_Execution__c> latestOrigExecs = new Map<String, Workflow_Step_Execution__c>();
    for (Workflow_Step_Execution__c exec : originalExecs) {
      String key = exec.Workflow_Instance__c + ':' + exec.Step_Name__c;
      if (!latestOrigExecs.containsKey(key)) {
        latestOrigExecs.put(key, exec);
      }
    }
    return latestOrigExecs;
  }

  /**
   * Builds the Pending compensation step executions to insert, skipping any that
   * already exist, and carrying the original step's Input/Output where available.
   * @param plan the per-instance compensation-step plan
   * @param existingKeys the '{instanceId}:{stepName}' keys already present
   * @param latestOrigExecs the latest original execution per step key
   * @return the compensation step executions to insert
   */
  private static List<Workflow_Step_Execution__c> buildCompStepsToInsert(
    CompStepPlan plan,
    Set<String> existingKeys,
    Map<String, Workflow_Step_Execution__c> latestOrigExecs
  ) {
    List<Workflow_Step_Execution__c> stepsToInsert = new List<Workflow_Step_Execution__c>();
    for (Workflow_Instance__c instance : plan.validInstances) {
      String compName = plan.compStepNames.get(instance.Id);
      String key = instance.Id + ':' + compName;
      if (existingKeys.contains(key)) {
        continue;
      }

      String activeName = plan.activeStepNames.get(instance.Id);
      String origKey = instance.Id + ':' + activeName;
      Workflow_Step_Execution__c origExec = latestOrigExecs.get(origKey);

      Workflow_Step_Execution__c compStepExec = new Workflow_Step_Execution__c();
      compStepExec.Workflow_Instance__c = instance.Id;
      compStepExec.Step_Name__c = compName;
      compStepExec.Status__c = 'Pending';
      compStepExec.Input__c = (origExec != null) ? origExec.Input__c : null;
      compStepExec.Output__c = (origExec != null) ? origExec.Output__c : null;
      compStepExec.Retry_Count__c = 0;
      stepsToInsert.add(compStepExec);
    }
    return stepsToInsert;
  }
}
