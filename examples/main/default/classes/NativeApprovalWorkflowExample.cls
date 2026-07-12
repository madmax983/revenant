/**
 * Reference example for issue #125: bridging a native Salesforce Approval Process to a
 * durable Revenant workflow, instead of building a bespoke approver inbox.
 *
 * Shape:
 *   ReserveBudgetStep (CompensatableStep)
 *     -> RequestApprovalStep (suspends; automatically submits the record; on resume surfaces the decision as output)
 *          approve -> PlaceOrderStep -> Completed
 *          reject  -> RejectStep -> WorkflowException -> LIFO compensation -> Compensated
 *
 * The approver-facing surface here is deliberately NOT a custom LWC: a native Approval
 * Process already ships an approver inbox, mobile approve/reject, and delegation, so this
 * example reuses it rather than rebuilding it. The bridge from the native process to this
 * suspended gate is wired via standard SObjects (e.g. standard Case) and a trigger/flow bridge:
 *
 *   1. A Case is created. An after-insert trigger (CaseApprovalBridgeTrigger) starts the
 *      workflow, correlating on the Case ID.
 *   2. The workflow executes. When it reaches RequestApprovalStep, it automatically queries the
 *      correlation key (the Case ID) and submits it to the native Salesforce Approval Process
 *      (Case.Revenant_Trigger_Approval_Example.approvalProcess-meta.xml).
 *   3. The request lands in the standard Salesforce Approval Requests tab/inbox.
 *   4. The designated approver acts on the request. On approval/rejection, the native process
 *      performs a final field update to Case.Approval_Status__c (e.g. to 'Approved' or 'Rejected').
 *   5. The Case trigger (CaseApprovalBridgeTrigger) detects this update, queries the approval comments
 *      from ProcessInstanceStep, and signals the workflow to resume.
 *
 * Revenant supplies the orchestration primitives (waitForApproval + signal-driven resume);
 * the native Salesforce Approval Process handles the human-facing workflow (routing, delegation,
 * and the standard global Approvals inbox).
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

  /**
   * @description Declares the steps that make up this workflow definition.
   * @return The fully-qualified step names in the definition.
   */
  public List<String> getSteps() {
    return new List<String>{
      'NativeApprovalWorkflowExample.ReserveBudgetStep',
      'NativeApprovalWorkflowExample.RequestApprovalStep',
      'NativeApprovalWorkflowExample.PlaceOrderStep',
      'NativeApprovalWorkflowExample.RejectStep'
    };
  }

  /**
   * @description Names the step the engine runs first when an instance starts.
   * @return The fully-qualified initial step name.
   */
  public String getInitialStep() {
    return 'NativeApprovalWorkflowExample.ReserveBudgetStep';
  }

  /**
   * Routes steps. The approve/reject branch is expressed here in the DAG, not inside
   * the approval step itself, to keep the step's responsibility narrow (read signal,
   * surface payload) and make the routing logic visible and testable at the definition level.
   *
   * @param currentStepName The name of the step that just completed.
   * @param result The completed step's result, carrying any decision output.
   * @return The next step name, or null when the workflow is complete.
   */
  public String getNextStep(String currentStepName, StepResult result) {
    if (currentStepName == 'NativeApprovalWorkflowExample.ReserveBudgetStep') {
      return 'NativeApprovalWorkflowExample.RequestApprovalStep';
    }
    if (
      currentStepName == 'NativeApprovalWorkflowExample.RequestApprovalStep'
    ) {
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

  /**
   * @description Reads a JSON object string into a Map, yielding an empty Map when the input
   * is blank or cannot be parsed. Folding the guard into one place lets each step read the
   * decision keys it needs without repeating null checks or inline parse-failure handling.
   * @param jsonText The JSON object string to deserialize.
   * @return The deserialized Map, or an empty Map when the input is blank or malformed.
   */
  private static Map<String, Object> deserializeJson(String jsonText) {
    if (String.isBlank(jsonText)) {
      return new Map<String, Object>();
    }
    try {
      return (Map<String, Object>) JSON.deserializeUntyped(jsonText);
    } catch (Exception ignored) {
      return new Map<String, Object>();
    }
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
    /**
     * @description Reserves budget for the purchase, deriving a reservation id
     * from the requested amount and returning it as the step output.
     * @param ctx The durable step context carrying the workflow input.
     * @return A completed StepResult carrying the reservation id and amount.
     */
    public StepResult execute(StepContext ctx) {
      Decimal amount = 0;
      Map<String, Object> input = deserializeJson(ctx.workflowInputJson);
      if (input.containsKey('amount')) {
        amount = (Decimal) input.get('amount');
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
     *
     * @param ctx The step context carrying the original step output as state.
     * @return A completed StepResult recording the released reservation.
     */
    public StepResult compensate(StepContext ctx) {
      String reservationId = 'res_unknown';
      Map<String, Object> orig = deserializeJson(ctx.stepStateJson);
      if (orig.containsKey('reservationId')) {
        reservationId = (String) orig.get('reservationId');
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
  public inherited sharing class RequestApprovalStep implements WorkflowStep {
    /**
     * @description On first run, submits the correlated record to the native
     * Approval Process and suspends; on resume, surfaces the decision signal's
     * payload as output so the DAG can route to the approve/reject branch.
     * @param ctx The step context, used to read the decision signal.
     * @return A waitForApproval result when suspending, or a completed result
     * carrying the decision payload on resume.
     */
    public StepResult execute(StepContext ctx) {
      StepContext.Signal decision = ctx.getSignal(DECISION_SIGNAL);

      if (!decision.isPresent()) {
        // Query the Workflow_Instance__c record to retrieve its Correlation_Key__c.
        // If it is a valid SObject ID, automatically submit it to the native Approval Process.
        // This ensures the approval request shows up in the standard Salesforce Approval Requests tab/inbox.
        String correlationKey = getCorrelationKey(ctx.workflowInstanceId);
        submitRecordIfValid(correlationKey);

        // The second argument is an optional Custom Permission API name that
        // WorkflowDashboardController.enforceApprovalRole would require an approver to
        // hold if this workflow were also decided from the dashboard. Left null here:
        // this example relies on the native Approval Process's approver assignment to
        // decide who is *prompted* to act, not on any check at the signal layer itself.
        return StepResult.waitForApproval(APPROVAL_KEY, null);
      }

      Map<String, Object> payload = (Map<String, Object>) JSON.deserializeUntyped(
        decision.payload
      );
      return StepResult.complete(null, payload);
    }

    private String getCorrelationKey(Id instanceId) {
      if (instanceId == null) {
        return null;
      }
      try {
        Workflow_Instance__c inst = [
          SELECT Correlation_Key__c
          FROM Workflow_Instance__c
          WHERE Id = :instanceId
          WITH SYSTEM_MODE
          LIMIT 1
        ];
        return inst.Correlation_Key__c;
      } catch (Exception e) {
        return null;
      }
    }

    private void submitRecordIfValid(String correlationKey) {
      if (String.isBlank(correlationKey)) {
        return;
      }
      try {
        Id recordId = (Id) correlationKey;
        Approval.ProcessSubmitRequest submitReq = new Approval.ProcessSubmitRequest();
        submitReq.setObjectId(recordId);
        // Let Salesforce pick the active process whose entry criteria matches
        Approval.process(submitReq, false);
      } catch (Exception ignored) {
      }
    }
  }

  /** Terminal step on the approved path. */
  public class PlaceOrderStep implements WorkflowStep {
    /**
     * @description Places the order on the approved path, returning a synthesized
     * order id as the terminal output.
     * @param ctx The step context, used for the instance id.
     * @return A completed StepResult carrying the order result and id.
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
     * @description Fails the workflow on the rejected path by throwing, which
     * triggers LIFO compensation of the reserved budget.
     * @param ctx The step context carrying the rejection input.
     * @return Never returns normally; always throws a WorkflowException.
     */
    public StepResult execute(StepContext ctx) {
      String reason = 'rejected';
      Map<String, Object> decision = deserializeJson(ctx.inputJson);
      // The outbound bridge Flow's payload carries the approver's note under
      // 'comments'; accept 'reason' too so a direct Apex/Flow signal using either
      // key still survives into the failure message.
      Object note = decision.containsKey('reason')
        ? decision.get('reason')
        : decision.get('comments');
      if (note != null) {
        reason = String.valueOf(note);
      }
      throw new WorkflowEngine.WorkflowException(
        'Approval rejected: ' + reason
      );
    }
  }
}
