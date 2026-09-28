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

  private static void assertRecorded(Id instanceId, String stepName) {
    Workflow_Step_Execution__c row = [
      SELECT Decision_Record__c
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c = :instanceId AND Step_Name__c = :stepName
      ORDER BY CreatedDate DESC, Id DESC
      LIMIT 1
    ];
    Assert.isNotNull(
      row.Decision_Record__c,
      'Strict mode recorded the wait of ' + stepName
    );
  }

  private static String status(Id instanceId) {
    return [SELECT Status__c FROM Workflow_Instance__c WHERE Id = :instanceId]
    .Status__c;
  }

  @IsTest
  static void approvalWaitRepeatsThenApproves() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
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
      Assert.areEqual('Suspended', status(instanceId), 'The approval waits');
      assertRecorded(
        instanceId,
        'ApprovalSignalWorkflowExample.RequestApprovalStep'
      );

      WorkflowEngine.signal(
        'StrictApprovalKey',
        ApprovalSignalWorkflowExample.DECISION_SIGNAL,
        '{"approved":true}'
      );
      new WorkflowOrchestrator(instanceId).execute(null);
      new WorkflowOrchestrator(instanceId).execute(null);

      Assert.areEqual(
        'Completed',
        status(instanceId),
        'The approval completes the run'
      );
      Test.stopTest();
      assertNoDivergence();
    }
  }

  @IsTest
  static void signalFanInWaitRepeatsThenSplits() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      strictOn();
      Id instanceId = WorkflowEngine.start(
        'ParallelSignalFanInWorkflowExample',
        'StrictFanInKey',
        null
      );
      new WorkflowOrchestrator(instanceId).execute(null);
      new WorkflowOrchestrator(instanceId).execute(null); // duplicate
      Assert.areEqual('Suspended', status(instanceId), 'The gather step waits');
      assertRecorded(
        instanceId,
        'ParallelSignalFanInWorkflowExample.GatherSpawnStep'
      );

      WorkflowEngine.signal('StrictFanInKey', 'Kick', '{}');
      new WorkflowOrchestrator(instanceId).execute(null);

      Workflow_Instance__c inst = [
        SELECT Status__c, Current_Step__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      Assert.areEqual('Running', inst.Status__c, 'The split runs');
      Assert.isTrue(inst.Current_Step__c.contains(','), 'Split into branches');
      Test.stopTest();
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

      Assert.areEqual(
        'Completed',
        result.status,
        'The child composition completes'
      );
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

      Assert.areEqual(
        'Completed',
        result.status,
        'The capture-once run completes'
      );
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

      Assert.areEqual('Compensated', result.status, 'The saga rolls back');
      assertNoDivergence();
    }
  }

  @IsTest
  static void calloutResumePayloadCompletes() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      strictOn();
      CalloutTimeoutWorkflowExample.forceAsyncInTest = true;
      Id instanceId = WorkflowEngine.start(
        'CalloutTimeoutWorkflowExample.CalloutWorkflow',
        'StrictCalloutKey',
        new Map<String, Object>{
          'endpoint' => 'https://httpbin.org/status/200'
        }
      );
      new WorkflowOrchestrator(instanceId).execute(null);
      new WorkflowOrchestrator(instanceId).execute(null); // duplicate
      Assert.areEqual('Suspended', status(instanceId), 'The callout waits');
      assertRecorded(
        instanceId,
        'CalloutTimeoutWorkflowExample.MakeHttpCalloutStep'
      );

      // The async callout job delivers the response as a resume payload.
      WorkflowResumeService.resumeInstance(
        instanceId,
        '{"status":200,"body":"ok"}'
      );
      new WorkflowOrchestrator(instanceId).execute(null);

      Assert.areEqual(
        'Completed',
        status(instanceId),
        'The resume payload completes the run'
      );
      Test.stopTest();
      assertNoDivergence();
    }
  }

  @IsTest
  static void cursorFanoutWaitRepeatsAfterChildrenStart() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      insert new List<Account>{
        new Account(Name = 'Strict A'),
        new Account(Name = 'Strict B'),
        new Account(Name = 'Strict C')
      };
      Test.startTest();
      strictOn();
      Id instanceId = WorkflowEngine.start(
        'RevenantCursorFanoutExample.CursorFanoutWorkflow',
        'StrictCursorFanoutKey',
        null
      );
      new WorkflowOrchestrator(instanceId).execute(null); // query step
      new WorkflowOrchestrator(instanceId).execute(null); // start children
      // Duplicates: the step now sees its children and waits.
      new WorkflowOrchestrator(instanceId).execute(null);
      new WorkflowOrchestrator(instanceId).execute(null);
      new WorkflowOrchestrator(instanceId).execute(null);

      Assert.areEqual(
        'Suspended',
        status(instanceId),
        'The fan-out waits for its children'
      );
      assertRecorded(
        instanceId,
        'RevenantCursorFanoutExample.CursorFanoutStep'
      );
      Test.stopTest();
      assertNoDivergence();
    }
  }
}
