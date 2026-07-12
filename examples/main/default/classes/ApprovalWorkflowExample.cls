/**
 * Reference example for issue #29: human-in-the-loop approval with saga rollback on rejection.
 *
 * Shape:
 *   ReserveBudgetStep (CompensatableStep)
 *     -> RequestApprovalStep (suspends; on resume surfaces the decision as output)
 *          approve -> PlaceOrderStep -> Completed
 *          reject  -> RejectStep -> WorkflowException -> LIFO compensation -> Compensated
 *
 * This is the canonical enterprise durable-workflow shape -- "do work, wait for approval,
 * approve continues / reject rolls back prior work" -- that native Approval Processes
 * cannot express because they have no durable multi-step orchestration or compensating rollback.
 */
public inherited sharing class ApprovalWorkflowExample implements WorkflowDefinition {
  /** Approval gate identifier passed to waitForApproval(). */
  public static final String APPROVAL_KEY = 'PurchaseApproval';

  /**
   * Signal name an approver publishes to convey their decision. Must match the
   * dashboard's submitApproval convention and WorkflowSignalInvocableAction:
   * both publish 'Approve:' + approvalKey.
   */
  public static final String DECISION_SIGNAL = 'Approve:' + APPROVAL_KEY;

  /**
   * @description Declares the ordered step names comprising the approval saga.
   * @return The list of ReserveBudget, RequestApproval, PlaceOrder, and Reject step names.
   */
  public List<String> getSteps() {
    return new List<String>{
      'ApprovalWorkflowExample.ReserveBudgetStep',
      'ApprovalWorkflowExample.RequestApprovalStep',
      'ApprovalWorkflowExample.PlaceOrderStep',
      'ApprovalWorkflowExample.RejectStep'
    };
  }

  /**
   * @description Names the step the engine runs first for a new instance.
   * @return The ReserveBudgetStep step name.
   */
  public String getInitialStep() {
    return 'ApprovalWorkflowExample.ReserveBudgetStep';
  }

  /**
   * @description Routes steps. The approve/reject branch is expressed here in the DAG, not inside
   * the approval step itself, to keep the step's responsibility narrow (read signal,
   * surface payload) and make the routing logic visible and testable at the definition level.
   * @param currentStepName The name of the step that just completed.
   * @param result The result of the completed step, whose output carries the approval decision.
   * @return The next step name (PlaceOrder on approve, Reject on rejection), or null when complete.
   */
  public String getNextStep(String currentStepName, StepResult result) {
    if (currentStepName == 'ApprovalWorkflowExample.ReserveBudgetStep') {
      return 'ApprovalWorkflowExample.RequestApprovalStep';
    }
    if (currentStepName == 'ApprovalWorkflowExample.RequestApprovalStep') {
      if (result.outputJson != null) {
        Map<String, Object> decision = (Map<String, Object>) JSON.deserializeUntyped(
          result.outputJson
        );
        Boolean approved =
          decision.get('approved') != null &&
          (Boolean) decision.get('approved');
        return approved
          ? 'ApprovalWorkflowExample.PlaceOrderStep'
          : 'ApprovalWorkflowExample.RejectStep';
      }
    }
    return null;
  }

  // --- STEP DEFINITIONS ---

  /**
   * Reserves budget for the purchase. Implements CompensatableStep so the engine
   * pushes it onto Compensation_Stack__c on completion; if the workflow is later
   * rejected, compensate() releases the reservation automatically via LIFO rollback.
   */
  public class ReserveBudgetStep implements CompensatableStep {
    /**
     * @description Reserves budget for the purchase, deriving a reservation ID from
     * the workflow input's purchaseAmount and surfacing it for later compensation.
     * @param ctx The durable step context exposing the workflow input JSON.
     * @return A completed StepResult carrying the reservationId and amount.
     */
    public StepResult execute(StepContext ctx) {
      Decimal amount = 0;
      if (String.isNotBlank(ctx.workflowInputJson)) {
        try {
          Map<String, Object> input = (Map<String, Object>) JSON.deserializeUntyped(
            ctx.workflowInputJson
          );
          if (input.containsKey('purchaseAmount')) {
            amount = (Decimal) input.get('purchaseAmount');
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
     * @description Releases the reserved budget. The original step output is available via
     * ctx.stepStateJson so the exact reservation ID can be retrieved without SOQL.
     * @param ctx The durable step context exposing the original step state JSON.
     * @return A completed StepResult recording the released reservationId.
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
   * Suspends the workflow pending an external approval decision.
   *
   * First execution: no signal present -> waitForApproval() suspends; instance status
   * becomes Suspended. An Admin or Flow Builder then signals the workflow via
   * WorkflowSignalInvocableAction (signal name 'Approve:PurchaseApproval').
   *
   * On resume: the decision signal is readable from ctx; the step surfaces the full
   * payload as its output so getNextStep() can route to PlaceOrderStep or RejectStep.
   * The engine marks the observed signal(s) Consumed at the COMPLETE transition, so an
   * at-least-once redelivered duplicate cannot advance the workflow twice.
   */
  public class RequestApprovalStep implements WorkflowStep {
    /**
     * @description On first run, suspends via waitForApproval awaiting the decision
     * signal; on resume, surfaces the signal payload as output for routing.
     * @param ctx The durable step context used to read the approval decision signal.
     * @return A waitForApproval StepResult when undecided, else a completed result with the decision payload.
     */
    public StepResult execute(StepContext ctx) {
      StepContext.Signal decision = ctx.getSignal(DECISION_SIGNAL);

      if (!decision.isPresent()) {
        // The second argument is an optional Custom Permission API name that the
        // built-in dashboard (WorkflowDashboardController.enforceApprovalRole) requires
        // an approver to hold. null leaves the gate unrestricted for this demo so any
        // authorized dashboard/Flow user can approve out of the box; pass a shipped
        // permission such as 'Workflow_Admin' to restrict who may decide.
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
    /**
     * @description Places the order on the approved path and completes the workflow.
     * @param ctx The durable step context supplying the workflow instance id for the order id.
     * @return A completed StepResult carrying the approved result and generated orderId.
     */
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
    /**
     * @description Fails the instance on the rejected path by throwing a
     * WorkflowException, which triggers LIFO compensation of prior steps.
     * @param ctx The durable step context exposing the rejection input JSON for the audit note.
     * @return Never returns normally; always throws WorkflowException to fail the instance.
     */
    public StepResult execute(StepContext ctx) {
      String reason = 'rejected';
      if (String.isNotBlank(ctx.inputJson)) {
        try {
          Map<String, Object> decision = (Map<String, Object>) JSON.deserializeUntyped(
            ctx.inputJson
          );
          // The built-in dashboard's submitApproval records the approver's note under
          // 'comments'; a Flow or Apex signal might instead use 'reason'. Accept either
          // so the approver's audit note survives into the failure message.
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
