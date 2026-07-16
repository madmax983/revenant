/**
 * @description The compensation drive: re-asserts the compensating status
 * (`reassertCompensatingStatus`) and executes one `_Compensate` rollback step
 * (`runCompensationStep`) for a saga that is unwinding. Reads the LIFO stack,
 * resolves the forward-execution source, and orchestrates the savepoint-free
 * exactly-once sequence (locked step-exec prepare, deferred-DML commit, invoke,
 * outcome dispatch) without ever popping a step except on success. Threads the
 * mutable `CompensationRun` accumulator through the phase helpers. All DML and
 * SOQL run in system mode.
 */
public inherited sharing class WorkflowCompensationRunner {
  /**
   * @description Re-asserts the compensating status before a compensation step
   * runs: `runCompensationStep` early-exits unless the instance is
   * Compensating/Cancelling, so a Suspended (initial detection) or Running
   * (signal-resumed) instance must be restored to the right compensation status
   * first. The DML is DEFERRED to `runCompensationStep` so a signal-resumed
   * CalloutStep compensate() is not blocked by uncommitted DML. Public so the
   * extracted `WorkflowStepRunner` compensation router can drive it.
   * @param instance the instance whose compensation status is re-asserted
   * @return the re-asserted status ('Cancelling' or 'Compensating'), or null when
   * the instance was not in a re-assertable (Suspended/Running) state
   */
  public static String reassertCompensatingStatus(
    Workflow_Instance__c instance
  ) {
    if (instance.Status__c != 'Suspended' && instance.Status__c != 'Running') {
      return null;
    }
    String reassertedStatus = (instance.Error_Message__c != null &&
      instance.Error_Message__c.contains('Cancelled by user'))
      ? 'Cancelling'
      : 'Compensating';
    instance.Status__c = reassertedStatus;
    instance.Async_Job_Id__c = null;
    return reassertedStatus;
  }

  /**
   * @description Mutable accumulator threaded through the compensation-step phase
   * helpers (across the runner, step-log, context, and invoke classes) so each
   * helper stays within the parameter and complexity budgets. Fields are public so
   * the extracted phase helpers can read and advance the shared run state.
   */
  public class CompensationRun {
    public Workflow_Instance__c instance;
    public String reassertedStatus;
    public Id forwardSourceInstanceId;
    public List<String> stack;
    public String activeStepName;
    public String compensationStepLogName;
    public List<Workflow_Step_Execution__c> stepExecs;
    public Workflow_Step_Execution__c stepExec;
    public Integer compensateVisit = 0;
    public Integer attempt;
    public Integer maxAttempts;
    public Map<String, Object> capturesMap;
    public Boolean deferPreExecDml;
    public Integer timeoutSeconds;
    public StepResult result;
  }

  /**
   * @description Drives one compensation (rollback) step for an instance whose
   * saga is unwinding, executing the current `_Compensate` step and persisting
   * its outcome under the re-asserted compensating status. Public so the
   * extracted `WorkflowStepRunner` compensation router can delegate a live
   * compensation drive back to the engine's resident saga logic.
   * @param instance the instance whose compensation step is executed
   * @param reassertedStatus the compensation status re-asserted before the drive
   * ('Cancelling' or 'Compensating'), or null when no re-assertion was needed
   */
  public static void runCompensationStep(
    Workflow_Instance__c instance,
    String reassertedStatus
  ) {
    CompensationRun run = new CompensationRun();
    run.instance = instance;
    run.reassertedStatus = reassertedStatus;
    // Determine the source of the forward executions (original completed run or this run)
    run.forwardSourceInstanceId = resolveForwardSourceInstanceId(instance);

    // 1. Read the compensation stack
    if (finalizeIfCompensationStackEmpty(run)) {
      return;
    }

    // 2. Get the top step to compensate (do not pop yet, only pop on success)
    run.activeStepName = run.stack[run.stack.size() - 1];
    run.compensationStepLogName = run.activeStepName + '_Compensate';

    // 3. Create or retrieve the compensation step execution log with FOR UPDATE lock.
    if (!WorkflowCompensationStepLog.prepareCompensationStepExec(run)) {
      return;
    }

    // 4. Instantiate the step and execute compensate
    executeCompensation(run);
  }

  /**
   * @description Resolves the instance whose completed forward executions supply
   * the compensation inputs -- the predecessor run when it committed Completed,
   * else this run. Public so `WorkflowCompensation.preCreateFirstCompensationStep`
   * can seed the first step from the same source.
   * @param instance the compensating instance being driven
   * @return the Id of the instance whose forward executions supply undo context
   */
  public static Id resolveForwardSourceInstanceId(
    Workflow_Instance__c instance
  ) {
    Id forwardSourceInstanceId = instance.Id;
    Id prevInstId = null;
    try {
      prevInstId = instance.Previous_Instance__c;
    } catch (SObjectException ex) {
      List<Workflow_Instance__c> temp = [
        SELECT Previous_Instance__c
        FROM Workflow_Instance__c
        WHERE Id = :instance.Id
        WITH SYSTEM_MODE
        LIMIT 1
      ];
      if (!temp.isEmpty()) {
        prevInstId = temp[0].Previous_Instance__c;
      }
    }
    if (prevInstId != null) {
      List<Workflow_Instance__c> preds = [
        SELECT Status__c
        FROM Workflow_Instance__c
        WHERE Id = :prevInstId
        WITH SYSTEM_MODE
        LIMIT 1
      ];
      if (!preds.isEmpty() && preds[0].Status__c == 'Completed') {
        forwardSourceInstanceId = prevInstId;
      }
    }
    return forwardSourceInstanceId;
  }

  // Read/parse the compensation stack; when empty, drive the instance to its
  // terminal state and return true to signal the caller to stop.
  private static Boolean finalizeIfCompensationStackEmpty(CompensationRun run) {
    Workflow_Instance__c instance = run.instance;
    if (String.isBlank(instance.Compensation_Stack__c)) {
      finalizeEmptyCompensationStack(instance);
      return true;
    }
    run.stack = (List<String>) JSON.deserialize(
      instance.Compensation_Stack__c,
      List<String>.class
    );
    if (run.stack.isEmpty()) {
      finalizeEmptyCompensationStack(instance);
      return true;
    }
    return false;
  }

  // Terminal transition for an instance whose compensation stack is exhausted.
  private static void finalizeEmptyCompensationStack(
    Workflow_Instance__c instance
  ) {
    instance.Status__c = (instance.Status__c == 'Cancelling')
      ? 'Cancelled'
      : 'Compensated';
    instance.Current_Step__c = null;
    Database.update(instance, true, AccessLevel.SYSTEM_MODE);
    WorkflowParentNotifier.notifyParentCompletion(instance);
    // Fire-and-forget outbound lifecycle event on terminal transition.
    WorkflowLifecyclePublisher.publish(instance);
  }

  /**
   * @description Pops the already-terminal top step, advances the stack, and
   * re-enqueues. Public so `WorkflowCompensationStepLog.buildCompensationStepExec`
   * can short-circuit a locked step-exec that is already terminal.
   * @param run the compensation run accumulator whose top step is finalized
   */
  public static void finalizeAlreadyCompensatedStep(CompensationRun run) {
    Workflow_Instance__c instance = run.instance;
    List<String> stack = run.stack;
    stack.remove(stack.size() - 1);
    instance.Compensation_Stack__c = JSON.serialize(stack);
    Database.update(instance, true, AccessLevel.SYSTEM_MODE);

    if (!stack.isEmpty()) {
      WorkflowCompensation.preCreateFirstCompensationStep(instance);
      WorkflowTimeoutArming.scheduleTimeoutJobForInstance(instance.Id);
    }

    enqueueCompensationOrchestrator(instance.Id);
  }

  /**
   * @description Enqueues the next orchestrator pass for a compensating instance,
   * dispatching directly under test and via event otherwise. Public so
   * `WorkflowCompensationContext.resolveCompensatableStep` can advance an
   * auto-compensated non-compensatable step.
   * @param instanceId the compensating instance to drive forward
   */
  public static void enqueueCompensationOrchestrator(Id instanceId) {
    if (Test.isRunningTest()) {
      if (!WorkflowEngine.disableQueueableInTest) {
        System.enqueueJob(new WorkflowOrchestrator(instanceId));
      }
    } else {
      WorkflowOrchestratorEnqueue.enqueueOrchestrator(instanceId, null);
    }
  }

  // Instantiate the compensatable step, build its context, execute compensate,
  // and dispatch the outcome. Non-compensatable steps are auto-compensated.
  private static void executeCompensation(CompensationRun run) {
    CompensatableStep compensatableStepInstance = WorkflowCompensationContext.resolveCompensatableStep(
      run
    );
    if (compensatableStepInstance == null) {
      return;
    }

    StepContext context = WorkflowCompensationContext.buildCompensationContext(
      run,
      compensatableStepInstance
    );
    WorkflowCompensationInvoke.commitPreCompensationState(
      run,
      compensatableStepInstance
    );

    if (
      !WorkflowCompensationInvoke.invokeCompensation(
        run,
        compensatableStepInstance,
        context
      )
    ) {
      return;
    }

    WorkflowEngine.StepOutcomeContext outcome = new WorkflowEngine.StepOutcomeContext();
    outcome.instance = run.instance;
    outcome.stepExec = run.stepExec;
    outcome.result = run.result;
    outcome.stack = run.stack;
    outcome.context = context;
    WorkflowCompensationOutcome.handleCompensationStepResult(outcome);
  }
}
