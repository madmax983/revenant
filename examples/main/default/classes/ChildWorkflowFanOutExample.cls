/**
 * ChildWorkflowFanOutExample — reference example for dynamic parent→child workflow fan-out and rejoin.
 *
 * Spawns N child workflows in parallel (dynamic size based on input list),
 * waits for all of them to complete, and aggregates their results.
 */
public inherited sharing class ChildWorkflowFanOutExample implements WorkflowDefinition {
  public List<String> getSteps() {
    return new List<String>{ 'ChildWorkflowFanOutExample.FanOutStep' };
  }

  public String getInitialStep() {
    return 'ChildWorkflowFanOutExample.FanOutStep';
  }

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
    public StepResult execute(StepContext ctx) {
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

      // Check if outcomes are already present (resume path)
      List<StepContext.ChildOutcome> outcomes = ctx.getChildOutcomes(childKeys);
      Boolean allPresent = true;
      for (StepContext.ChildOutcome outcome : outcomes) {
        if (!outcome.isPresent()) {
          allPresent = false;
          break;
        }
      }

      if (allPresent) {
        // All child outcomes are present! We aggregate their scores here.
        Integer totalScore = 0;
        for (Integer i = 0; i < outcomes.size(); i++) {
          StepContext.ChildOutcome outcome = outcomes[i];
          if (outcome.isSuccess()) {
            String childOutput = outcome.output;
            Map<String, Object> result = (Map<String, Object>) JSON.deserializeUntyped(
              childOutput
            );
            totalScore += ((Decimal) result.get('score')).intValue();
          } else {
            return StepResult.fail(
              'Child workflow failed: ' + outcome.errorMessage
            );
          }
        }

        return StepResult.complete(
          null,
          new Map<String, Object>{ 'totalScore' => totalScore }
        );
      }

      // First run path: spawn child workflows
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

  public class ScoreItemWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{ 'ChildWorkflowFanOutExample.ComputeScoreStep' };
    }

    public String getInitialStep() {
      return 'ChildWorkflowFanOutExample.ComputeScoreStep';
    }

    public String getNextStep(String currentStepName, StepResult stepResult) {
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // CHILD STEP
  // ---------------------------------------------------------------------------

  public class ComputeScoreStep implements WorkflowStep {
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
