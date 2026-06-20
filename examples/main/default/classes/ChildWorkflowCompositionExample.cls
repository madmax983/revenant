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
 * 4. WorkflowEngine.cancel(parentId, false) cancels the parent and all of its
 *    active descendants (root-first traversal over Parent_Instance__c), so
 *    explicitly cancelling a parent reaps its in-flight children.  Note this is
 *    cancellation only: a parent that FAILS is not cascaded — failWorkflowInstance
 *    does not traverse Parent_Instance__c — and a child that fails or times out
 *    never publishes ChildCompleted, so its parent stays Suspended.  A production
 *    composite would add its own child-failure/timeout signal to cover that path.
 */
public inherited sharing class ChildWorkflowCompositionExample
  implements WorkflowDefinition {

  /** Minimum credit score required to approve the loan. */
  public static final Integer APPROVE_THRESHOLD = 680;

  // ---------------------------------------------------------------------------
  // PARENT WORKFLOW DEFINITION
  // ---------------------------------------------------------------------------

  public List<String> getSteps() {
    return new List<String>{
      'ChildWorkflowCompositionExample.RequestCreditCheckStep',
      'ChildWorkflowCompositionExample.ApproveLoanStep',
      'ChildWorkflowCompositionExample.DeclineLoanStep'
    };
  }

  public String getInitialStep() {
    return 'ChildWorkflowCompositionExample.RequestCreditCheckStep';
  }

  /**
   * RequestCreditCheckStep decides the branch by embedding the next step name in
   * its COMPLETE result (the ApprovalSignalWorkflowExample branching pattern).
   * ApproveLoanStep and DeclineLoanStep are terminal — null ends the workflow.
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
   *              while the instance is Suspended; calling startChild() a second time
   *              with the same key would hit the engine's duplicate-active-key guard
   *              and FAIL the parent, so we must idempotently wait instead.
   *
   * First run — no signal and no child yet → startChild.  The engine suspends the
   *              parent and starts the child's own Queueable chain.  This same step
   *              is re-run (not a new step) when the child completes.
   */
  public class RequestCreditCheckStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      String childKey = 'CreditCheck_' + ctx.workflowInstanceId;
      StepContext.Signal done = ctx.getSignal('ChildCompleted:' + childKey);

      if (done.isPresent()) {
        // Resume: the child completed.  Its serialised output is the signal payload.
        // For large child outputs the payload may be a blob reference; resolve it.
        String childOutputJson = WorkflowEngine.resolvePayload(done.payload);
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
      }

      // No completion signal yet.  If we already launched the child on a prior run
      // of this step, re-suspend idempotently rather than starting a duplicate.
      List<Workflow_Instance__c> alreadyLaunched = [
        SELECT Id
        FROM Workflow_Instance__c
        WHERE
          Parent_Instance__c = :ctx.workflowInstanceId
          AND Correlation_Key__c = :childKey
        LIMIT 1
      ];
      if (!alreadyLaunched.isEmpty()) {
        return StepResult.suspend();
      }

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

  public class ApproveLoanStep implements WorkflowStep {
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

  public class DeclineLoanStep implements WorkflowStep {
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

  public class CreditCheckWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{
        'ChildWorkflowCompositionExample.ComputeCreditScoreStep'
      };
    }

    public String getInitialStep() {
      return 'ChildWorkflowCompositionExample.ComputeCreditScoreStep';
    }

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

      Integer incomeBonus = (Integer) Math.min(income / 1000, 250);
      Integer amountPenalty = (Integer) Math.min(amount / 5000, 150);
      Integer score = 600 + incomeBonus - amountPenalty;
      score = Math.max(300, Math.min(850, score));

      return StepResult.complete(
        null,
        new Map<String, Object>{ 'creditScore' => score, 'applicant' => applicant }
      );
    }
  }
}
