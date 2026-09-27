/**
 * @description Tests for AutoRetryWorkflowExample (issue #101). A short
 * gateway outage recovers with no rollback. A lost response does not charge
 * the card two times. A long outage rolls back the saga. An opted-out step
 * fails fast.
 */
@IsTest
public class AutoRetryWorkflowExampleTest {
  private static final String WF = 'AutoRetryWorkflowExample.OrderSaga';
  private static final String RESERVE = 'AutoRetryWorkflowExample.ReserveInventoryStep';
  private static final String CHARGE = 'AutoRetryWorkflowExample.ChargePaymentStep';
  private static final String RECEIPT = 'AutoRetryWorkflowExample.SendReceiptStep';

  private static WorkflowTestHarness.Result runOrder(String key) {
    return runOrder(key, 4200);
  }

  private static WorkflowTestHarness.Result runOrder(
    String key,
    Object amountCents
  ) {
    Id instanceId = WorkflowEngine.start(
      WF,
      key,
      new Map<String, Object>{
        'orderId' => 'O-1001',
        'amountCents' => amountCents
      }
    );
    return new WorkflowTestHarness(instanceId).drive();
  }

  private static Workflow_Step_Execution__c chargeRow() {
    return [
      SELECT Status__c, Retry_Count__c, Error_Details__c
      FROM Workflow_Step_Execution__c
      WHERE Step_Name__c = :CHARGE
      ORDER BY CreatedDate DESC, Id DESC
      LIMIT 1
    ];
  }

  @IsTest
  static void shortGatewayOutageIsRetriedAndOrderCompletes() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      MockFlakyOrderServices.reset();
      MockFlakyOrderServices.gatewayOutagesLeft = 2;
      Test.startTest();
      WorkflowTestHarness.Result result = runOrder('AutoRetry_OK');
      Test.stopTest();

