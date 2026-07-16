/**
 * @description Operator "resume past step" intervention for the Revenant engine
 * (entry point and preconditions). Lets an operator resolve a `Failed`
 * `Workflow_Instance__c` by supplying the failed step's output and advancing
 * forward execution past it. This class locks the failed instance and step
 * execution (FOR UPDATE), validates and normalizes the step name, records the
 * skip as an `OperatorSkipped` step execution and writes an operator-intervention
 * audit log, then hands the shared {@link ResumeSkipRun} accumulator to
 * {@link WorkflowOperatorSkipAdvance#advanceAfterSkip} to advance the workflow —
 * all inside a savepoint so a failure rolls the intervention back atomically.
 * Every DML and SOQL runs in system mode. Extracted from `WorkflowEngine`;
 * callers invoke {@link WorkflowOperatorSkip#resumePastStep} directly. The
 * advancement logic is split across {@link WorkflowOperatorSkipAdvance},
 * {@link WorkflowOperatorSkipParallel} and
 * {@link WorkflowOperatorSkipParallelResume} so each cohesive phase stays within
 * its own complexity budget.
 */
public inherited sharing class WorkflowOperatorSkip {
  /**
   * @description Mutable accumulator threaded through the resume-past-step phase
   * helpers (across `WorkflowOperatorSkip`, `WorkflowOperatorSkipAdvance`,
   * `WorkflowOperatorSkipParallel` and `WorkflowOperatorSkipParallelResume`) so
   * each helper stays within the parameter and complexity budgets.
   */
  public class ResumeSkipRun {
    /** @description The locked failed instance being resumed. */
    public Workflow_Instance__c instance;
    /** @description Id of the failed instance being resumed. */
    public Id instanceId;
    /** @description The normalized name of the step being skipped. */
    public String stepName;
    /** @description Operator-supplied resolved output for the skipped step. */
    public String suppliedOutputJson;
    /** @description The locked latest execution of the skipped step. */
    public Workflow_Step_Execution__c latestExec;
    /** @description The recorded OperatorSkipped step execution. */
    public Workflow_Step_Execution__c skipExec;
    /** @description The resolved workflow definition. */
    public WorkflowDefinition def;
    /** @description Active parallel branch step names, when parallel. */
    public List<String> activeParallelSteps;
    /** @description Latest execution per active parallel step name. */
    public Map<String, Workflow_Step_Execution__c> latestParallelMap;
  }

  /**
   * @description Operator action to resume a failed instance past a failed step
   * by supplying that step's resolved output and resuming forward execution.
   * @param instanceId Id of the failed instance to resume
   * @param stepName name of the failed step being resolved
   * @param suppliedOutputJson operator-supplied resolved output for that step
   */
  public static void resumePastStep(
    Id instanceId,
    String stepName,
    String suppliedOutputJson
  ) {
    if (instanceId == null) {
      throw new WorkflowEngine.WorkflowException('Instance ID is required.');
    }
    if (String.isBlank(stepName)) {
      throw new WorkflowEngine.WorkflowException('Step name is required.');
    }

    // 1. Fetch and lock instance state + 2. Validate status
    Workflow_Instance__c instance = lockFailedInstanceForSkip(instanceId);

    // 3. Validate step is currently active and normalize casing to match definition exactly
    stepName = validateAndNormalizeSkipStep(instance, stepName);

    // 4. Retrieve latest step execution with row lock (FOR UPDATE)
    Workflow_Step_Execution__c latestExec = lockLatestFailedStepExec(
      instanceId,
      stepName
    );

    // 5. Parse and validate supplied output JSON
    validateSuppliedSkipOutput(suppliedOutputJson);

    ResumeSkipRun run = new ResumeSkipRun();
    run.instance = instance;
    run.instanceId = instanceId;
    run.stepName = stepName;
    run.suppliedOutputJson = suppliedOutputJson;
    run.latestExec = latestExec;

    Savepoint sp = Database.setSavepoint();
    try {
      // 6. Record skip as a new Step Execution row
      recordOperatorSkip(run);
      // 7. Log operator intervention
      logOperatorSkipIntervention(run);
      // 8. Determine next step and advance
      WorkflowOperatorSkipAdvance.advanceAfterSkip(run);
    } catch (Exception ex) {
      Database.rollback(sp);
      throw ex;
    }
  }

  /**
   * @description Fetch/lock the instance and require `Failed` status for a
   * resume-past-step.
   * @param instanceId Id of the instance being resumed
   * @return the locked `Failed` instance
   */
  private static Workflow_Instance__c lockFailedInstanceForSkip(Id instanceId) {
    List<Workflow_Instance__c> instances = [
      SELECT
        Id,
        Name,
        Workflow_Name__c,
        Status__c,
        Current_Step__c,
        Input__c,
        Correlation_Key__c,
        Root_Correlation_Key__c,
        Parent_Instance__c,
        Compensation_Stack__c,
        Definition_Version__c,
        Previous_Run_At__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
      WITH SYSTEM_MODE
      FOR UPDATE
    ];

    if (instances.isEmpty()) {
      throw new WorkflowEngine.WorkflowException(
        'Workflow instance not found: ' + instanceId
      );
    }
    Workflow_Instance__c instance = instances[0];

    if (instance.Status__c != 'Failed') {
      throw new WorkflowEngine.WorkflowException(
        'Resume past step is only allowed for instances in Failed state. Current status: ' +
        instance.Status__c
      );
    }
    return instance;
  }

  /**
   * @description Confirm the requested step is the active/expected step,
   * returning the definition-normalized casing. Throws when the step is not
   * resumable.
   * @param instance the locked failed instance
   * @param stepName the operator-supplied step name to validate
   * @return the definition-normalized step name
   */
  private static String validateAndNormalizeSkipStep(
    Workflow_Instance__c instance,
    String stepName
  ) {
    String normalized = matchStepNameCandidate(
      instance.Current_Step__c,
      stepName
    );
    if (normalized == null) {
      throw new WorkflowEngine.WorkflowException(
        'Step ' +
          stepName +
          ' is not the active/expected step for this instance: ' +
          instance.Current_Step__c
      );
    }
    return normalized;
  }

  /**
   * @description Resolve the definition-normalized casing for `stepName` within
   * `currentStep` (which may be a comma-separated parallel-branch list). Returns
   * null when the step is not among the active steps.
   * @param currentStep the instance's current step (possibly comma-separated)
   * @param stepName the operator-supplied step name
   * @return the matched normalized step name, or null when not active
   */
  private static String matchStepNameCandidate(
    String currentStep,
    String stepName
  ) {
    if (String.isBlank(currentStep)) {
      return null;
    }
    if (!currentStep.contains(',')) {
      return currentStep.equalsIgnoreCase(stepName) ? currentStep : null;
    }
    for (String s : currentStep.split(',')) {
      if (s.trim().equalsIgnoreCase(stepName)) {
        return s.trim();
      }
    }
    return null;
  }

  /**
   * @description Retrieve and FOR UPDATE-lock the latest execution for the step,
   * requiring it to be in `Failed` status before it can be operator-skipped.
   * @param instanceId Id of the instance being resumed
   * @param stepName the normalized failed step name
   * @return the locked `Failed` step execution
   */
  private static Workflow_Step_Execution__c lockLatestFailedStepExec(
    Id instanceId,
    String stepName
  ) {
    List<Workflow_Step_Execution__c> stepExecsWithoutLock = [
      SELECT Id
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c = :instanceId AND Step_Name__c = :stepName
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC, Id DESC
      LIMIT 1
    ];
    if (stepExecsWithoutLock.isEmpty()) {
      throw new WorkflowEngine.WorkflowException(
        'No execution record found for step: ' + stepName
      );
    }
    Id latestStepExecId = stepExecsWithoutLock[0].Id;

    List<Workflow_Step_Execution__c> stepExecs = [
      SELECT Id, Status__c, Input__c, Retry_Count__c, Transient_Retry_Count__c
      FROM Workflow_Step_Execution__c
      WHERE Id = :latestStepExecId
      WITH SYSTEM_MODE
      FOR UPDATE
    ];
    Workflow_Step_Execution__c latestExec = stepExecs[0];
    if (latestExec.Status__c != 'Failed') {
      throw new WorkflowEngine.WorkflowException(
        'Step ' +
          stepName +
          ' cannot be skipped because it is not in Failed status. Current status: ' +
          latestExec.Status__c
      );
    }
    return latestExec;
  }

  /**
   * @description Validate operator-supplied output JSON: size, reserved markers,
   * parseability.
   * @param suppliedOutputJson the operator-supplied output JSON to validate
   */
  private static void validateSuppliedSkipOutput(String suppliedOutputJson) {
    if (String.isBlank(suppliedOutputJson)) {
      return;
    }
    if (suppliedOutputJson.length() > 250000) {
      throw new WorkflowEngine.WorkflowException(
        'Supplied output size exceeds maximum allowed limit of 250KB.'
      );
    }
    if (suppliedOutputJson.contains('"$attachmentId"')) {
      throw new WorkflowEngine.WorkflowException(
        'Operator-supplied payload cannot contain reserved "$attachmentId" markers.'
      );
    }
    try {
      JSON.deserializeUntyped(suppliedOutputJson);
    } catch (Exception ex) {
      throw new WorkflowEngine.WorkflowException(
        'Supplied output is not valid JSON: ' + ex.getMessage()
      );
    }
  }

  /**
   * @description Record the operator skip as a new `OperatorSkipped` step
   * execution row.
   * @param run the resume-past-step accumulator
   */
  private static void recordOperatorSkip(ResumeSkipRun run) {
    Workflow_Step_Execution__c skipExec = new Workflow_Step_Execution__c();
    skipExec.Workflow_Instance__c = run.instanceId;
    skipExec.Step_Name__c = run.stepName;
    skipExec.Status__c = 'OperatorSkipped';
    skipExec.Retry_Count__c = 0;
    skipExec.Transient_Retry_Count__c = 0;
    skipExec.Input__c = run.latestExec.Input__c;
    skipExec.Output__c = WorkflowPayloadOffload.savePayloadIfNeeded(
      run.instanceId,
      run.suppliedOutputJson,
      'Output_' + run.stepName.replaceAll('[^a-zA-Z0-9]', '_')
    );
    Database.insert(skipExec, true, AccessLevel.SYSTEM_MODE);
    run.skipExec = skipExec;
  }

  /**
   * @description Write the operator-intervention audit log for the skip.
   * @param run the resume-past-step accumulator
   */
  private static void logOperatorSkipIntervention(ResumeSkipRun run) {
    Workflow_Instance__c instance = run.instance;
    String suppliedOutputJson = run.suppliedOutputJson;
    String msg =
      'User ' +
      UserInfo.getUserName() +
      ' (' +
      UserInfo.getName() +
      ') skipped step ' +
      run.stepName +
      ' on instance ' +
      instance.Name +
      ' (Correlation Key: ' +
      instance.Correlation_Key__c +
      ') providing output: ' +
      (suppliedOutputJson != null &&
        suppliedOutputJson.length() > 500
        ? suppliedOutputJson.substring(0, 500) + '...'
        : suppliedOutputJson);

    Workflow_Log__c interventionLog = new Workflow_Log__c(
      Workflow_Instance__c = run.instanceId,
      Workflow_Name__c = instance.Workflow_Name__c,
      Correlation_Key__c = instance.Correlation_Key__c,
      Log_Type__c = 'OperatorIntervention',
      Message__c = msg.left(131072),
      Outcome__c = 'Success',
      Level__c = 'INFO',
      Fire_Time__c = DateTime.now()
    );
    Database.insert(interventionLog, true, AccessLevel.SYSTEM_MODE);
  }
}
