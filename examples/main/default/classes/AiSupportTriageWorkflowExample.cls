/**
 * AI-Powered Support Triage Workflow
 *
 * Demonstrates why durable workflows are the right foundation for agentic AI:
 *
 *  - LLM calls that fail are automatically retried with back-off — no extra code.
 *  - Human-in-the-loop escalation is a first-class citizen: the workflow suspends
 *    until a reviewer acts via the dashboard, then resumes exactly where it left off.
 *  - Every AI decision is captured in the immutable step-execution audit trail.
 *
 * Uses aiplatform.ModelsAPI — the native Salesforce Apex LLM interface — so no
 * HTTP callout, no Named Credential, and no external API key is needed. Requires
 * the Einstein Platform settings enabled in the org (already set in project-scratch-def.json).
 */
public with sharing class AiSupportTriageWorkflowExample {
  /**
   * Inject a classification result in @isTest methods to skip the live LLM call.
   * Set before WorkflowEngine.start() or WorkflowTestHarness.drive().
   */
  @TestVisible
  private static String mockAiClassification;

  @TestVisible
  private static String aiModel = 'sfdc_ai__DefaultGPT35Turbo';

  // ── Workflow definition ────────────────────────────────────────────────────

  public class TriageWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{
        'AiSupportTriageWorkflowExample.AiClassifyStep',
        'AiSupportTriageWorkflowExample.AutoResolveBillingStep',
        'AiSupportTriageWorkflowExample.CreateCaseStep',
        'AiSupportTriageWorkflowExample.EscalateStep'
      };
    }

    public String getInitialStep() {
      return 'AiSupportTriageWorkflowExample.AiClassifyStep';
    }

    public String getNextStep(String currentStep, StepResult result) {
      if (currentStep == 'AiSupportTriageWorkflowExample.AiClassifyStep') {
        Map<String, Object> out = (Map<String, Object>) JSON.deserializeUntyped(
          result.outputJson
        );
        String classification = (String) out.get('classification');
        if (classification == 'billing') {
          return 'AiSupportTriageWorkflowExample.AutoResolveBillingStep';
        }
        if (classification == 'technical') {
          return 'AiSupportTriageWorkflowExample.CreateCaseStep';
        }
        // 'escalate' or any unrecognised category
        return 'AiSupportTriageWorkflowExample.EscalateStep';
      }
      if (currentStep == 'AiSupportTriageWorkflowExample.CreateCaseStep') {
        // Always escalate after case creation so a human confirms the diagnosis
        return 'AiSupportTriageWorkflowExample.EscalateStep';
      }
      return null; // AutoResolveBilling and EscalateStep are both terminal
    }
  }

  // ── Step definitions ───────────────────────────────────────────────────────

  /**
   * Step 1: Ask the LLM to classify the support inquiry.
   *
   * Any aiplatform.ModelsAPI.createGenerations_ResponseException thrown here
   * propagates to the engine, which automatically retries the step with the
   * default RetryPolicy (5 s, ×2 back-off, up to 5 attempts). If all retries
   * are exhausted the workflow ends as Failed and can be re-driven from the
   * dashboard once the AI service recovers — all without extra error-handling code.
   */
  public class AiClassifyStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      Map<String, Object> input = parseJson(ctx.inputJson);
      String inquiryText = (String) input.get('inquiryText');
      if (String.isBlank(inquiryText)) {
        throw new WorkflowEngine.WorkflowException('inquiryText is required');
      }

      String classification = classifyWithLlm(inquiryText);

      return StepResult.complete(
        null,
        new Map<String, Object>{
          'classification' => classification,
          'inquiryText' => inquiryText
        }
      );
    }
  }

  /**
   * Step 2a: Billing issue — automatically issue a refund and close.
   */
  public class AutoResolveBillingStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      Map<String, Object> classify = parseJson(ctx.inputJson);
      return StepResult.complete(
        null,
        new Map<String, Object>{
          'resolution' => 'auto-resolved',
          'category' => 'billing',
          'action' => 'refund_issued',
          'inquiryText' => classify.get('inquiryText')
        }
      );
    }
  }

  /**
   * Step 2b: Technical issue — create a support case, then hand off to the
   * human escalation gate (EscalateStep) for confirmation.
   */
  public inherited sharing class CreateCaseStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      Map<String, Object> classify = parseJson(ctx.inputJson);

      Case c = new Case(
        Subject = 'AI Triage — Technical Issue',
        Status = 'New',
        Origin = 'Web',
        Priority = 'Medium',
        Description = (String) classify.get('inquiryText')
      );
      insert as user c;

      return StepResult.complete(
        null,
        new Map<String, Object>{
          'resolution' => 'case-created',
          'category' => 'technical',
          'caseId' => (String) c.Id
        }
      );
    }
  }

  /**
   * Step 3 (also Step 2c): Human escalation gate.
   *
   * Returns waitForApproval on first entry — the dashboard renders an approve /
   * reject button for the 'EscalationReview' key. When the reviewer acts, the
   * engine re-runs this step; on re-entry the signal is consumed and the step
   * completes with the reviewer's decision.
   */
  public inherited sharing class EscalateStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      List<Workflow_Signal__c> signals = [
        SELECT Id, Payload__c
        FROM Workflow_Signal__c
        WHERE
          Workflow_Instance__c = :ctx.workflowInstanceId
          AND Signal_Name__c = 'Approve:EscalationReview'
          AND Status__c = 'Received'
        WITH SYSTEM_MODE
        LIMIT 1
      ];

      if (signals.isEmpty()) {
        return StepResult.waitForApproval('EscalationReview', null);
      }

      Workflow_Signal__c sig = signals[0];
      sig.Status__c = 'Consumed';
      update as user sig;

      Map<String, Object> decision = (Map<String, Object>) JSON.deserializeUntyped(
        sig.Payload__c
      );
      return StepResult.complete(
        null,
        new Map<String, Object>{
          'resolution' => 'human-reviewed',
          'approved' => decision.get('approved'),
          'comments' => decision.get('comments'),
          'reviewedBy' => decision.get('approver')
        }
      );
    }
  }

  // ── LLM helper ────────────────────────────────────────────────────────────

  private static String classifyWithLlm(String inquiryText) {
    if (String.isNotBlank(mockAiClassification)) {
      return mockAiClassification;
    }

    String prompt =
      'You are a customer support classifier.\n' +
      'Classify the inquiry below into exactly one of: billing, technical, escalate.\n' +
      'Respond with ONLY that single word, nothing else.\n\n' +
      'Inquiry: ' +
      inquiryText;

    aiplatform.ModelsAPI.createGenerations_Request request = new aiplatform.ModelsAPI.createGenerations_Request();
    request.modelName = aiModel;

    aiplatform.ModelsAPI_GenerationRequest body = new aiplatform.ModelsAPI_GenerationRequest();
    body.prompt = prompt;
    request.body = body;

    aiplatform.ModelsAPI modelsAPI = new aiplatform.ModelsAPI();
    aiplatform.ModelsAPI.createGenerations_Response response = modelsAPI.createGenerations(
      request
    );

    String content = response.Code200.generation.generatedText.trim()
      .toLowerCase();
    if (content.startsWith('billing')) {
      return 'billing';
    }
    if (content.startsWith('technical')) {
      return 'technical';
    }
    return 'escalate';
  }

  private static Map<String, Object> parseJson(String jsonStr) {
    if (String.isBlank(jsonStr)) {
      return new Map<String, Object>();
    }
    return (Map<String, Object>) JSON.deserializeUntyped(jsonStr);
  }
}