      Assert.areEqual('Completed', result.status, 'Two 503s do not fail it');
      Assert.isTrue(
        result.compensatedSteps.isEmpty(),
        'A recovered outage does not roll back the saga'
      );
      Assert.areEqual(
        3,
        MockFlakyOrderServices.chargeAttempts,
        'Gateway is called 3 times: 503, 503, 200'
      );
      Assert.areEqual(
        1,
        MockFlakyOrderServices.effectiveCharges,
        'The card is charged once'
      );
      Assert.areEqual(
        2,
        chargeRow().Retry_Count__c.intValue(),
        'Two auto-retries are counted'
      );
      Assert.areEqual(1, MockFlakyOrderServices.receiptsSent, 'One receipt');
      Assert.areEqual(
        2,
        [SELECT COUNT() FROM Workflow_Log__c WHERE Log_Type__c = 'AutoRetry'],
        'Each retried attempt is logged'
      );
    }
  }

  @IsTest
  static void lostResponseIsRetriedWithoutDoubleCharge() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      MockFlakyOrderServices.reset();
      MockFlakyOrderServices.lostResponsesLeft = 1;
      Test.startTest();
      WorkflowTestHarness.Result result = runOrder('AutoRetry_Lost');
      Test.stopTest();

      Assert.areEqual('Completed', result.status, 'A 504 does not fail it');
      Assert.areEqual(
        2,
        MockFlakyOrderServices.chargeAttempts,
        'Gateway is called 2 times: 504, then 200'
      );
      Assert.areEqual(
        1,
        MockFlakyOrderServices.effectiveCharges,
        'The idempotency key stops a second charge'
      );
    }
  }

  @IsTest
  static void wholeDecimalAmountIsCharged() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      MockFlakyOrderServices.reset();
      Test.startTest();
      WorkflowTestHarness.Result result = runOrder(
        'AutoRetry_Decimal',
        Decimal.valueOf('4200.00')
      );
      Test.stopTest();

      Assert.areEqual('Completed', result.status, 'A Decimal amount is valid');
      Assert.areEqual(
        1,
        MockFlakyOrderServices.chargeAttempts,
        'The amount does not cause a retry'
      );
      Assert.areEqual(
        4200,
        MockFlakyOrderServices.lastChargeAmountCents,
        'The gateway gets the amount in cents'
      );
    }
  }

  @IsTest
  static void fractionalAmountFailsWithoutRetry() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      MockFlakyOrderServices.reset();
      Test.startTest();
      WorkflowTestHarness.Result result = runOrder(
        'AutoRetry_Fraction',
        Decimal.valueOf('4200.99')
      );
      Test.stopTest();

      Assert.areEqual('Compensated', result.status, 'Bad amount fails');
      Assert.areEqual(
        0,
        MockFlakyOrderServices.chargeAttempts,
        'The gateway is not called'
      );
      Workflow_Step_Execution__c charge = chargeRow();
      Assert.areEqual(
        0,
        charge.Retry_Count__c.intValue(),
        'fail() is not retried'
      );
      Assert.isTrue(
        charge.Error_Details__c.startsWith('Invalid amountCents: 4200.99'),
        'Details show the bad amount: ' + charge.Error_Details__c
      );
    }
  }

  @IsTest
  static void tooLargeAmountFailsWithoutRetry() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      MockFlakyOrderServices.reset();
      Test.startTest();
      WorkflowTestHarness.Result result = runOrder(
        'AutoRetry_TooLarge',
        Decimal.valueOf('3000000000')
      );
      Test.stopTest();

      Assert.areEqual('Compensated', result.status, 'Bad amount fails');
      Assert.areEqual(
        0,
        MockFlakyOrderServices.chargeAttempts,
        'The gateway is not called'
      );
      Assert.areEqual(
        0,
        chargeRow().Retry_Count__c.intValue(),
        'fail() is not retried'
      );
    }
  }

  @IsTest
  static void refundIsIdempotentByKey() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      MockFlakyOrderServices.reset();
      MockFlakyOrderServices.refund('refund-key', 'ch_1');
      MockFlakyOrderServices.refund('refund-key', 'ch_1');
      Assert.areEqual(
        1,
        MockFlakyOrderServices.refunds,
        'A repeat refund with the same key does nothing'
      );
    }
  }

  @IsTest
  static void longGatewayOutageRollsBack() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      MockFlakyOrderServices.reset();
      MockFlakyOrderServices.gatewayOutagesLeft = 99;
      Test.startTest();
      WorkflowTestHarness.Result result = runOrder('AutoRetry_Down');
      Test.stopTest();

      Assert.areEqual('Compensated', result.status, 'Saga rolls back');
      Assert.areEqual(
        new List<String>{ RESERVE + '_Compensate' },
        result.compensatedSteps,
        'Only the reservation is released: no charge was made'
      );
      Assert.areEqual(
        4,
        MockFlakyOrderServices.chargeAttempts,
        'Gateway is called maximumAttempts (4) times'
      );
      Assert.areEqual(0, MockFlakyOrderServices.effectiveCharges, 'No charge');
      Assert.areEqual(0, MockFlakyOrderServices.refunds, 'Nothing to refund');
      Workflow_Step_Execution__c charge = chargeRow();
      Assert.areEqual('Failed', charge.Status__c, 'Charge step fails');
      Assert.areEqual(
        4,
        charge.Retry_Count__c.intValue(),
        'Retry count equals attempts'
      );
      Assert.isTrue(
        charge.Error_Details__c.startsWith(
          'Auto-retry exhausted after 4 attempts: 503 Service Unavailable'
        ),
        'Details show the exhausted auto-retry: ' + charge.Error_Details__c
      );
    }
  }

  @IsTest
  static void optedOutReceiptStepFailsFastAndRefunds() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      MockFlakyOrderServices.reset();
      MockFlakyOrderServices.receiptOutagesLeft = 1;
      Test.startTest();
      WorkflowTestHarness.Result result = runOrder('AutoRetry_Receipt');
      Test.stopTest();

      Assert.areEqual('Compensated', result.status, 'Receipt fails fast');
      Assert.areEqual(
        new List<String>{ CHARGE + '_Compensate', RESERVE + '_Compensate' },
        result.compensatedSteps,
        'Refund, then release (LIFO)'
      );
      Assert.areEqual(
        1,
        MockFlakyOrderServices.receiptAttempts,
        'The receipt step is not retried'
      );
      Assert.areEqual(1, MockFlakyOrderServices.refunds, 'Card is refunded');
      Assert.areEqual(
        'ch_1',
        MockFlakyOrderServices.lastRefundedChargeId,
        'Refund uses the charge id from the step output'
      );
    }
  }
}
