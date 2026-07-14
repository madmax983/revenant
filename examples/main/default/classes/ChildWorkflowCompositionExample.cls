/**
 * ChildWorkflowCompositionExample — reference for parent→child workflow composition.
 *
 * A LoanApplication parent delegates credit scoring to a CreditCheck child workflow,
 * then branches on the child's output: approve the loan if the score meets the
 * threshold, otherwise decline it.
 *
 * Engine contract demonstrated
 * ─────────────────────────────
 * 1. StepResult.startChild() suspends the parent and starts the child's own
 *    durable Queueable chain.  The parent must NOT poll or loop — it simply returns
 *    startChild on the first run and suspends until the engine wakes it.
 *
 * 2. When the child reaches Completed the engine publishes a
 *    ChildCompleted:<childCorrelationKey> Platform Event targeting the parent.  The
 *    parent step reads the child's output with ctx.getSignal(...).payload — no
 *    hand-rolled SOQL against Workflow_Signal__c.
 *
 * 3. Returning StepResult.complete() from the resuming step triggers engine-managed
 *    signal consumption: every Received signal of the observed name is marked
 *    Consumed at the COMPLETE transition.  A redelivered at-least-once duplicate
 *    therefore cannot double-advance the parent.
 *
 * 4. WorkflowEngine.cancel(parentId) cancels the parent and all of its
 *    active descendants (root-first traversal over Parent_Instance__c), so
 *    explicitly cancelling a parent reaps its in-flight children.  Note this is
 *    cancellation only: a parent that FAILS is not cascaded — failWorkflowInstance
 *    does not traverse Parent_Instance__c — and a child that fails or times out
 *    never publishes ChildCompleted, so its parent stays Suspended.  A production
 *    composite would add its own child-failure/timeout signal to cover that path.
 */
