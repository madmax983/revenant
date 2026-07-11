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
  /** The approval gate name passed to waitForApproval. */
  public static final String APPROVAL_KEY = 'OrderApproval';
  /**
   * The signal name an approver publishes to convey their decision. This must
   * match what the approval gate produces: the dashboard's submitApproval (and
   * the WorkflowSignalInvocableAction approval convention) publish
   * 'Approve:' + approvalKey, so the step reads that exact name.
   */
  public static final String DECISION_SIGNAL = 'Approve:' + APPROVAL_KEY;

  /**
   * @description Returns the ordered step names composing this approval workflow.
   * @return The request-approval, approve, and reject step names.
   */
  public List<String> getSteps() {
    return new List<String>{
      'ApprovalSignalWorkflowExample.RequestApprovalStep',
      'ApprovalSignalWorkflowExample.ApproveStep',
      'ApprovalSignalWorkflowExample.RejectStep'
    };
  }

  /**
   * @description Returns the step the workflow begins with.
   * @return The request-approval step name.
   */
  public String getInitialStep() {
    return 'ApprovalSignalWorkflowExample.RequestApprovalStep';
  }

  /**
   * @description Routes to the branch the approval step chose by reading the next
   * step name embedded in its result; the terminal steps end the workflow.
   * @param currentStepName The name of the step that just completed.
   * @param stepResult The result of the completed step, carrying the chosen next step.
   * @return The next step name set by the approval step, or null to end the workflow.
   */
  public String getNextStep(String currentStepName, StepResult stepResult) {
    // The approval step decides the branch by setting the next step name on its
    // result; the terminal approve/reject steps end the workflow.
    if (String.isNotBlank(stepResult.nextStepName)) {
      return stepResult.nextStepName;
    }
    return null;
  }

  // --- STEP DEFINITIONS ---

  /**
   * @description Suspends waiting for an approval decision, then on resume reads the
   * decision signal and routes to the approve or reject branch.
   */
  public class RequestApprovalStep implements WorkflowStep {
    /**
     * @description Waits for approval on first run; once the decision signal arrives,
     * branches to the approve or reject step based on the payload.
     * @param ctx The durable step context exposing the decision signal that woke the step.
     * @return waitForApproval while pending, or COMPLETE routing to the approve/reject step.
     */
    public StepResult execute(StepContext ctx) {
      // One accessor: read the decision that woke us, if any.
      StepContext.Signal decision = ctx.getSignal(DECISION_SIGNAL);

      if (!decision.isPresent()) {
        // First run (or resumed by a timer): nothing decided yet -> suspend.
        return StepResult.waitForApproval(APPROVAL_KEY, 'Manager');
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

  /**
   * @description Terminal step reached when the request was approved.
   */
  public class ApproveStep implements WorkflowStep {
    /**
     * @description Records the approved outcome and ends the workflow.
     * @param ctx The durable step context for this execution.
     * @return A COMPLETE result carrying the approved outcome.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(
        null,
        new Map<String, Object>{ 'result' => 'approved' }
      );
    }
  }

  /**
   * @description Terminal step reached when the request was rejected.
   */
  public class RejectStep implements WorkflowStep {
    /**
     * @description Records the rejected outcome, carrying through any supplied reason.
     * @param ctx The durable step context supplying the workflow input.
     * @return A COMPLETE result carrying the rejected outcome and reason.
     */
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
