/**
 * @description Durable step-execution orchestrator for the engine's
 * exactly-once heart. Drives one `Workflow_Instance__c` delivery through the
 * mandated admission + lock + invoke sequence and preserves its guarded-return
 * ORDER: load (no lock) → finished-check → compensation route → pause park →
 * concurrency admission (instance `FOR UPDATE`) → in-memory init → stale-parallel
 * guard → step-execution log lock (step-exec `FOR UPDATE`) → validate → resolve
 * previous output → invoke + outcome. The instance is locked for admission
 * BEFORE the step-execution row is locked for execution, so a bounded workflow
 * can never double-run a step or resurrect a finished instance. The phase
 * implementations live in `WorkflowStepAdmission`, `WorkflowStepExecLock` and
 * `WorkflowStepInvoke`; this class owns the sequence and the shared
 * `RunStepContext`. All DML and SOQL run in system mode.
 */
public inherited sharing class WorkflowStepRunner {
  /**
   * @description Executes the active step for a workflow instance. Designed to
   * run in a Queueable context.
   * @param instanceId Id of the instance whose active step is executed
   */
  public static void runStepById(Id instanceId) {
    runStepNamed(instanceId, null);
  }

  /**
   * @description Mutable per-delivery execution context threaded through the
   * admission, lock and invoke phases. Public (with public fields) so the
   * extracted phase classes can read and populate it as the delivery advances;
   * carries no static members.
   */
  public class RunStepContext {
    public Id instanceId;
    public String stepName;
    public Workflow_Instance__c instance;
    public Workflow_Step_Execution__c stepExec;
    public Integer stepVisit = 0;
    public String activeStepName;
  }

  /**
   * @description Executes a single step of a workflow instance and durably
   * persists its outcome: hydrates the step's `StepContext`, runs the step (or a
   * routed timeout fallback), then hands the `StepResult` to handleStepResult to
   * advance, suspend, retry, split, complete, fail or compensate the instance.
   * The engine's core step-execution entry point, run inside a Queueable. Keeps
   * the admission + lock guarded-return ORDER intact while delegating each
   * phase's implementation to its cohesive phase class.
   * @param instanceId Id of the instance to advance
   * @param stepName name of the step to run, or null to run the instance's
   * current step
   */
  public static void runStepNamed(Id instanceId, String stepName) {
    RunStepContext ctx = new RunStepContext();
    ctx.instanceId = instanceId;
    ctx.stepName = stepName;
    ctx.instance = loadInstanceForRun(instanceId);
    if (isFinishedStatus(ctx.instance.Status__c)) {
      return; // Already finished
    }
    if (WorkflowStepAdmission.routeIfCompensating(ctx.instance)) {
      return;
    }
    if (WorkflowStepAdmission.parkIfPaused(ctx.instance)) {
      return;
    }
    if (WorkflowStepAdmission.admitOrParkForConcurrency(ctx.instance)) {
      return;
    }
    WorkflowStepExecLock.initializeStepInMemory(ctx.instance);
    if (isStaleParallelOrchestratorRun(ctx.instance, stepName)) {
      return;
    }
    ctx.activeStepName = String.isNotBlank(stepName)
      ? stepName
      : ctx.instance.Current_Step__c;
    if (WorkflowStepExecLock.acquireStepExecutionLog(ctx)) {
      return;
    }
    validateExplicitStepName(ctx.instance, stepName);
    String prevOutput = resolvePreviousStepOutput(
      ctx.instance,
      ctx.activeStepName,
      stepName
    );
    WorkflowStepInvoke.invokeStepAndHandleOutcome(ctx, prevOutput);
  }

  // §1. Fetch instance state (NO FOR UPDATE lock to allow parallel execution and
  // direct callouts).
  private static Workflow_Instance__c loadInstanceForRun(Id instanceId) {
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
        Error_Message__c,
        Previous_Run_At__c,
        Concurrency_Slot_Held__c,
        Concurrency_Parked__c,
        CreatedDate,
        Failure_Category__c,
        Causation_Id__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
      WITH SYSTEM_MODE
      LIMIT 1
    ];
    if (instances.isEmpty()) {
      throw new WorkflowEngine.WorkflowException(
        'Workflow instance not found: ' + instanceId
      );
    }
    return instances[0];
  }

  /**
   * @description A forward-terminal status: nothing left to drive. Public so the
   * extracted step-execution-lock phase can re-check terminality under the lock.
   * @param status the instance status to test
   * @return true when the status is forward-terminal
   */
  public static Boolean isFinishedStatus(String status) {
    return status == 'Completed' ||
      status == 'Failed' ||
      status == 'Compensated' ||
      status == 'CompensationFailed' ||
      status == 'Cancelled' ||
      status == 'ContinuedAsNew';
  }

  // A blank-stepName delivery for a parallel (comma-list) current step is a
  // stale/duplicate orchestrator run.
  private static Boolean isStaleParallelOrchestratorRun(
    Workflow_Instance__c instance,
    String stepName
  ) {
    return String.isBlank(stepName) &&
      String.isNotBlank(instance.Current_Step__c) &&
      instance.Current_Step__c.contains(',');
  }

  // Validate an explicit stepName against the active (possibly parallel) step.
  private static void validateExplicitStepName(
    Workflow_Instance__c instance,
    String stepName
  ) {
    if (String.isBlank(stepName) || instance.Current_Step__c == stepName) {
      return;
    }
    if (!isStepInParallelList(instance.Current_Step__c, stepName)) {
      throw new WorkflowEngine.WorkflowException(
        'Step ' +
          stepName +
          ' is not the active/expected step for this instance: ' +
          instance.Current_Step__c
      );
    }
  }

  // True when stepName is one of the comma-separated active parallel steps.
  private static Boolean isStepInParallelList(
    String currentStep,
    String stepName
  ) {
    if (String.isBlank(currentStep) || !currentStep.contains(',')) {
      return false;
    }
    for (String pStep : currentStep.split(',')) {
      if (pStep.trim() == stepName) {
        return true;
      }
    }
    return false;
  }

  // §4. Resolve the previous step's output for a yielded/resumed execution.
  private static String resolvePreviousStepOutput(
    Workflow_Instance__c instance,
    String activeStepName,
    String stepName
  ) {
    Id instanceId = instance.Id;
    String prevOutput = null;
    List<Workflow_Step_Execution__c> lastCompleted;
    if (
      String.isNotBlank(stepName) &&
      String.isNotBlank(instance.Current_Step__c) &&
      instance.Current_Step__c.contains(',')
    ) {
      List<String> activeParallelSteps = instance.Current_Step__c.split(',');
      lastCompleted = [
        SELECT Output__c
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Status__c IN ('Completed', 'OperatorSkipped')
          AND Step_Name__c NOT IN :activeParallelSteps
        WITH SYSTEM_MODE
        ORDER BY CreatedDate DESC, Id DESC
        LIMIT 1
      ];
    } else {
      lastCompleted = [
        SELECT Output__c
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Status__c IN ('Completed', 'OperatorSkipped')
          AND Step_Name__c != :activeStepName
        WITH SYSTEM_MODE
        ORDER BY CreatedDate DESC, Id DESC
        LIMIT 1
      ];
    }
    if (!lastCompleted.isEmpty()) {
      prevOutput = lastCompleted[0].Output__c;
    }

    return prevOutput;
  }
}
