/**
 * @description Example onboarding workflow showcasing Revenant features end to end:
 * a parallel split/join, a signal-gated VIP approval, and a launched welcome-email
 * child workflow, ending in a completion step.
 */
public inherited sharing class OnboardingWorkflowExample implements WorkflowDefinition {
  /**
   * @description Declares every step class in the onboarding DAG, including the
   * parallel branches and join.
   * @return The list of fully-qualified onboarding step names.
   */
  public List<String> getSteps() {
    return new List<String>{
      'OnboardingWorkflowExample.VerifyOrderStep',
      'OnboardingWorkflowExample.SplitOnboardingStep',
      'OnboardingWorkflowExample.ProvisionSandboxStep',
      'OnboardingWorkflowExample.CreateBillingAccountStep',
      'OnboardingWorkflowExample.JoinOnboardingStep',
      'OnboardingWorkflowExample.VIPApprovalStep',
      'OnboardingWorkflowExample.WelcomeWorkflowLauncherStep',
      'OnboardingWorkflowExample.CompleteOnboardingStep'
    };
  }

  /**
   * @description Returns the first onboarding step, order verification.
   * @return The name of the initial step.
   */
  public String getInitialStep() {
    return 'OnboardingWorkflowExample.VerifyOrderStep';
  }

  /**
   * @description Routes the linear portion of the onboarding DAG from one step to
   * the next (the split/join fan-out is handled by StepResult.split itself).
   * @param currentStepName The name of the step that just completed.
   * @param stepResult The result of the completed step.
   * @return The next step name, or null when onboarding is complete.
   */
  public String getNextStep(String currentStepName, StepResult stepResult) {
    if (currentStepName == 'OnboardingWorkflowExample.VerifyOrderStep') {
      return 'OnboardingWorkflowExample.SplitOnboardingStep';
    }
    if (currentStepName == 'OnboardingWorkflowExample.SplitOnboardingStep') {
      return 'OnboardingWorkflowExample.JoinOnboardingStep';
    }
    if (currentStepName == 'OnboardingWorkflowExample.JoinOnboardingStep') {
      return 'OnboardingWorkflowExample.VIPApprovalStep';
    }
    if (currentStepName == 'OnboardingWorkflowExample.VIPApprovalStep') {
      return 'OnboardingWorkflowExample.WelcomeWorkflowLauncherStep';
    }
    if (
      currentStepName == 'OnboardingWorkflowExample.WelcomeWorkflowLauncherStep'
    ) {
      return 'OnboardingWorkflowExample.CompleteOnboardingStep';
    }
    return null;
  }

  // --- STEP DEFINITIONS ---

  /**
   * @description Validates the incoming order payload, requiring a non-blank input
   * with a positive amount before onboarding proceeds.
   */
  public class VerifyOrderStep implements WorkflowStep {
    /**
     * @description Parses and validates the order input, failing the step if the
     * payload is missing or the amount is not positive.
     * @param ctx The durable step context exposing the instance input JSON.
     * @return A complete result carrying the parsed order map.
     */
    public StepResult execute(StepContext ctx) {
      ctx.reportProgress(10.0, 'Validating order details');
      if (String.isBlank(ctx.inputJson)) {
        throw new WorkflowEngine.WorkflowException('Input payload is required');
      }
      Map<String, Object> inputMap = (Map<String, Object>) JSON.deserializeUntyped(
        ctx.inputJson
      );
      Decimal amount = (Decimal) inputMap.get('amount');
      if (amount == null || amount <= 0) {
        throw new WorkflowEngine.WorkflowException(
          'Order amount must be positive'
        );
      }
      return StepResult.complete(null, inputMap);
    }
  }

  /**
   * @description Fans onboarding out into parallel sandbox-provisioning and
   * billing-account branches that later rejoin at JoinOnboardingStep.
   */
  public class SplitOnboardingStep implements WorkflowStep {
    /**
     * @description Emits a split result forking the two parallel branches, passing
     * the verified order forward to each.
     * @param ctx The durable step context exposing the previous step's output.
     * @return A split result naming the parallel branch steps.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.split(
        new List<String>{
          'OnboardingWorkflowExample.ProvisionSandboxStep',
          'OnboardingWorkflowExample.CreateBillingAccountStep'
        },
        ctx.previousStepOutput
      );
    }
  }

  /**
   * @description Parallel branch that provisions the client sandbox org for the order.
   */
  public class ProvisionSandboxStep implements WorkflowStep {
    /**
     * @description Simulates provisioning a sandbox org and returns its generated Id.
     * @param ctx The durable step context exposing the order input JSON.
     * @return A complete result carrying the provisioned sandbox org Id and status.
     */
    public StepResult execute(StepContext ctx) {
      ctx.reportProgress(30.0, 'Creating client sandbox');
      Map<String, Object> order = (Map<String, Object>) JSON.deserializeUntyped(
        ctx.inputJson
      );

      String sandboxOrgId =
        '00D' + String.valueOf(Math.abs(Crypto.getRandomInteger())).left(15);
      Map<String, Object> result = new Map<String, Object>{
        'sandboxOrgId' => sandboxOrgId,
        'status' => 'Provisioned'
      };
      return StepResult.complete(null, result);
    }
  }

  /**
   * @description Parallel branch that creates the customer billing account for the order.
   */
  public class CreateBillingAccountStep implements WorkflowStep {
    /**
     * @description Simulates creating a billing account and returns its generated Id.
     * @param ctx The durable step context exposing the order input JSON.
     * @return A complete result carrying the billing account Id and status.
     */
    public StepResult execute(StepContext ctx) {
      ctx.reportProgress(50.0, 'Configuring billing accounts');
      Map<String, Object> order = (Map<String, Object>) JSON.deserializeUntyped(
        ctx.inputJson
      );

      String billingAccountId =
        'cust_billing_' +
        String.valueOf(Math.abs(Crypto.getRandomInteger())).left(8);
      Map<String, Object> result = new Map<String, Object>{
        'billingAccountId' => billingAccountId,
        'status' => 'Created'
      };
      return StepResult.complete(null, result);
    }
  }

  /**
   * @description Join step that resumes once both parallel branches finish, receiving
   * their merged outputs.
   */
  public class JoinOnboardingStep implements WorkflowStep {
    /**
     * @description Passes the merged parallel-branch outputs forward as this step's result.
     * @param ctx The durable step context exposing the joined branch outputs as input JSON.
     * @return A complete result carrying the combined parallel outputs.
     */
    public StepResult execute(StepContext ctx) {
      Map<String, Object> parallelOutputs = (Map<String, Object>) JSON.deserializeUntyped(
        ctx.inputJson
      );
      return StepResult.complete(null, parallelOutputs);
    }
  }

  /**
   * @description For high-value orders, pauses for an executive approval signal and
   * consumes the decision, failing the step on rejection.
   */
  public class VIPApprovalStep implements WorkflowStep {
    /**
     * @description Waits for the VIP approval signal when the order amount is large,
     * consuming the decision on resume and throwing if it was rejected; small orders
     * pass straight through.
     * @param ctx The durable step context exposing the instance input and instance Id.
     * @return A wait-for-approval result, or a complete result once approved or below threshold.
     */
    public StepResult execute(StepContext ctx) {
      ctx.reportProgress(70.0, 'Verifying manager approvals');
      Map<String, Object> instanceInput = (Map<String, Object>) JSON.deserializeUntyped(
        ctx.workflowInputJson
      );
      Decimal amount = (Decimal) instanceInput.get('amount');

      if (amount >= 10000.0) {
        List<Workflow_Signal__c> signals = [
          SELECT Id, Payload__c
          FROM Workflow_Signal__c
          WHERE
            Workflow_Instance__c = :ctx.workflowInstanceId
            AND Signal_Name__c = 'Approve:VIPOrderApproval'
            AND Status__c = 'Received'
          WITH USER_MODE
          LIMIT 1
        ];

        if (signals.isEmpty()) {
          return StepResult.waitForApproval(
            'VIPOrderApproval',
            'Executive Manager'
          );
        }

        // Consume the decision before potentially throwing: a rejection must not
        // remain Received to be re-loaded (and re-fail) on a retry. Engine-managed
        // consumption only fires on a successful COMPLETE, so a step that throws
        // on rejection consumes the signal itself here. See
        // ApprovalSignalWorkflowExample for the engine-managed (non-throwing)
        // approve/reject pattern using ctx.getSignal(...).
        Workflow_Signal__c sig = signals[0];
        sig.Status__c = 'Consumed';
        update as user sig;

        Map<String, Object> payloadMap = (Map<String, Object>) JSON.deserializeUntyped(
          sig.Payload__c
        );
        Boolean approved = (Boolean) payloadMap.get('approved');
        if (!approved) {
          throw new WorkflowEngine.WorkflowException(
            'VIP order was rejected by executive manager.'
          );
        }
      }

      return StepResult.complete(null, 'VIP Approval Checked');
    }
  }

  /**
   * @description Launches the welcome-email child workflow and resumes when the child
   * signals completion, demonstrating parent/child orchestration.
   */
  public class WelcomeWorkflowLauncherStep implements WorkflowStep {
    /**
     * @description Starts the welcome-email child workflow on first execution, then
     * completes once the child's ChildCompleted signal has been received and consumed.
     * @param ctx The durable step context exposing the instance input and instance Id.
     * @return A start-child result, or a complete result once the child has finished.
     */
    public StepResult execute(StepContext ctx) {
      Map<String, Object> instanceInput = (Map<String, Object>) JSON.deserializeUntyped(
        ctx.workflowInputJson
      );
      String email = (String) instanceInput.get('email');

      String childKey = 'WelcomeEmail_' + ctx.workflowInstanceId;

      List<Workflow_Signal__c> signals = [
        SELECT Id, Payload__c
        FROM Workflow_Signal__c
        WHERE
          Workflow_Instance__c = :ctx.workflowInstanceId
          AND Signal_Name__c = :('ChildCompleted:' + childKey)
          AND Status__c = 'Received'
        WITH USER_MODE
        LIMIT 1
      ];

      if (!signals.isEmpty()) {
        signals[0].Status__c = 'Consumed';
        update signals[0];
        return StepResult.complete(null, 'Welcome Email Sent Successfully');
      }

      return StepResult.startChild(
        'OnboardingWorkflowExample.WelcomeEmailWorkflow',
        childKey,
        email
      );
    }
  }

  /**
   * @description Terminal step that marks the onboarding workflow complete.
   */
  public class CompleteOnboardingStep implements WorkflowStep {
    /**
     * @description Reports full progress and returns the final onboarding summary.
     * @param ctx The durable step context.
     * @return A complete result carrying the onboarding completion status and date.
     */
    public StepResult execute(StepContext ctx) {
      ctx.reportProgress(100.0, 'Finished onboarding checklist');
      Map<String, Object> onboardingResults = new Map<String, Object>{
        'status' => 'Completed',
        'completedDate' => Datetime.now()
      };
      return StepResult.complete(null, onboardingResults);
    }
  }

  // --- WELCOME EMAIL CHILD WORKFLOW ---

  /**
   * @description Child workflow launched by WelcomeWorkflowLauncherStep: it delays
   * briefly, then sends the welcome email.
   */
  public class WelcomeEmailWorkflow implements WorkflowDefinition {
    /**
     * @description Declares the child workflow's two steps.
     * @return The list of step names in the welcome-email child workflow.
     */
    public List<String> getSteps() {
      return new List<String>{
        'OnboardingWorkflowExample.DelayEmailStep',
        'OnboardingWorkflowExample.SendEmailStep'
      };
    }
    /**
     * @description Returns the child workflow's first step, the delay.
     * @return The name of the initial step.
     */
    public String getInitialStep() {
      return 'OnboardingWorkflowExample.DelayEmailStep';
    }
    /**
     * @description Routes the child workflow from the delay step to the send step.
     * @param currentStepName The name of the step that just completed.
     * @param stepResult The result of the completed step.
     * @return The next step name, or null when the child workflow is complete.
     */
    public String getNextStep(String currentStepName, StepResult stepResult) {
      if (currentStepName == 'OnboardingWorkflowExample.DelayEmailStep') {
        return 'OnboardingWorkflowExample.SendEmailStep';
      }
      return null;
    }
  }

  /**
   * @description Child step that durably sleeps once before proceeding, illustrating
   * a timer-based pause and resume.
   */
  public class DelayEmailStep implements WorkflowStep {
    /**
     * @description Sleeps on first execution and completes on resume, when durable
     * step state indicates the sleep has already elapsed.
     * @param ctx The durable step context exposing prior step state.
     * @return A sleep result on first run, or a complete result on resume.
     */
    public StepResult execute(StepContext ctx) {
      if (ctx.stepStateJson != null) {
        return StepResult.complete(null, ctx.inputJson);
      }
      return StepResult.sleep(5, 'slept');
    }
  }

  /**
   * @description Terminal child step that sends the welcome email to the customer.
   */
  public class SendEmailStep implements WorkflowStep {
    /**
     * @description Sends the welcome email to the address carried in the input.
     * @param ctx The durable step context exposing the recipient email as input JSON.
     * @return A complete result confirming the email was sent.
     */
    public StepResult execute(StepContext ctx) {
      String email = (String) JSON.deserialize(ctx.inputJson, String.class);
      System.debug('Welcome email sent to: ' + email);
      return StepResult.complete(null, 'Sent welcome email to ' + email);
    }
  }
}
