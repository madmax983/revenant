/**
 * ChildWorkflowFanOutExample — reference example for dynamic parent→child workflow fan-out and rejoin.
 *
 * Spawns N child workflows in parallel (dynamic size based on input list),
 * waits for all of them to complete, and aggregates their results.
 */
public inherited sharing class ChildWorkflowFanOutExample implements WorkflowDefinition {
  /**
   * @description Declares the fully-qualified step names that make up the parent workflow.
   * @return The list of fully-qualified step names in this definition.
   */
  public List<String> getSteps() {
    return new List<String>{ 'ChildWorkflowFanOutExample.FanOutStep' };
  }

  /**
   * @description Names the entry-point step the engine runs first.
   * @return The fully-qualified initial step name.
   */
  public String getInitialStep() {
    return 'ChildWorkflowFanOutExample.FanOutStep';
  }

  /**
   * @description Routes to the successor step after the current step completes.
   * @param currentStepName The step that just completed.
   * @param stepResult The result of the completed step.
   * @return The next step name, or null since the fan-out step is terminal.
   */
  public String getNextStep(String currentStepName, StepResult stepResult) {
    return null;
  }

  // ---------------------------------------------------------------------------
  // PARENT STEPS
  // ---------------------------------------------------------------------------

  /**
   * FanOutStep reads the input list of items, constructs child requests,
   * and starts them all in parallel using StepResult.startChildren().
   *
   * On resume, it checks if all child outcomes are present, aggregates
   * their results, and completes the workflow.
   */
  public class FanOutStep implements WorkflowStep {
    /**
     * @description Reads the input items and spawns a child workflow per item; on resume, aggregates the child scores and completes.
     * @param ctx The durable per-step execution context.
     * @return The step's outcome result.
     */
    public StepResult execute(StepContext ctx) {
      List<Object> items = parseItems(ctx);
      List<String> childKeys = buildChildKeys(items, ctx);

      // Check if outcomes are already present (resume path)
      List<StepContext.ChildOutcome> outcomes = ctx.getChildOutcomes(childKeys);
      if (allOutcomesPresent(outcomes)) {
        return aggregateOutcomes(outcomes);
      }

      // First run path: spawn child workflows
      return spawnChildren(items, ctx);
    }

    // Deserializes the workflow input into the list of items, accepting either a
    // bare list or an object with an "items" list. Throws if the input is
    // missing or not one of those shapes.
    private List<Object> parseItems(StepContext ctx) {
      if (String.isBlank(ctx.workflowInputJson)) {
        throw new WorkflowEngine.WorkflowException(
          'Workflow input is required.'
        );
      }
      Object deserialized = JSON.deserializeUntyped(ctx.workflowInputJson);
      List<Object> items = null;
      if (deserialized instanceof List<Object>) {
        items = (List<Object>) deserialized;
      } else if (deserialized instanceof Map<String, Object>) {
        Map<String, Object> inputMap = (Map<String, Object>) deserialized;
        items = (List<Object>) inputMap.get('items');
      }

      if (items == null) {
        throw new WorkflowEngine.WorkflowException(
          'Workflow input must be a list of items or an object containing an "items" list.'
        );
      }
      return items;
    }

    // Derives the deterministic child correlation key for each item so the same
    // children can be looked up on resume. Throws if any item is missing its id.
    private List<String> buildChildKeys(List<Object> items, StepContext ctx) {
      List<String> childKeys = new List<String>();
      for (Object obj : items) {
        Map<String, Object> item = (Map<String, Object>) obj;
        String itemId = (String) item.get('id');
        if (String.isBlank(itemId)) {
          throw new WorkflowEngine.WorkflowException(
            'Item ID must not be blank.'
          );
        }
        childKeys.add('Score_' + ctx.workflowInstanceId + '_' + itemId);
      }
      return childKeys;
    }

    // True only once every spawned child has reported an outcome.
    private Boolean allOutcomesPresent(
      List<StepContext.ChildOutcome> outcomes
    ) {
      for (StepContext.ChildOutcome outcome : outcomes) {
        if (!outcome.isPresent()) {
          return false;
        }
      }
      return true;
    }

    // All child outcomes are present: aggregate their scores, failing the step
    // if any child failed.
    private StepResult aggregateOutcomes(
      List<StepContext.ChildOutcome> outcomes
    ) {
      Integer totalScore = 0;
      for (Integer i = 0; i < outcomes.size(); i++) {
        StepContext.ChildOutcome outcome = outcomes[i];
        if (!outcome.isSuccess()) {
          return StepResult.fail(
            'Child workflow failed: ' + outcome.errorMessage
          );
        }
        String childOutput = outcome.output;
        Map<String, Object> result = (Map<String, Object>) JSON.deserializeUntyped(
          childOutput
        );
        totalScore += ((Decimal) result.get('score')).intValue();
      }

      return StepResult.complete(
        null,
        new Map<String, Object>{ 'totalScore' => totalScore }
      );
    }

    // First run path: build one child request per item and spawn them all.
    private StepResult spawnChildren(List<Object> items, StepContext ctx) {
      List<StepResult.ChildRequest> reqs = new List<StepResult.ChildRequest>();
      for (Integer i = 0; i < items.size(); i++) {
        Map<String, Object> item = (Map<String, Object>) items[i];
        String itemId = (String) item.get('id');
        Integer value = ((Decimal) item.get('value')).intValue();
        String childKey = 'Score_' + ctx.workflowInstanceId + '_' + itemId;

        reqs.add(
          new StepResult.ChildRequest(
            'ChildWorkflowFanOutExample.ScoreItemWorkflow',
            childKey,
            new Map<String, Object>{ 'itemId' => itemId, 'value' => value }
          )
        );
      }

      return StepResult.startChildren(reqs);
    }
  }

  // ---------------------------------------------------------------------------
  // CHILD WORKFLOW DEFINITION
  // ---------------------------------------------------------------------------

  /**
   * @description Child workflow definition that scores a single item via one step.
   */
  public class ScoreItemWorkflow implements WorkflowDefinition {
    /**
     * @description Declares the fully-qualified step names that make up the child workflow.
     * @return The list of fully-qualified step names in this definition.
     */
    public List<String> getSteps() {
      return new List<String>{ 'ChildWorkflowFanOutExample.ComputeScoreStep' };
    }

    /**
     * @description Names the entry-point step the child workflow runs first.
     * @return The fully-qualified initial step name.
     */
    public String getInitialStep() {
      return 'ChildWorkflowFanOutExample.ComputeScoreStep';
    }

    /**
     * @description Routes to the successor step after the current child step completes.
     * @param currentStepName The step that just completed.
     * @param stepResult The result of the completed step.
     * @return The next step name, or null since the child workflow has a single terminal step.
     */
    public String getNextStep(String currentStepName, StepResult stepResult) {
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // CHILD STEP
  // ---------------------------------------------------------------------------

  /**
   * @description Child step that computes a score from the item's value.
   */
  public class ComputeScoreStep implements WorkflowStep {
    /**
     * @description Computes a score by doubling the item value and completes with the result.
     * @param ctx The durable per-step execution context.
     * @return The step's outcome result.
     */
    public StepResult execute(StepContext ctx) {
      Map<String, Object> input = (Map<String, Object>) JSON.deserializeUntyped(
        ctx.workflowInputJson
      );
      String itemId = (String) input.get('itemId');
      Integer value = ((Decimal) input.get('value')).intValue();

      // Simple scoring formula (e.g. double the value)
      Integer score = value * 2;

      return StepResult.complete(
        null,
        new Map<String, Object>{ 'itemId' => itemId, 'score' => score }
      );
    }
  }
}
