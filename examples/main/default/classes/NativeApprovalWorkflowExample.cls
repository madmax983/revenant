/**
 * Reference example for issue #125: bridging a native Salesforce Approval Process to a
 * durable Revenant workflow, instead of building a bespoke approver inbox.
 *
 * Shape:
 *   ReserveBudgetStep (CompensatableStep)
 *     -> RequestApprovalStep (suspends; on resume surfaces the decision as output)
 *          approve -> PlaceOrderStep -> Completed
 *          reject  -> RejectStep -> WorkflowException -> LIFO compensation -> Compensated
 *
 * The approver-facing surface here is deliberately NOT a custom LWC: a native Approval
 * Process already ships a least-privilege approver inbox, mobile approve/reject, and
 * delegation, so this example reuses it rather than rebuilding it. The bridge from the
 * native process to this suspended gate is entirely declarative:
 *
 *   1. A record-triggered Flow starts this workflow when an Approval_Request__c is
 *      created (see Revenant_Start_Approval_Workflow_Example.flow-meta.xml), correlating
 *      on Correlation_Key__c.
 *   2. The record is separately submitted to the native Approval Process
 *      (Approval_Request__c.Revenant_Native_Approval_Example.approvalProcess-meta.xml),
 *      whose final approval/rejection action is a plain field update to
 *      Approval_Status__c -- no Apex, no custom UI.
 *   3. A second record-triggered Flow
 *      (Revenant_Approval_Decision_To_Signal_Example.flow-meta.xml) fires when that field
 *      update lands and calls the already-shipped WorkflowSignalInvocableAction to publish
 *      this workflow's DECISION_SIGNAL -- the same 'Approve:' + key convention
 *      ApprovalWorkflowExample and the dashboard's submitApproval already use.
 *
 * Revenant supplies only the primitive (waitForApproval + the Approve: signal); the
 * approval *mechanism* -- who may decide, the inbox, mobile access -- is the native
 * Approval Process, which is exactly what native Approval Processes are good at and what
 * they cannot combine with durable multi-step orchestration or compensating rollback.
 */
