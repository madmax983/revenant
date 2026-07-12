@IsTest
public class OnboardingWorkflowExampleTest {
  /**
   * The customer-onboarding happy path, driven by WorkflowTestHarness.
   *
   * This test previously drove the workflow with 13 hand-written, engine-internal
   * orchestration calls — constructing WorkflowOrchestrator per step and per parallel
   * branch, calling Test.getEventBus().deliver() after every signal, and mutating the
   * child instance record to fake the sleep resumer. It now collapses to two harness
   * calls (drive + injectSignal) with zero lines touching WorkflowOrchestrator,
   * Test.getEventBus(), or direct instance-record mutation, while preserving the
   * behavioural assertions (parallel fan-out/rejoin, executive-approval suspend,
   * child welcome workflow with a sleep, and final Completed output).
   */
  @IsTest
  static void testCustomerOnboardingWorkflow() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Map<String, Object> inputMap = new Map<String, Object>{
        'amount' => 15000.0,
        'customerName' => 'Acme Corp',
        'email' => 'admin@acme.com'
      };

      Test.startTest();
      // 1. Start the workflow and hand it to the harness.
      Id instanceId = WorkflowEngine.start(
        'OnboardingWorkflowExample',
        'Onboarding_Key_123',
        inputMap
      );
      WorkflowTestHarness harness = new WorkflowTestHarness(instanceId);

      // 2. Drive: VerifyOrder -> parallel Provision/Billing fan-out -> Join ->
      //    VIPApproval, which suspends for executive approval (amount >= 10000).
      WorkflowTestHarness.Result suspended = harness.drive();
      Test.stopTest();

      System.assertEquals(
        'Suspended',
        suspended.status,
        'Workflow should suspend for VIP approval'
      );
      System.assert(
        suspended.reachedStep('OnboardingWorkflowExample.ProvisionSandboxStep'),
        'Parallel ProvisionSandboxStep should have run'
      );
      System.assert(
        suspended.reachedStep(
          'OnboardingWorkflowExample.CreateBillingAccountStep'
        ),
        'Parallel CreateBillingAccountStep should have run'
      );
      System.assert(
        suspended.reachedStep('OnboardingWorkflowExample.JoinOnboardingStep'),
        'Rejoin JoinOnboardingStep should have run'
      );

      // 3. Submit executive approval. The harness delivers the signal and resumes the
      //    workflow — including the child WelcomeEmail workflow and its sleep — to the end.
      WorkflowTestHarness.Result completed = harness.injectSignal(
        'Onboarding_Key_123',
        'Approve:VIPOrderApproval',
        '{"approved":true,"comments":"Approved VIP Customer"}'
      );

      System.assertEquals(
        'Completed',
        completed.status,
        'Workflow should complete after approval'
      );
      System.assert(
        completed.output.contains('"status":"Completed"'),
        'Final output should carry the completed status payload'
      );
      System.assert(
        completed.reachedStep(
          'OnboardingWorkflowExample.WelcomeWorkflowLauncherStep'
        ),
        'WelcomeWorkflowLauncherStep should have run'
      );
      System.assert(
        completed.reachedStep(
          'OnboardingWorkflowExample.CompleteOnboardingStep'
        ),
        'CompleteOnboardingStep should have run'
      );

      // The child WelcomeEmail workflow ran to completion (its DelayEmailStep sleep was
      // resumed by the harness through the engine, not by mutating the instance record).
      Workflow_Instance__c childInst = [
        SELECT Status__c
        FROM Workflow_Instance__c
        WHERE Parent_Instance__c = :instanceId
        LIMIT 1
      ];
      System.assertEquals(
        'Completed',
        childInst.Status__c,
        'Child welcome workflow should complete'
      );
    }
  }
}
