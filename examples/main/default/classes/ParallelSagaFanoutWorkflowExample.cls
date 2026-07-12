/**
 * @description Example saga workflow that fans out into four parallel compensatable
 * branches and joins them, demonstrating how a failure in one branch triggers LIFO
 * compensation of the branches that already completed.
 */
public inherited sharing class ParallelSagaFanoutWorkflowExample {
  public static Boolean failBranch3 = true;
  public static List<String> executionAudit = new List<String>();
  public static List<String> compensationAudit = new List<String>();

  /**
   * @description Workflow definition that spawns four parallel branches and joins them once
   * all have completed.
   */
  public inherited sharing class ParallelSagaWorkflow implements WorkflowDefinition {
    /**
     * @description Returns the ordered step names comprising the saga.
     * @return The list of spawn, four branch, and join step names.
     */
    public List<String> getSteps() {
      return new List<String>{
        'ParallelSagaFanoutWorkflowExample.SpawnStep',
        'ParallelSagaFanoutWorkflowExample.Branch1Step',
        'ParallelSagaFanoutWorkflowExample.Branch2Step',
        'ParallelSagaFanoutWorkflowExample.Branch3Step',
        'ParallelSagaFanoutWorkflowExample.Branch4Step',
        'ParallelSagaFanoutWorkflowExample.JoinStep'
      };
    }

    /**
     * @description Returns the name of the first step to execute.
     * @return The name of the spawn step.
     */
    public String getInitialStep() {
      return 'ParallelSagaFanoutWorkflowExample.SpawnStep';
    }

    /**
     * @description Routes the spawn step to the join step; branch steps end the branch.
     * @param currentStepName The name of the step that just completed.
     * @param result The result of the completed step.
     * @return The join step name after the spawn, otherwise null.
     */
    public String getNextStep(String currentStepName, StepResult result) {
      if (currentStepName == 'ParallelSagaFanoutWorkflowExample.SpawnStep') {
        return 'ParallelSagaFanoutWorkflowExample.JoinStep';
      }
      return null;
    }
  }

  /**
   * @description Step that splits execution into the four parallel branch steps.
   */
  public inherited sharing class SpawnStep implements WorkflowStep {
    /**
     * @description Splits into the four branch steps, sharing the workflow input.
     * @param ctx The durable step context supplying the input.
     * @return A split result naming the four parallel branches.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.split(
        new List<String>{
          'ParallelSagaFanoutWorkflowExample.Branch1Step',
          'ParallelSagaFanoutWorkflowExample.Branch2Step',
          'ParallelSagaFanoutWorkflowExample.Branch3Step',
          'ParallelSagaFanoutWorkflowExample.Branch4Step'
        },
        ctx.inputJson
      );
    }
  }

  /**
   * @description Compensatable branch 1: suspends until its completion signal arrives, then
   * completes, and undoes its work on compensation.
   */
  public inherited sharing class Branch1Step implements CompensatableStep {
    /**
     * @description Suspends until the Branch1_Complete signal is present, then completes.
     * @param ctx The durable step context exposing signals.
     * @return A suspend result until signalled, otherwise a complete result.
     */
    public StepResult execute(StepContext ctx) {
      StepContext.Signal sig = ctx.getSignal('Branch1_Complete');
      if (!sig.isPresent()) {
        return StepResult.suspend();
      }
      executionAudit.add('Branch1_Execute');
      return StepResult.complete(
        null,
        new Map<String, Object>{ 'branch' => 1, 'status' => 'Completed' }
      );
    }

    /**
     * @description Undoes branch 1's work when the saga compensates.
     * @param ctx The durable step context supplying the persisted step state.
     * @return A complete result marking the branch compensated.
     */
    public StepResult compensate(StepContext ctx) {
      compensationAudit.add('Branch1_Compensate');
      return StepResult.complete(
        null,
        new Map<String, Object>{ 'branch' => 1, 'status' => 'Compensated' }
      );
    }
  }

  /**
   * @description Compensatable branch 2: suspends until its completion signal arrives, then
   * completes, and undoes its work on compensation.
   */
  public inherited sharing class Branch2Step implements CompensatableStep {
    /**
     * @description Suspends until the Branch2_Complete signal is present, then completes.
     * @param ctx The durable step context exposing signals.
     * @return A suspend result until signalled, otherwise a complete result.
     */
    public StepResult execute(StepContext ctx) {
      StepContext.Signal sig = ctx.getSignal('Branch2_Complete');
      if (!sig.isPresent()) {
        return StepResult.suspend();
      }
      executionAudit.add('Branch2_Execute');
      return StepResult.complete(
        null,
        new Map<String, Object>{ 'branch' => 2, 'status' => 'Completed' }
      );
    }

    /**
     * @description Undoes branch 2's work when the saga compensates.
     * @param ctx The durable step context supplying the persisted step state.
     * @return A complete result marking the branch compensated.
     */
    public StepResult compensate(StepContext ctx) {
      compensationAudit.add('Branch2_Compensate');
      return StepResult.complete(
        null,
        new Map<String, Object>{ 'branch' => 2, 'status' => 'Compensated' }
      );
    }
  }

  /**
   * @description Compensatable branch 3: the branch that induces failure (when failBranch3
   * is set) to trigger compensation of the sibling branches.
   */
  public inherited sharing class Branch3Step implements CompensatableStep {
    /**
     * @description Suspends until the Branch3_Complete signal is present, then either throws
     * an induced failure or completes, depending on the failBranch3 flag.
     * @param ctx The durable step context exposing signals.
     * @return A suspend result until signalled, otherwise a complete result (or throws).
     */
    public StepResult execute(StepContext ctx) {
      StepContext.Signal sig = ctx.getSignal('Branch3_Complete');
      if (!sig.isPresent()) {
        return StepResult.suspend();
      }
      executionAudit.add('Branch3_Execute');
      if (failBranch3) {
        throw new WorkflowEngine.WorkflowException('Branch 3 induced failure');
      }
      return StepResult.complete(
        null,
        new Map<String, Object>{ 'branch' => 3, 'status' => 'Completed' }
      );
    }

    /**
     * @description Undoes branch 3's work when the saga compensates.
     * @param ctx The durable step context supplying the persisted step state.
     * @return A complete result marking the branch compensated.
     */
    public StepResult compensate(StepContext ctx) {
      compensationAudit.add('Branch3_Compensate');
      return StepResult.complete(
        null,
        new Map<String, Object>{ 'branch' => 3, 'status' => 'Compensated' }
      );
    }
  }

  /**
   * @description Compensatable branch 4: suspends until its completion signal arrives, then
   * completes, and undoes its work on compensation.
   */
  public inherited sharing class Branch4Step implements CompensatableStep {
    /**
     * @description Suspends until the Branch4_Complete signal is present, then completes.
     * @param ctx The durable step context exposing signals.
     * @return A suspend result until signalled, otherwise a complete result.
     */
    public StepResult execute(StepContext ctx) {
      StepContext.Signal sig = ctx.getSignal('Branch4_Complete');
      if (!sig.isPresent()) {
        return StepResult.suspend();
      }
      executionAudit.add('Branch4_Execute');
      return StepResult.complete(
        null,
        new Map<String, Object>{ 'branch' => 4, 'status' => 'Completed' }
      );
    }

    /**
     * @description Undoes branch 4's work when the saga compensates.
     * @param ctx The durable step context supplying the persisted step state.
     * @return A complete result marking the branch compensated.
     */
    public StepResult compensate(StepContext ctx) {
      compensationAudit.add('Branch4_Compensate');
      return StepResult.complete(
        null,
        new Map<String, Object>{ 'branch' => 4, 'status' => 'Compensated' }
      );
    }
  }

  /**
   * @description Join step that runs once all branches have completed and finalizes the saga.
   */
  public inherited sharing class JoinStep implements WorkflowStep {
    /**
     * @description Completes the workflow, echoing the parsed input as the final output.
     * @param ctx The durable step context supplying the input.
     * @return A complete result carrying the parsed input.
     */
    public StepResult execute(StepContext ctx) {
      executionAudit.add('Join_Execute');
      Object parsedInput = String.isNotBlank(ctx.inputJson)
        ? JSON.deserializeUntyped(ctx.inputJson)
        : null;
      return StepResult.complete(null, parsedInput);
    }
  }
}
