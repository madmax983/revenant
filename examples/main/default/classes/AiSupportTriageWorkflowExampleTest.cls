@IsTest
public class AiSupportTriageWorkflowExampleTest {
  /**
   * Billing path: LLM classifies inquiry as 'billing', workflow auto-resolves
   * without human intervention. Exercises the most common happy path.
   */
  @IsTest
  static void testBillingInquiryAutoResolves() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      AiSupportTriageWorkflowExample.mockAiClassification = 'billing';

      Test.startTest();
      Id instanceId = WorkflowEngine.start(
        'AiSupportTriageWorkflowExample.TriageWorkflow',
        'Triage_Billing_1',
        new Map<String, Object>{
          'inquiryText' => 'I was charged twice for my subscription last month.'
        },
        new Map<String, String>{ 'region' => 'US', 'tier' => 'premium' }
      );
      WorkflowTestHarness.Result result = new WorkflowTestHarness(instanceId)
        .drive();
      Test.stopTest();

      List<Workflow_Search_Attribute__c> searchAttrs = [
        SELECT Key__c, Value__c, Key_Value__c
        FROM Workflow_Search_Attribute__c
        WHERE Workflow_Instance__c = :instanceId
        ORDER BY Key__c ASC
      ];
      System.assertEquals(
        2,
        searchAttrs.size(),
        'Should persist two attributes'
      );
      System.assertEquals('region', searchAttrs[0].Key__c);
      System.assertEquals('US', searchAttrs[0].Value__c);
      System.assertEquals('region=US', searchAttrs[0].Key_Value__c);
      System.assertEquals('tier', searchAttrs[1].Key__c);
      System.assertEquals('premium', searchAttrs[1].Value__c);
      System.assertEquals('tier=premium', searchAttrs[1].Key_Value__c);

      System.assertEquals(
        'Completed',
        result.status,
        'Billing inquiries should auto-resolve'
      );
      System.assert(result.isTerminal, 'Completed is a terminal state');

      Map<String, Object> output = (Map<String, Object>) JSON.deserializeUntyped(
        result.output
      );
      System.assertEquals('auto-resolved', output.get('resolution'));
      System.assertEquals('billing', output.get('category'));
      System.assertEquals('refund_issued', output.get('action'));
    }
  }

  /**
   * Escalation path: LLM classifies as 'escalate', workflow suspends for
   * human review. The harness injects the approval signal to drive to completion.
   */
  @IsTest
  static void testEscalationRequiresAndCompletesHumanReview() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
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

      System.assertEquals(
        'Suspended',
        suspended.status,
        'Should suspend at EscalateStep'
      );
      System.assert(
        suspended.isSuspended,
        'Result should report suspended state'
      );
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

      System.assertEquals(
        'Completed',
        completed.status,
        'Should complete after approval'
      );
      Map<String, Object> output = (Map<String, Object>) JSON.deserializeUntyped(
        completed.output
      );
      System.assertEquals('human-reviewed', output.get('resolution'));
      System.assertEquals(true, output.get('approved'));
      System.assertEquals('Jane Smith', output.get('reviewedBy'));
    }
  }

  /**
   * Technical path: LLM classifies as 'technical', workflow creates a Case
   * then suspends at the human escalation gate. Verifies the Case was actually
   * inserted before the workflow suspended.
   */
  @IsTest
  static void testTechnicalInquiryCreatesCaseAndEscalates() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      AiSupportTriageWorkflowExample.mockAiClassification = 'technical';

      Test.startTest();
      Id instanceId = WorkflowEngine.start(
        'AiSupportTriageWorkflowExample.TriageWorkflow',
        'Triage_Technical_1',
        new Map<String, Object>{
          'inquiryText' => 'My API integration keeps returning 500 errors since this morning.'
        }
      );
      WorkflowTestHarness.Result suspended = new WorkflowTestHarness(instanceId)
        .drive();
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
      System.assertEquals(
        1,
        createStepExecs.size(),
        'CreateCaseStep should have one completed execution'
      );

      Map<String, Object> stepOutput = (Map<String, Object>) JSON.deserializeUntyped(
        createStepExecs[0].Output__c
      );
      Id caseId = (Id) stepOutput.get('caseId');
      System.assertNotEquals(null, caseId, 'Case ID should be in step output');

      List<Case> cases = [
        SELECT Id, Subject, Status
        FROM Case
        WHERE Id = :caseId
      ];
      System.assertEquals(1, cases.size(), 'Case record should exist in org');
      System.assertEquals('AI Triage — Technical Issue', cases[0].Subject);
    }
  }
}