public inherited sharing class NativeApprovalWorkflowExample implements WorkflowDefinition {
  /** Approval gate identifier passed to waitForApproval(). */
  public static final String APPROVAL_KEY = 'NativeApprovalRequest';

  /**
   * Signal name the outbound bridge Flow publishes once the native Approval Process
   * reaches a final decision. Must match the 'Approve:' + approvalKey convention shared by
   * WorkflowDashboardController.submitApproval and WorkflowSignalInvocableAction.
   */
  public static final String DECISION_SIGNAL = 'Approve:' + APPROVAL_KEY;

  public List<String> getSteps() {
    return new List<String>{
      'NativeApprovalWorkflowExample.ReserveBudgetStep',
      'NativeApprovalWorkflowExample.RequestApprovalStep',
      'NativeApprovalWorkflowExample.PlaceOrderStep',
      'NativeApprovalWorkflowExample.RejectStep'
    };
  }

  public String getInitialStep() {
    return 'NativeApprovalWorkflowExample.ReserveBudgetStep';
  }

  /**
   * Routes steps. The approve/reject branch is expressed here in the DAG, not inside
   * the approval step itself, to keep the step's responsibility narrow (read signal,
   * surface payload) and make the routing logic visible and testable at the definition level.
   */
  public String getNextStep(String currentStepName, StepResult result) {
    if (currentStepName == 'NativeApprovalWorkflowExample.ReserveBudgetStep') {
      return 'NativeApprovalWorkflowExample.RequestApprovalStep';
    }
    if (currentStepName == 'NativeApprovalWorkflowExample.RequestApprovalStep') {
      if (result.outputJson != null) {
        Map<String, Object> decision = (Map<String, Object>) JSON.deserializeUntyped(
          result.outputJson
        );
        Boolean approved =
          decision.get('approved') != null &&
          (Boolean) decision.get('approved');
        return approved
          ? 'NativeApprovalWorkflowExample.PlaceOrderStep'
          : 'NativeApprovalWorkflowExample.RejectStep';
      }
    }
    return null;
  }

  // --- STEP DEFINITIONS ---

  /**
   * Reserves budget for the purchase. Implements CompensatableStep so the engine pushes
   * it onto Compensation_Stack__c on completion; if the native Approval Process later
   * rejects and the bridge Flow signals a rejection, compensate() releases the
   * reservation automatically via LIFO rollback -- the saga behaviour a native Approval
   * Process alone cannot express.
   */
  public class ReserveBudgetStep implements CompensatableStep {
    public StepResult execute(StepContext ctx) {
      Decimal amount = 0;
      if (String.isNotBlank(ctx.workflowInputJson)) {
        try {
          Map<String, Object> input = (Map<String, Object>) JSON.deserializeUntyped(
            ctx.workflowInputJson
          );
          if (input.containsKey('amount')) {
            amount = (Decimal) input.get('amount');
          }
        } catch (Exception e) {
          System.debug(
            LoggingLevel.WARN,
            'Failed to deserialize input JSON: ' + e.getMessage()
          );
        }
      }
      String reservationId = 'res_' + String.valueOf(amount).replace('.', '_');
      return StepResult.complete(
        null,
        new Map<String, Object>{
          'reservationId' => reservationId,
          'amount' => amount
        }
      );
    }

    /**
     * Releases the reserved budget. The original step output is available via
     * ctx.stepStateJson so the exact reservation ID can be retrieved without SOQL.
     */
    public StepResult compensate(StepContext ctx) {
      String reservationId = 'res_unknown';
      if (String.isNotBlank(ctx.stepStateJson)) {
        try {
          Map<String, Object> orig = (Map<String, Object>) JSON.deserializeUntyped(
            ctx.stepStateJson
          );
          if (orig.containsKey('reservationId')) {
            reservationId = (String) orig.get('reservationId');
          }
        } catch (Exception e) {
          System.debug(
            LoggingLevel.WARN,
            'Failed to deserialize step state JSON: ' + e.getMessage()
          );
        }
      }
      return StepResult.complete(
        null,
        new Map<String, Object>{
          'released' => true,
          'reservationId' => reservationId
        }
      );
    }
  }

  /**
   * Suspends the workflow pending the native Approval Process's decision.
   *
   * First execution: no signal present -> waitForApproval() suspends; instance status
   * becomes Suspended. The native Approval Process's approver inbox is the only surface
   * a human interacts with -- there is no Revenant-side UI to build or gate.
   *
   * On resume: the bridge Flow's decision signal is readable from ctx; the step surfaces
   * the full payload as its output so getNextStep() can route to PlaceOrderStep or
   * RejectStep. The engine marks the observed signal(s) Consumed at the COMPLETE
   * transition, so an at-least-once redelivered duplicate (e.g. the bridge Flow re-firing)
   * cannot advance the workflow twice.
   */
  public class RequestApprovalStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      StepContext.Signal decision = ctx.getSignal(DECISION_SIGNAL);

      if (!decision.isPresent()) {
        // The second argument is an optional Custom Permission API name that
        // WorkflowDashboardController.enforceApprovalRole would require an approver to
        // hold if this workflow were also decided from the dashboard. Left null here:
        // the native Approval Process's assigned approver is this example's
        // least-privilege boundary, so there is nothing further to gate on the Revenant
        // side. Pass a shipped permission (e.g. 'Workflow_Admin') to additionally
        // restrict the dashboard's fallback decision path.
        return StepResult.waitForApproval(APPROVAL_KEY, null);
      }

      Map<String, Object> payload = (Map<String, Object>) JSON.deserializeUntyped(
        decision.payload
      );
      return StepResult.complete(null, payload);
    }
  }

  /** Terminal step on the approved path. */
  public class PlaceOrderStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(
        null,
        new Map<String, Object>{
          'result' => 'approved',
          'orderId' => 'ord_' + ctx.workflowInstanceId
        }
      );
    }
  }

  /**
   * Terminal step on the rejected path. Throwing WorkflowException signals to the engine
   * that this workflow instance has failed. Because ReserveBudgetStep is a CompensatableStep
   * whose name is on Compensation_Stack__c, the engine unwinds it in LIFO order:
   * ReserveBudgetStep.compensate() is called and the instance reaches Compensated.
   * This is the saga-on-reject behaviour that native Approval Processes cannot express.
   */
  public class RejectStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      String reason = 'rejected';
      if (String.isNotBlank(ctx.inputJson)) {
        try {
          Map<String, Object> decision = (Map<String, Object>) JSON.deserializeUntyped(
            ctx.inputJson
          );
          // The outbound bridge Flow's payload carries the approver's note under
          // 'comments'; accept 'reason' too so a direct Apex/Flow signal using either
          // key still survives into the failure message.
          Object note = decision.containsKey('reason')
            ? decision.get('reason')
            : decision.get('comments');
          if (note != null) {
            reason = String.valueOf(note);
          }
        } catch (Exception e) {
          System.debug(
            LoggingLevel.WARN,
            'Failed to deserialize rejection input JSON: ' + e.getMessage()
          );
        }
      }
      throw new WorkflowEngine.WorkflowException(
        'Approval rejected: ' + reason
      );
    }
  }
}