public inherited sharing class ChildWorkflowCompositionExample implements WorkflowDefinition {
  /** Minimum credit score required to approve the loan. */
  public static final Integer APPROVE_THRESHOLD = 680;

  // ---------------------------------------------------------------------------
  // PARENT WORKFLOW DEFINITION
  // ---------------------------------------------------------------------------

  /**
   * @description Returns the ordered step names composing the parent loan workflow.
   * @return The request-credit-check, approve, decline, and failure-handling step names.
   */
  public List<String> getSteps() {
    return new List<String>{
      'ChildWorkflowCompositionExample.RequestCreditCheckStep',
      'ChildWorkflowCompositionExample.ApproveLoanStep',
      'ChildWorkflowCompositionExample.DeclineLoanStep',
      'ChildWorkflowCompositionExample.HandleCreditCheckFailureStep'
    };
  }

  /**
   * @description Returns the step the parent workflow begins with.
   * @return The request-credit-check step name.
   */
  public String getInitialStep() {
    return 'ChildWorkflowCompositionExample.RequestCreditCheckStep';
  }

  /**
   * @description Routes to the branch RequestCreditCheckStep chose by embedding the
   * next step name in its COMPLETE result; the approve/decline steps are terminal.
   * @param currentStepName The name of the step that just completed.
   * @param stepResult The result of the completed step, carrying the chosen next step.
   * @return The next step name set by the credit-check step, or null to end the workflow.
   */
  public String getNextStep(String currentStepName, StepResult stepResult) {
    if (
      currentStepName ==
      'ChildWorkflowCompositionExample.RequestCreditCheckStep'
    ) {
      return stepResult.nextStepName;
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // PARENT STEPS
  // ---------------------------------------------------------------------------

  /**
   * Launcher + resume handler in one idempotent step.
   *
   * Resume run — ChildCompleted:<childKey> signal is present → read the child's
   *              credit score from the payload, decide the branch, and return
   *              COMPLETE.  The COMPLETE transition marks every Received signal of
   *              the observed name Consumed, so at-least-once redelivered duplicates
   *              cannot cause a second advance.
   *
   * Re-entry  — no signal yet, but a child with this correlation key already
   *              exists → re-suspend.  The engine re-runs the current step on any
   *              stray orchestrator hop / watchdog re-check / redelivered resume
   *              while the instance is Suspended. Calling startChild() a second time
   *              with the same key resolves to a native idempotent re-suspend.
   *
   * First run — no signal and no child yet → startChild.  The engine suspends the
   *              parent and starts the child's own Queueable chain.  This same step
   *              is re-run (not a new step) when the child completes.
   */
  public class RequestCreditCheckStep implements WorkflowStep {
    /**
     * @description Launches the CreditCheck child on first run and suspends; on the
     * child's completion signal reads the score, decides the branch, and completes.
     * @param ctx The durable step context exposing the child outcome and workflow input.
     * @return startChild while awaiting the child, or COMPLETE routing to the decision branch.
     */
    public StepResult execute(StepContext ctx) {
      String childKey = 'CreditCheck_' + ctx.workflowInstanceId;
      StepContext.ChildOutcome outcome = ctx.getChildOutcome(childKey);

      if (outcome.isPresent()) {
        if (outcome.isSuccess()) {
          // Resume: the child completed.  Its serialised output is the signal payload.
          // For large child outputs the payload may be a blob reference; resolve it.
          String childOutputJson = WorkflowEngine.resolvePayload(
            outcome.output
          );
          Map<String, Object> childResult = (Map<String, Object>) JSON.deserializeUntyped(
            childOutputJson
          );
          Integer creditScore = ((Decimal) childResult.get('creditScore'))
            .intValue();
          Boolean approved = creditScore >= APPROVE_THRESHOLD;

          Map<String, Object> decision = new Map<String, Object>{
            'approved' => approved,
            'creditScore' => creditScore,
            'applicant' => childResult.get('applicant')
          };

          String nextStep = approved
            ? 'ChildWorkflowCompositionExample.ApproveLoanStep'
            : 'ChildWorkflowCompositionExample.DeclineLoanStep';

          // Returning COMPLETE lets the engine consume all same-name Received signals
          // (engine-managed idempotency — no manual sig.Status__c='Consumed' needed).
          return StepResult.complete(nextStep, decision);
        } else {
          // Fallback if child failed/cancelled/timed out
          Map<String, Object> decision = new Map<String, Object>{
            'status' => outcome.status,
            'errorMessage' => outcome.errorMessage
          };
          return StepResult.complete(
            'ChildWorkflowCompositionExample.HandleCreditCheckFailureStep',
            decision
          );
        }
      }

      // No completion signal yet. First run or re-entrant hop: delegate credit scoring
      // to the child workflow and suspend. The engine handles re-entrancy idempotently.

      // First run: delegate credit scoring to the child workflow and suspend.
      Map<String, Object> applicantData = (Map<String, Object>) JSON.deserializeUntyped(
        ctx.workflowInputJson
      );
      return StepResult.startChild(
        'ChildWorkflowCompositionExample.CreditCheckWorkflow',
        childKey,
        applicantData
      );
    }
  }

  /**
   * @description Terminal step reached when the credit score meets the threshold.
   */
  public class ApproveLoanStep implements WorkflowStep {
    /**
     * @description Records the loan-approved decision and ends the workflow.
     * @param ctx The durable step context supplying the credit-check decision input.
     * @return A COMPLETE result carrying the approval decision and applicant details.
     */
    public StepResult execute(StepContext ctx) {
      Map<String, Object> input = (Map<String, Object>) JSON.deserializeUntyped(
        ctx.inputJson
      );
      return StepResult.complete(
        null,
        new Map<String, Object>{
          'decision' => 'approved',
          'creditScore' => input.get('creditScore'),
          'applicant' => input.get('applicant'),
          'message' => 'Loan application approved.'
        }
      );
    }
  }

  /**
   * @description Terminal step reached when the credit score is below the threshold.
   */
  public class DeclineLoanStep implements WorkflowStep {
    /**
     * @description Records the loan-declined decision and ends the workflow.
     * @param ctx The durable step context supplying the credit-check decision input.
     * @return A COMPLETE result carrying the decline decision and applicant details.
     */
    public StepResult execute(StepContext ctx) {
      Map<String, Object> input = (Map<String, Object>) JSON.deserializeUntyped(
        ctx.inputJson
      );
      return StepResult.complete(
        null,
        new Map<String, Object>{
          'decision' => 'declined',
          'creditScore' => input.get('creditScore'),
          'applicant' => input.get('applicant'),
          'message' => 'Loan application declined: credit score below threshold.'
        }
      );
    }
  }

  // ---------------------------------------------------------------------------
  // CHILD WORKFLOW DEFINITION
  // ---------------------------------------------------------------------------

  /**
   * @description Child workflow definition that computes a credit score in a single
   * step and completes, signaling its parent.
   */
  public class CreditCheckWorkflow implements WorkflowDefinition {
    /**
     * @description Returns the sole step composing the child workflow.
     * @return A one-element list naming the compute-credit-score step.
     */
    public List<String> getSteps() {
      return new List<String>{
        'ChildWorkflowCompositionExample.ComputeCreditScoreStep'
      };
    }

    /**
     * @description Returns the step the child workflow begins with.
     * @return The compute-credit-score step name.
     */
    public String getInitialStep() {
      return 'ChildWorkflowCompositionExample.ComputeCreditScoreStep';
    }

    /**
     * @description Terminal single-step child workflow: there is no successor step.
     * @param currentStepName The name of the step that just completed.
     * @param stepResult The result of the completed step.
     * @return Always null, ending the child workflow after the scoring step.
     */
    public String getNextStep(String currentStepName, StepResult stepResult) {
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // CHILD STEP
  // ---------------------------------------------------------------------------

  /**
   * Deterministic credit-score formula driven by the applicant data that the parent
   * forwarded as the child's input.  In production this would call a bureau API;
   * the formula keeps the test free of mocking.
   *
   * score = 600 + min(annualIncome / 1_000, 250) − min(requestedAmount / 5_000, 150)
   * clamped to [300, 850].
   *
   * Example values used in the companion test
   *   High score: income=100 000, amount=50 000  → 600+100−10 = 690  (≥680, approved)
   *   Low  score: income=20 000,  amount=200 000 → 600+20−40  = 580  (<680, declined)
   */
  public class ComputeCreditScoreStep implements WorkflowStep {
    /**
     * @description Computes the applicant's credit score from the forwarded input
     * using the deterministic formula, throwing for the 'FailMe' applicant to
     * exercise the parent's child-failure branch.
     * @param ctx The durable step context supplying the applicant input JSON.
     * @return A COMPLETE result carrying the clamped credit score and applicant name.
     */
    public StepResult execute(StepContext ctx) {
      Map<String, Object> input = (Map<String, Object>) JSON.deserializeUntyped(
        ctx.workflowInputJson
      );
      Decimal income = input.containsKey('annualIncome')
        ? (Decimal) input.get('annualIncome')
        : 0;
      Decimal amount = input.containsKey('requestedAmount')
        ? (Decimal) input.get('requestedAmount')
        : 0;
      String applicant = (String) input.get('applicant');

      if (applicant == 'FailMe') {
        throw new IllegalArgumentException('Simulated credit check failure');
      }

      Integer incomeBonus = (Integer) Math.min(income / 1000, 250);
      Integer amountPenalty = (Integer) Math.min(amount / 5000, 150);
      Integer score = 600 + incomeBonus - amountPenalty;
      score = Math.max(300, Math.min(850, score));

      return StepResult.complete(
        null,
        new Map<String, Object>{
          'creditScore' => score,
          'applicant' => applicant
        }
      );
    }
  }

  /**
   * @description Fallback step reached when the child credit check failed, was
   * cancelled, or timed out, applying the parent's failure-handling logic.
   */
  public class HandleCreditCheckFailureStep implements WorkflowStep {
    /**
     * @description Records the child-failure fallback decision and ends the workflow.
     * @param ctx The durable step context supplying the child failure status and error.
     * @return A COMPLETE result carrying the failed decision and error details.
     */
    public StepResult execute(StepContext ctx) {
      Map<String, Object> input = (Map<String, Object>) JSON.deserializeUntyped(
        ctx.inputJson
      );
      return StepResult.complete(
        null,
        new Map<String, Object>{
          'decision' => 'failed',
          'status' => input.get('status'),
          'errorMessage' => input.get('errorMessage'),
          'message' => 'Credit check child workflow failed. Applying fallback logic.'
        }
      );
    }
  }
}
