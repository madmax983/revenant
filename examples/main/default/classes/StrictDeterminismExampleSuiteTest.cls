/**
 * @description Runs example workflows with strict determinism mode on (issue
 * #102). Each example must reach its usual end state with zero
 * STEP_NON_DETERMINISM failures. Some cases run a waiting step again with no
 * new input, as a duplicate delivery does.
 */
@IsTest
private class StrictDeterminismExampleSuiteTest {
  private static void strictOn() {
    WorkflowEngine.strictDeterminism = true;
    WorkflowEngine.disableQueueableInTest = true;
  }

  // No divergence log row and no divergence category on any instance.
  private static void assertNoDivergence() {
    Assert.areEqual(
      0,
      [
        SELECT COUNT()
        FROM Workflow_Log__c
        WHERE Log_Type__c = :WorkflowDeterminismGuard.LOG_TYPE
      ],
      'No divergence log rows'
    );
    Assert.areEqual(
      0,
      [
        SELECT COUNT()
        FROM Workflow_Instance__c
        WHERE Failure_Category__c = :WorkflowEngine.CAT_STEP_NON_DETERMINISM
      ],
      'No divergence failures'
    );
  }

  private static String status(Id instanceId) {
    return [SELECT Status__c FROM Workflow_Instance__c WHERE Id = :instanceId]
    .Status__c;
  }

  @IsTest
  static void approvalWaitRepeatsThenApproves() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      strictOn();
      Id instanceId = WorkflowEngine.start(
        'ApprovalSignalWorkflowExample',
        'StrictApprovalKey',
        new Map<String, Object>{ 'amount' => 999 }
      );
      new WorkflowOrchestrator(instanceId).execute(null);
      // Duplicate deliveries: same inputs, so the step must repeat its wait.
      new WorkflowOrchestrator(instanceId).execute(null);
      new WorkflowOrchestrator(instanceId).execute(null);
      Assert.areEqual('Suspended', status(instanceId));

      WorkflowEngine.signal(
        'StrictApprovalKey',
        ApprovalSignalWorkflowExample.DECISION_SIGNAL,
        '{"approved":true}'
      );
      new WorkflowOrchestrator(instanceId).execute(null);
      new WorkflowOrchestrator(instanceId).execute(null);

      Assert.areEqual('Completed', status(instanceId));
      assertNoDivergence();
    }
  }

  @IsTest
  static void signalFanInWaitRepeatsThenSplits() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      strictOn();
      Id instanceId = WorkflowEngine.start(
        'ParallelSignalFanInWorkflowExample',
        'StrictFanInKey',
        null
      );
      new WorkflowOrchestrator(instanceId).execute(null);
      new WorkflowOrchestrator(instanceId).execute(null); // duplicate
      Assert.areEqual('Suspended', status(instanceId));

      WorkflowEngine.signal('StrictFanInKey', 'Kick', '{}');
      new WorkflowOrchestrator(instanceId).execute(null);

      Workflow_Instance__c inst = [
        SELECT Status__c, Current_Step__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      Assert.areEqual('Running', inst.Status__c);
      Assert.isTrue(inst.Current_Step__c.contains(','), 'Split into branches');
      assertNoDivergence();
    }
  }

  @IsTest
  static void childCompositionCompletes() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      strictOn();
      Id parentId = WorkflowEngine.start(
        'ChildWorkflowCompositionExample',
        'StrictLoanApp',
        new Map<String, Object>{
          'applicant' => 'Alice',
          'annualIncome' => 100000,
          'requestedAmount' => 50000
        }
      );
      WorkflowTestHarness.Result result = new WorkflowTestHarness(parentId)
        .drive();
      Test.stopTest();

      Assert.areEqual('Completed', result.status);
      assertNoDivergence();
    }
  }

  @IsTest
  static void childFanOutCompletes() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      strictOn();
      Id parentId = WorkflowEngine.start(
        'ChildWorkflowFanOutExample',
        'StrictFanOut_' + Crypto.getRandomInteger(),
        new List<Map<String, Object>>{
          new Map<String, Object>{ 'id' => 'itemA', 'value' => 15 },
          new Map<String, Object>{ 'id' => 'itemB', 'value' => 25 },
          new Map<String, Object>{ 'id' => 'itemC', 'value' => 5 }
        }
      );
      WorkflowTestHarness.Result result = new WorkflowTestHarness(parentId)
        .drive();
      Test.stopTest();

      Assert.areEqual('Completed', result.status);
      assertNoDivergence();
    }
  }

  @IsTest
  static void captureOnceCompletes() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      CaptureOnceWorkflowExample.resetProducerCounters();
      Test.startTest();
      strictOn();
      Id instanceId = WorkflowEngine.start(
        'CaptureOnceWorkflowExample.CaptureOnceWorkflow',
        'strict-capture-once',
        null
      );
      WorkflowTestHarness.Result result = new WorkflowTestHarness(instanceId)
        .drive();
      Test.stopTest();

      Assert.areEqual('Completed', result.status);
      assertNoDivergence();
    }
  }

  @IsTest
  static void sagaFailureCompensates() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      strictOn();
      Id instanceId = WorkflowEngine.start(
        'SagaWorkflowExample.SagaWorkflow',
        'StrictSagaKey',
        '{"email":"test@example.com"}'
      );
      WorkflowTestHarness harness = new WorkflowTestHarness(instanceId);
      harness.failStep(
        'SagaWorkflowExample.SendWelcomeEmailStep',
        'SMTP Server Down'
      );
      WorkflowTestHarness.Result result = harness.drive();
      Test.stopTest();

      Assert.areEqual('Compensated', result.status);
      assertNoDivergence();
    }
  }
}
