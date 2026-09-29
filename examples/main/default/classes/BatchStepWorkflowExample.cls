/**
 * @description Reference example for WorkflowBatchStep (issue #138). The
 * workflow reserves a tag, runs ExampleAccountTagBatch as one durable step,
 * then branches on the batch outcome. A batch that does not succeed goes to
 * RollbackStep. RollbackStep fails the run, so the engine compensates
 * ReserveTagStep.
 *
 * Input: {"namePrefix": "Acme", "tag": "Q3-Review"}
 */
public inherited sharing class BatchStepWorkflowExample {
  private static final String RESERVE = 'BatchStepWorkflowExample.ReserveTagStep';
  private static final String TAG_ACCOUNTS = 'BatchStepWorkflowExample.TagAccountsStep';
  private static final String CONFIRM = 'BatchStepWorkflowExample.ConfirmStep';
  private static final String ROLLBACK_STEP = 'BatchStepWorkflowExample.RollbackStep';

  /**
   * @description Reserve, run the batch, then confirm or roll back.
   */
  public class AccountTagWorkflow implements WorkflowDefinition {
    /**
     * @description Returns the steps.
     * @return The step names.
     */
    public List<String> getSteps() {
      return new List<String>{ RESERVE, TAG_ACCOUNTS, CONFIRM, ROLLBACK_STEP };
    }

    /**
     * @description Returns the first step.
     * @return The reserve step name.
     */
    public String getInitialStep() {
      return RESERVE;
    }

    /**
     * @description Branches on the batch outcome.
     * @param currentStepName The step that completed.
     * @param result The result of that step.
     * @return The next step name, or null at the end.
     */
    public String getNextStep(String currentStepName, StepResult result) {
      if (currentStepName == RESERVE) {
        return TAG_ACCOUNTS;
      }
      if (currentStepName == TAG_ACCOUNTS) {
        Map<String, Object> outcome = (Map<String, Object>) JSON.deserializeUntyped(
          result.directive().outputJson
        );
        return outcome.get('succeeded') == true ? CONFIRM : ROLLBACK_STEP;
      }
      return null;
    }
  }

  /**
   * @description Reserves the tag. The compensation releases it.
   */
  public class ReserveTagStep implements CompensatableStep {
    /**
     * @description Reserves the tag from the workflow input.
     * @param ctx The step context.
     * @return COMPLETE with the tag.
     */
    public StepResult execute(StepContext ctx) {
      Map<String, Object> input = (Map<String, Object>) JSON.deserializeUntyped(
        ctx.workflowInputJson
      );
      return StepResult.complete(
        null,
        new Map<String, Object>{ 'tag' => input.get('tag') }
      );
    }

    /**
     * @description Releases the tag.
     * @param ctx The step context.
     * @return COMPLETE with the released tag.
     */
    public StepResult compensate(StepContext ctx) {
      ctx.logger().log(StepContext.Level.WARN, 'Releasing the tag');
      return StepResult.complete(
        null,
        new Map<String, Object>{ 'released' => true }
      );
    }
  }

  /**
   * @description The batch binding: class, scope size and input. No other code.
   */
  public class TagAccountsStep extends WorkflowBatchStep {
    /**
     * @description Binds ExampleAccountTagBatch to the workflow input.
     * @param ctx The step context.
     * @return The binding.
     */
    protected override WorkflowBatchStep.Binding bind(StepContext ctx) {
      return new WorkflowBatchStep.Binding(
        'ExampleAccountTagBatch',
        200,
        JSON.deserializeUntyped(ctx.workflowInputJson)
      );
    }
  }

  /**
   * @description Confirms the tag after a batch that succeeded.
   */
  public class ConfirmStep implements WorkflowStep {
    /**
     * @description Completes with the batch counts.
     * @param ctx The step context. The input is the batch outcome.
     * @return COMPLETE with the counts.
     */
    public StepResult execute(StepContext ctx) {
      Map<String, Object> outcome = (Map<String, Object>) JSON.deserializeUntyped(
        ctx.inputJson
      );
      return StepResult.complete(
        null,
        new Map<String, Object>{
          'confirmed' => true,
          'jobItemsProcessed' => outcome.get('jobItemsProcessed')
        }
      );
    }
  }

  /**
   * @description Fails the run after a batch that did not succeed. The engine
   * then compensates ReserveTagStep.
   */
  public class RollbackStep implements WorkflowStep {
    /**
     * @description Fails with the batch status and first error.
     * @param ctx The step context. The input is the batch outcome.
     * @return FAIL with the outcome.
     */
    public StepResult execute(StepContext ctx) {
      Map<String, Object> outcome = (Map<String, Object>) JSON.deserializeUntyped(
        ctx.inputJson
      );
      return StepResult.fail(
        'Account tag batch ended with status ' +
          outcome.get('status') +
          ': ' +
          outcome.get('firstError'),
        outcome
      );
    }
  }
}
