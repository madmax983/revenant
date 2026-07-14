/**
 * Reference example: effectively-once outbound emit for step-to-step
 * choreography (issue #64).
 *
 * Workflow A (ShipmentWorkflow) ships an order and, when its ShipOrderStep
 * COMPLETEs, emits a domain event (Order_Shipped__e). A subscriber trigger
 * (OrderShippedTrigger) starts Workflow B (RefundWorkflow). The engine couples
 * the publish to the step's COMPLETE commit, so retries / re-drives /
 * at-least-once resumes never double-start B — the author writes no dedup token.
 *
 * Contrast: calling EventBus.publish() directly inside execute() would re-fire
 * on every at-least-once re-execution, double-triggering the refund. With
 * ctx.events().emit() the engine publishes once, anchored on the append-only Completed
 * record. (StepResult.complete(next, output, events) is the equivalent form when
 * you already have the events in hand at the return site.)
 *
 * See README.md for the full inbound/outbound choreography story.
 */
public inherited sharing class OrderChoreographyWorkflowExample {
  /**
   * Counts how many times the Order_Shipped__e subscriber started the refund
   * workflow. The choreography test asserts this is 1 even though the shipping
   * step re-executes (and calls emit()) three times. Lives on the top-level
   * class because Apex allows statics only on a top-level type.
   */
  public static Integer refundStartCount = 0;

  /**
   * @description Resets the refund-start counter so a test can assert the effectively-once
   * emission from a known baseline.
   */
  public static void resetCounters() {
    refundStartCount = 0;
  }

  /**
   * Subscriber entry point invoked by OrderShippedTrigger for each delivered
   * Order_Shipped__e. Get-or-start keeps it idempotent on the consumer side too,
   * but the producer-side effectively-once publish is what keeps it from being
   * asked to start B more than once per shipment.
   *
   * @param events The delivered Order_Shipped__e events driving get-or-start of the refund workflow.
   */
  public static void onOrderShipped(List<Order_Shipped__e> events) {
    // Bulk-safe: a platform-event trigger can deliver many events in one
    // transaction, and each WorkflowEngine.start() does SOQL + workflow-row DML
    // + an enqueue. Starting one-by-one in a loop would blow the per-transaction
    // governor limits on a normal bulk delivery and roll back the whole
    // subscriber. Build one batch of StartRequests and use the bulk start path
    // (get-or-start), which runs the whole delivery in a single set of DML.
    List<WorkflowEngine.StartRequest> requests = new List<WorkflowEngine.StartRequest>();
    for (Order_Shipped__e evt : events) {
      refundStartCount++;
      WorkflowEngine.StartRequest req = new WorkflowEngine.StartRequest(
        'OrderChoreographyWorkflowExample.RefundWorkflow',
        'refund-' + evt.Correlation_Key__c,
        new Map<String, Object>{ 'orderId' => evt.Order_Id__c }
      );
      req.causationId = evt.Trace_Id__c;
      requests.add(req);
    }
    if (!requests.isEmpty()) {
      WorkflowEngine.start(requests);
    }
  }

  // ----- Workflow A: ship the order, emit Order_Shipped__e on COMPLETE. -------

  /**
   * @description Workflow A: a single-step definition that ships the order and emits
   * Order_Shipped__e when its ShipOrderStep completes.
   */
  public class ShipmentWorkflow implements WorkflowDefinition {
    /**
     * @description Lists the steps that make up this workflow.
     * @return The ordered list of fully-qualified step names.
     */
    public List<String> getSteps() {
      return new List<String>{
        'OrderChoreographyWorkflowExample.ShipOrderStep'
      };
    }
    /**
     * @description Names the first step executed when an instance starts.
     * @return The fully-qualified initial step name.
     */
    public String getInitialStep() {
      return 'OrderChoreographyWorkflowExample.ShipOrderStep';
    }
    /**
     * @description Routes to the next step; this workflow completes after its only step.
     * @param currentStep The name of the step that just completed.
     * @param result The result of the completed step.
     * @return Always null, signalling the workflow is complete.
     */
    public String getNextStep(String currentStep, StepResult result) {
      return null;
    }
  }

  /**
   * Emits the Order_Shipped__e on every execution but only reaches COMPLETE on
   * the third, driven through a yield and a retry first. This reproduces the
   * >=3-re-executions-before-commit scenario; effectively-once means the event
   * publishes exactly once, on the final COMPLETE commit.
   *
   * (A real shipping step would just do its work and return
   * StepResult.complete(null, output) after ctx.events().emit(...) — the yield/retry here
   * exists only to force re-execution for the test.)
   */
  public inherited sharing class ShipOrderStep implements WorkflowStep {
    /**
     * @description Buffers an Order_Shipped__e via ctx.emit on every execution but only
     * reaches COMPLETE on the third run (after a yield and a retry), demonstrating that the
     * event publishes exactly once on the final commit.
     * @param ctx The durable step context carrying workflow input and step state.
     * @return A yield, retry, or complete StepResult depending on the execution phase.
     */
    public StepResult execute(StepContext ctx) {
      Map<String, Object> input = (Map<String, Object>) JSON.deserializeUntyped(
        ctx.workflowInputJson
      );
      String orderId = (String) input.get('orderId');
      // Buffered every execution; published only when this step's COMPLETE
      // transition commits.
      ctx.events()
        .emit(
          new Order_Shipped__e(
            Order_Id__c = orderId,
            Correlation_Key__c = orderId,
            Trace_Id__c = ctx.workflowInstanceId
          )
        );

      Integer retryCount = currentRetryCount(ctx);

      Boolean resumedFromYield = String.isNotBlank(ctx.stepStateJson);

      if (retryCount == 0 && !resumedFromYield) {
        return StepResult.yield('{"phase":"yielded"}');
      }
      if (retryCount == 0 && resumedFromYield) {
        return StepResult.retry(new RetryPolicy(1, (Double) 1.0, 3));
      }
      return StepResult.complete(
        null,
        new Map<String, Object>{ 'orderId' => orderId, 'shipped' => true }
      );
    }

    // Durable retry count for this step's execution row. Unlike stepStateJson
    // (cleared on RETRY), Retry_Count__c survives the retry, so it tells a
    // post-retry resume (>=1) apart from a fresh first run (0).
    private Integer currentRetryCount(StepContext ctx) {
      List<Workflow_Step_Execution__c> execs = [
        SELECT Retry_Count__c
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :ctx.workflowInstanceId
          AND Step_Name__c = :ctx.stepName
        WITH SYSTEM_MODE
        ORDER BY CreatedDate DESC, Id DESC
        LIMIT 1
      ];
      if (execs.isEmpty() || execs[0].Retry_Count__c == null) {
        return 0;
      }
      return execs[0].Retry_Count__c.intValue();
    }
  }

  // ----- Workflow B: started by the Order_Shipped__e subscriber. --------------

  /**
   * @description Workflow B: a single-step refund definition started by the Order_Shipped__e
   * subscriber once shipment completes.
   */
  public class RefundWorkflow implements WorkflowDefinition {
    /**
     * @description Lists the steps that make up this workflow.
     * @return The ordered list of fully-qualified step names.
     */
    public List<String> getSteps() {
      return new List<String>{
        'OrderChoreographyWorkflowExample.IssueRefundStep'
      };
    }
    /**
     * @description Names the first step executed when an instance starts.
     * @return The fully-qualified initial step name.
     */
    public String getInitialStep() {
      return 'OrderChoreographyWorkflowExample.IssueRefundStep';
    }
    /**
     * @description Routes to the next step; this workflow completes after its only step.
     * @param currentStep The name of the step that just completed.
     * @param result The result of the completed step.
     * @return Always null, signalling the workflow is complete.
     */
    public String getNextStep(String currentStep, StepResult result) {
      return null;
    }
  }

  /**
   * @description The single refund step of Workflow B, which completes immediately.
   */
  public class IssueRefundStep implements WorkflowStep {
    /**
     * @description Issues the refund and completes the workflow.
     * @param ctx The durable step context for this execution.
     * @return A completed StepResult carrying the refund outcome.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, 'refund-issued');
    }
  }
}
