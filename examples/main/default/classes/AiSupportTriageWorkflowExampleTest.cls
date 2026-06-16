@isTest
public class AiSupportTriageWorkflowExampleTest {
  /**
   * Billing path: LLM classifies inquiry as 'billing', workflow auto-resolves
   * without human intervention. Exercises the most common happy path.
   */
  @isTest
  static void testBillingInquiryAutoResolves() {
    AiSupportTriageWorkflowExample.mockAiClassification = 'billing';

    Test.startTest();
    Id instanceId = WorkflowEngine.start(
      'AiSupportTriageWorkflowExample.TriageWorkflow',
      'Triage_Billing_1',
      new Map<String, Object>{
        'inquiryText' => 'I was charged twice for my subscription last month.'
      }
    );
    WorkflowTestHarness.Result result = new WorkflowTestHarness(instanceId).drive();
    Test.stopTest();

    System.assertEquals('Completed', result.status, 'Billing inquiries should auto-resolve');
    System.assert(result.isTerminal, 'Completed is a terminal state');

    Map<String, Object> output = (Map<String, Object>) JSON.deserializeUntyped(result.output);
    System.assertEquals('auto-resolved', output.get('resolution'));
    System.assertEquals('billing', output.get('category'));
    System.assertEquals('refund_issued', output.get('action'));
  }

  /**
   * Escalation path: LLM classifies as 'escalate', workflow suspends for
   * human review. The harness injects the approval signal to drive to completion.
   */
  @isTest
  static void testEscalationRequiresAndCompletesHumanReview() {
    AiSupportTriageWorkflowExample.mockAiClassification = 'escalate';

    Test.startTest();
    Id instanceId = WorkflowEngine.start(
      'AiSupportTriageWorkflowExample.TriageWorkflow',
      'Triage_Escalate_1',
      new Map<String, Object>{
        'inquiryText' => 'This is an urgent legal matter, please contact me immediately.'
      }
    );
    WorkflowTestHarness harness = new WorkflowTestHarness(instanceId);

    // Drive to the human review gate — should pause waiting for approval
    WorkflowTestHarness.Result suspended = harness.drive();

    System.assertEquals('Suspended', suspended.status, 'Should suspend at EscalateStep');
    System.assert(suspended.isSuspended, 'Result should report suspended state');
    System.assert(
      suspended.reachedStep('AiSupportTriageWorkflowExample.AiClassifyStep'),
      'AiClassifyStep should be in the audit trail'
    );

    // Reviewer approves via the dashboard — harness simulates the signal
    WorkflowTestHarness.Result completed = harness.injectSignal(
      'Triage_Escalate_1',
      'Approve:EscalationReview',
      '{"approved":true,"comments":"Escalation reviewed and resolved","approver":"Jane Smith"}'
    );
    Test.stopTest();

    System.assertEquals('Completed', completed.status, 'Should complete after approval');
    Map<String, Object> output = (Map<String, Object>) JSON.deserializeUntyped(completed.output);
    System.assertEquals('human-reviewed', output.get('resolution'));
    System.assertEquals(true, output.get('approved'));
    System.assertEquals('Jane Smith', output.get('reviewedBy'));
  }

  /**
   * Technical path: LLM classifies as 'technical', workflow creates a Case
   * then suspends at the human escalation gate. Verifies the Case was actually
   * inserted before the workflow suspended.
   */
  @isTest
  static void testTechnicalInquiryCreatesCaseAndEscalates() {
    AiSupportTriageWorkflowExample.mockAiClassification = 'technical';

    Test.startTest();
    Id instanceId = WorkflowEngine.start(
      'AiSupportTriageWorkflowExample.TriageWorkflow',
      'Triage_Technical_1',
      new Map<String, Object>{
        'inquiryText' => 'My API integration keeps returning 500 errors since this morning.'
      }
    );
    WorkflowTestHarness.Result suspended = new WorkflowTestHarness(instanceId).drive();
    Test.stopTest();

    System.assertEquals(
      'Suspended',
      suspended.status,
      'Technical path should pause at EscalateStep after case creation'
    );
    System.assert(
      suspended.reachedStep('AiSupportTriageWorkflowExample.CreateCaseStep'),
      'CreateCaseStep should be in the audit trail'
    );

    // Verify the Case record was actually created by the workflow step
    List<Workflow_Step_Execution__c> createStepExecs = [
      SELECT Output__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :instanceId
        AND Step_Name__c = 'AiSupportTriageWorkflowExample.CreateCaseStep'
        AND Status__c = 'Completed'
    ];
    System.assertEquals(1, createStepExecs.size(), 'CreateCaseStep should have one completed execution');

    Map<String, Object> stepOutput = (Map<String, Object>) JSON.deserializeUntyped(
      createStepExecs[0].Output__c
    );
    Id caseId = (Id) stepOutput.get('caseId');
    System.assertNotEquals(null, caseId, 'Case ID should be in step output');

    List<Case> cases = [SELECT Id, Subject, Status FROM Case WHERE Id = :caseId];
    System.assertEquals(1, cases.size(), 'Case record should exist in org');
    System.assertEquals('AI Triage — Technical Issue', cases[0].Subject);
  }
}
