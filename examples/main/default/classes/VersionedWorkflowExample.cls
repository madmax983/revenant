public inherited sharing class VersionedWorkflowExample {
  public class VersionedWorkflowImpl implements VersionedWorkflow {
    public List<String> getSteps() {
      return new List<String>{
        'VersionedWorkflowExample.StepAStep',
        'VersionedWorkflowExample.StepBStep',
        'VersionedWorkflowExample.NewStepBStep'
      };
    }

    public String getInitialStep() {
      return 'VersionedWorkflowExample.StepAStep';
    }

    public Integer getLatestVersion() {
      return 2;
    }

    public String getNextStep(String currentStepName, StepResult result) {
      // Fallback / default routing (Version 1 behavior)
      return getNextStep(currentStepName, result, 1);
    }

    public String getNextStep(
      String currentStepName,
      StepResult result,
      Integer version
    ) {
      if (currentStepName == 'VersionedWorkflowExample.StepAStep') {
        return (version >= 2)
          ? 'VersionedWorkflowExample.NewStepBStep'
          : 'VersionedWorkflowExample.StepBStep';
      }
      return null; // End of workflow
    }
  }

  public class StepAStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      String msg = (ctx.workflowVersion >= 2) ? 'New logic' : 'Legacy logic';
      return StepResult.complete(
        null,
        new Map<String, Object>{ 'message' => msg }
      );
    }
  }

  public class StepBStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(
        null,
        new Map<String, Object>{ 'legacy' => true }
      );
    }
  }

  public class NewStepBStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(
        null,
        new Map<String, Object>{ 'legacy' => false }
      );
    }
  }
}
