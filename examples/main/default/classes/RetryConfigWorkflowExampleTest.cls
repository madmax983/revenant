/**
 * @description Tests for RetryConfigWorkflowExample (issue #103). The operator
 * record sets the pacing. An operator cap in the middle of an incident stops
 * the retries at the next retry outcome. With no record, the engine default
 * applies.
 */
@IsTest
public class RetryConfigWorkflowExampleTest {
  private static final String WF = 'RetryConfigWorkflowExample.PartnerSyncWorkflow';
  private static final String PUSH = 'RetryConfigWorkflowExample.PushOrderStep';

  private static Workflow_Retry_Config__mdt partnerSync(Integer maxAttempts) {
    return new Workflow_Retry_Config__mdt(
      DeveloperName = 'PartnerSync',
      Workflow_Definition__c = WF,
      Initial_Interval_Seconds__c = 30,
      Backoff_Coefficient__c = 2,
      Maximum_Attempts__c = maxAttempts,
      Override_Author_Policy__c = false
    );
  }

  private static void useRecords(List<Workflow_Retry_Config__mdt> records) {
    WorkflowRetryConfigResolver.mockRecords = records;
  }

  private static Id startSync(String key) {
    return WorkflowEngine.start(
      WF,
      key,
      new Map<String, Object>{ 'orderId' => 'O-2001' }
    );
  }

  @IsTest
  static void shortOutageRecoversWithOperatorPacing() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      MockPartnerApi.reset();
      MockPartnerApi.outagesLeft = 3;
      useRecords(new List<Workflow_Retry_Config__mdt>{ partnerSync(6) });
      Test.startTest();
      WorkflowTestHarness.Result result = new WorkflowTestHarness(
          startSync('PartnerSync_OK')
        )
        .drive();
      Test.stopTest();

      Assert.areEqual('Completed', result.status, 'Three 503s do not fail it');
      Assert.areEqual(4, MockPartnerApi.calls, 'API gets 4 calls');
      Assert.areEqual(1, MockPartnerApi.storedOrders(), 'One order is stored');
    }
  }

  @IsTest
  static void operatorCapsAttemptsInTheMiddleOfAnIncident() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      MockPartnerApi.reset();
      MockPartnerApi.outagesLeft = 100;
      useRecords(new List<Workflow_Retry_Config__mdt>{ partnerSync(10) });
      Test.startTest();
      Id instanceId = startSync('PartnerSync_Incident');
      WorkflowTestHarness harness = new WorkflowTestHarness(instanceId);
      harness.disableAutoTimeSkip = true;
      harness.drive();
      WorkflowTestHarness.Result parked = harness.fireRetry(PUSH);
      Assert.isTrue(parked.isAwaitingRetry, 'Attempt 2 parks for a retry');

      // The operator edits the record in Setup: Maximum Attempts = 3.
      useRecords(new List<Workflow_Retry_Config__mdt>{ partnerSync(3) });
      WorkflowTestHarness.Result result = harness.fireRetry(PUSH);
      Test.stopTest();

      Assert.areEqual('Failed', result.status, 'Cap stops the retries');
      Assert.areEqual(3, MockPartnerApi.calls, 'API gets 3 calls, not 10');
      Workflow_Instance__c instance = [
        SELECT Failure_Category__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      Assert.areEqual(
        WorkflowEngine.CAT_RETRIES_EXHAUSTED,
        instance.Failure_Category__c,
        'Category is RETRIES_EXHAUSTED'
      );
    }
  }

  @IsTest
  static void noRecordUsesEngineDefault() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      MockPartnerApi.reset();
      MockPartnerApi.outagesLeft = 100;
      useRecords(new List<Workflow_Retry_Config__mdt>());
      Test.startTest();
      WorkflowTestHarness.Result result = new WorkflowTestHarness(
          startSync('PartnerSync_Default')
        )
        .drive();
      Test.stopTest();

      Assert.areEqual('Failed', result.status, 'Retries run out');
      Assert.areEqual(5, MockPartnerApi.calls, 'Engine default: 5 attempts');
    }
  }
}
