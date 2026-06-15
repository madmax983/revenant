/**
 * Reference example for issue #11: reading the inbound signal that resumed a step.
 *
 * The first step suspends waiting for an approval decision. When an external
 * approver signals the workflow, the step resumes and reads the decision
 * payload directly from `StepContext` -- no SOQL against the engine's internal
 * `Workflow_Signal__c` object, and no hand-rolled "consumed" marker. The engine
 * marks the signal(s) the step observed as consumed at the COMPLETE transition,
 * so an at-least-once redelivered duplicate of the same signal does not cause
 * the reject branch to fire twice.
 */
public inherited sharing class ApprovalSignalWorkflowExample implements WorkflowDefinition {
  /** The signal name an approver publishes to convey their decision. */
  public static final String DECISION_SIGNAL = 'ApprovalDecision';

  public String getInitialStep() {
    return 'ApprovalSignalWorkflowExample.RequestApprovalStep';
  }

  public String getNextStep(String currentStepName, StepResult stepResult) {
    // The approval step decides the branch by setting the next step name on its
    // result; the terminal approve/reject steps end the workflow.
    if (String.isNotBlank(stepResult.nextStepName)) {
      return stepResult.nextStepName;
    }
    return null;
  }

  // --- STEP DEFINITIONS ---

  public class RequestApprovalStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      // One accessor: read the decision that woke us, if any.
      StepContext.Signal decision = ctx.getSignal(DECISION_SIGNAL);

      if (!decision.isPresent()) {
        // First run (or resumed by a timer): nothing decided yet -> suspend.
        return StepResult.waitForApproval('OrderApproval', 'Manager');
      }

      Map<String, Object> payload = (Map<String, Object>) JSON.deserializeUntyped(
        decision.payload
      );
      Boolean approved = payload.get('approved') == null
        ? false
        : (Boolean) payload.get('approved');

      if (approved) {
        return StepResult.complete(
          'ApprovalSignalWorkflowExample.ApproveStep',
          payload
        );
      }
      return StepResult.complete(
        'ApprovalSignalWorkflowExample.RejectStep',
        payload
      );
    }
  }

  public class ApproveStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(
        null,
        new Map<String, Object>{ 'result' => 'approved' }
      );
    }
  }

  public class RejectStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      Map<String, Object> input = String.isNotBlank(ctx.inputJson)
        ? (Map<String, Object>) JSON.deserializeUntyped(ctx.inputJson)
        : new Map<String, Object>();
      return StepResult.complete(
        null,
        new Map<String, Object>{
          'result' => 'rejected',
          'reason' => input.get('reason')
        }
      );
    }
  }
}
