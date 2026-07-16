@IsTest
public class WorkflowEngineCompensation1Test {
  private static List<Workflow_Step_Execution__c> resumeCompensationAndAssertReplayed(
    Id instanceId,
    String attemptsPreservedMessage
  ) {
    Workflow_Instance__c stalled = [
      SELECT Status__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals('CompensationFailed', stalled.Status__c);

    WorkflowCompensation.resumeCompensation(instanceId);
    WorkflowEngine.runStep(instanceId, null);
    Test.stopTest();

    Workflow_Instance__c finalInst = [
      SELECT Status__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals('Compensated', finalInst.Status__c);

    List<Workflow_Step_Execution__c> compAttempts = [
      SELECT Status__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :instanceId
        AND Step_Name__c = 'WorkflowEngineTest.CompensatableHappyStep_Compensate'
      ORDER BY CreatedDate ASC, Id ASC
    ];
    System.assertEquals(2, compAttempts.size(), attemptsPreservedMessage);
    System.assertEquals('Failed', compAttempts[0].Status__c);
    return compAttempts;
  }

  @IsTest
  static void testCompensationCrashViaFinalizerRecordsCompensationStep() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // A finalizer-style crash during compensation (no stepName) must be recorded against
      // the top-of-stack _Compensate step, not the stale forward Current_Step__c, so the
      // append-only audit trail and resume path stay correct.
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
        Status__c = 'Compensating',
        Current_Step__c = 'WorkflowEngineTest.HappyStep1', // stale forward step
        Compensation_Stack__c = JSON.serialize(
          new List<String>{ 'WorkflowEngineTest.CompensatableHappyStep' }
        ),
        Input__c = '{"test": true}'
      );
      insert inst;
      // The pre-created pending compensation log (as preCreateFirstCompensationStep makes).
      Workflow_Step_Execution__c compLog = new Workflow_Step_Execution__c(
        Workflow_Instance__c = inst.Id,
        Step_Name__c = 'WorkflowEngineTest.CompensatableHappyStep_Compensate',
        Status__c = 'Pending',
        Retry_Count__c = 0
      );
      insert compLog;

      Test.startTest();
      WorkflowEngine.handleCrash(
        inst.Id,
        new WorkflowEngine.WorkflowException(
          'Governor limit during compensation'
        )
      );

      // The crash is recorded against the compensation step, not the stale forward step.
      Workflow_Step_Execution__c crashedComp = [
        SELECT Status__c
        FROM Workflow_Step_Execution__c
        WHERE Id = :compLog.Id
      ];
      System.assertEquals('Failed', crashedComp.Status__c);

      Integer forwardFailures = [
        SELECT COUNT()
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :inst.Id
          AND Step_Name__c = 'WorkflowEngineTest.HappyStep1'
          AND Status__c = 'Failed'
      ];
      System.assertEquals(
        0,
        forwardFailures,
        'A compensation crash must not create a spurious forward-step failure'
      );

      // Resume appends a fresh attempt (append-only) and completes the rollback.
      List<Workflow_Step_Execution__c> compAttempts = resumeCompensationAndAssertReplayed(
        inst.Id,
        'The failed attempt is preserved alongside the successful resume attempt'
      );
      System.assertEquals(
        'Compensated',
        compAttempts[compAttempts.size() - 1].Status__c
      );
    }
  }

  @IsTest
  static void testSuspendedCompensationCrashRecordsCompensationStep() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // A sleeping/approval-gated compensation: the engine parked the saga as Suspended
      // while a _Compensate step waited (SLEEP/SUSPEND/WAIT_FOR_APPROVAL), then resumed it
      // via WorkflowOrchestrator(instanceId) with no stepName. runStep flips Suspended back
      // to Compensating in-transaction, but a crash rolls that flip back, so the finalizer's
      // handleCrash sees status 'Suspended' with a blank stepName. It must still record the
      // crash against the top-of-stack _Compensate step (not the stale forward step) and
      // park the saga as recoverable CompensationFailed.
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
        Status__c = 'Suspended', // rolled back from Compensating by the crash
        Current_Step__c = 'WorkflowEngineTest.HappyStep1', // stale forward step
        Compensation_Stack__c = JSON.serialize(
          new List<String>{ 'WorkflowEngineTest.CompensatableHappyStep' }
        ),
        Input__c = '{"test": true}'
      );
      insert inst;
      // The suspended _Compensate attempt (Pending, as the SLEEP/approval branch leaves it).
      // It is the latest step execution, which is how handleCrash detects mid-rollback.
      Workflow_Step_Execution__c compLog = new Workflow_Step_Execution__c(
        Workflow_Instance__c = inst.Id,
        Step_Name__c = 'WorkflowEngineTest.CompensatableHappyStep_Compensate',
        Status__c = 'Pending',
        Retry_Count__c = 0
      );
      insert compLog;

      Test.startTest();
      WorkflowEngine.handleCrash(
        inst.Id,
        new WorkflowEngine.WorkflowException(
          'Crash resuming sleeping compensation'
        )
      );

      Workflow_Step_Execution__c crashedComp = [
        SELECT Status__c
        FROM Workflow_Step_Execution__c
        WHERE Id = :compLog.Id
      ];
      System.assertEquals('Failed', crashedComp.Status__c);

      Integer forwardFailures = [
        SELECT COUNT()
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :inst.Id
          AND Step_Name__c = 'WorkflowEngineTest.HappyStep1'
          AND Status__c = 'Failed'
      ];
      System.assertEquals(
        0,
        forwardFailures,
        'A suspended-compensation crash must not create a spurious forward-step failure'
      );

      resumeCompensationAndAssertReplayed(
        inst.Id,
        'The failed suspended attempt is preserved alongside the successful resume attempt'
      );
    }
  }

  @IsTest
  static void testCompensationFlow() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
        Status__c = 'Compensating',
        Compensation_Stack__c = JSON.serialize(
          new List<String>{
            'WorkflowEngineTest.NonCompensatableStep',
            'WorkflowEngineTest.CompensatableHappyStep'
          }
        ),
        Input__c = '{"test": true}'
      );
      insert inst;

      Workflow_Step_Execution__c origExec = new Workflow_Step_Execution__c(
        Workflow_Instance__c = inst.Id,
        Step_Name__c = 'WorkflowEngineTest.CompensatableHappyStep',
        Status__c = 'Completed',
        Input__c = '{"stepInput": 1}',
        Output__c = '{"stepOutput": 2}'
      );
      insert origExec;

      Test.startTest();
      WorkflowEngine.runStep(inst.Id, null); // Runs CompensatableHappyStep
      WorkflowEngine.runStep(inst.Id, null); // Runs NonCompensatableStep (skipped)
      WorkflowEngine.runStep(inst.Id, null); // Stack empty -> transition status to Compensated
      Test.stopTest();

      Workflow_Instance__c completedInst = [
        SELECT Status__c, Compensation_Stack__c
        FROM Workflow_Instance__c
        WHERE Id = :inst.Id
      ];
      System.assertEquals('Compensated', completedInst.Status__c);

      List<Workflow_Step_Execution__c> stepExecs = [
        SELECT Step_Name__c, Status__c, Output__c
        FROM Workflow_Step_Execution__c
        WHERE Workflow_Instance__c = :inst.Id
        ORDER BY CreatedDate ASC, Id ASC
      ];
      System.assertEquals(3, stepExecs.size());
      System.assertEquals(
        'WorkflowEngineTest.CompensatableHappyStep_Compensate',
        stepExecs[1].Step_Name__c
      );
      System.assertEquals('Compensated', stepExecs[1].Status__c);
      System.assertEquals('"Compensated"', stepExecs[1].Output__c);

      System.assertEquals(
        'WorkflowEngineTest.NonCompensatableStep_Compensate',
        stepExecs[2].Step_Name__c
      );
      System.assertEquals('Compensated', stepExecs[2].Status__c);
    }
  }

  @IsTest
  static void testCompensationContextCarriesPreviousRunAt() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      WorkflowEngineMocksATest.capturedCompensatePreviousRunAt = null;
      WorkflowEngineMocksATest.compensatePreviousRunAtCaptured = false;

      Datetime priorRun = Datetime.newInstanceGmt(2026, 1, 2, 3, 4, 5);
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
        Status__c = 'Compensating',
        Compensation_Stack__c = JSON.serialize(
          new List<String>{
            'WorkflowEngineMocksBTest.PreviousRunAtCompensatableStep'
          }
        ),
        Input__c = '{"test": true}',
        Previous_Run_At__c = priorRun
      );
      insert inst;

      insert new Workflow_Step_Execution__c(
        Workflow_Instance__c = inst.Id,
        Step_Name__c = 'WorkflowEngineMocksBTest.PreviousRunAtCompensatableStep',
        Status__c = 'Completed',
        Input__c = '{"stepInput": 1}',
        Output__c = '{"stepOutput": 2}'
      );

      Test.startTest();
      WorkflowEngine.runStep(inst.Id, null); // runs *_Compensate
      Test.stopTest();

      System.assert(
        WorkflowEngineMocksATest.compensatePreviousRunAtCaptured,
        'compensate() should have been invoked'
      );
      System.assertEquals(
        priorRun,
        WorkflowEngineMocksATest.capturedCompensatePreviousRunAt,
        'compensate() must observe the instance Previous_Run_At__c, not null'
      );
    }
  }

  @IsTest
  static void testCalloutCompensationWithTimeoutDoesNotHitUncommittedWork() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.setMock(
        HttpCalloutMock.class,
        new WorkflowEngineMocksATest.CompOkMock()
      );
      WorkflowEngine.disableQueueableInTest = true;

      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
        Status__c = 'Compensating',
        Compensation_Stack__c = JSON.serialize(
          new List<String>{ 'WorkflowEngineMocksBTest.CalloutCompensationStep' }
        ),
        Input__c = '{"test": true}'
      );
      insert inst;

      insert new Workflow_Step_Execution__c(
        Workflow_Instance__c = inst.Id,
        Step_Name__c = 'WorkflowEngineMocksBTest.CalloutCompensationStep',
        Status__c = 'Completed',
        Output__c = '{}'
      );

      Test.startTest();
      WorkflowEngine.runStep(inst.Id, null); // runs CalloutCompensationStep_Compensate
      Test.stopTest();

      Workflow_Step_Execution__c compExec = [
        SELECT Status__c, Output__c
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :inst.Id
          AND Step_Name__c = 'WorkflowEngineMocksBTest.CalloutCompensationStep_Compensate'
        ORDER BY CreatedDate DESC, Id DESC
        LIMIT 1
      ];
      System.assertEquals(
        'Compensated',
        compExec.Status__c,
        'A CalloutStep+TimeoutConfigurable compensation must complete its synchronous callout without an uncommitted-work exception'
      );
      System.assert(
        compExec.Output__c != null && compExec.Output__c.contains('204'),
        'compensation callout response should be recorded, got: ' +
        compExec.Output__c
      );
    }
  }

  @IsTest
  static void testSignalResumedCalloutCompensationDefersStatusDml() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.setMock(
        HttpCalloutMock.class,
        new WorkflowEngineMocksATest.CompOkMock()
      );
      WorkflowEngine.disableQueueableInTest = true;

      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
        Status__c = 'Suspended',
        Compensation_Stack__c = JSON.serialize(
          new List<String>{ 'WorkflowEngineMocksBTest.CalloutCompensationStep' }
        ),
        Input__c = '{"test": true}'
      );
      insert inst;

      // The forward step completed (so it is on the stack), then the compensation
      // step that suspended waiting for the signal: its '_Compensate' execution is
      // the latest row and still Pending, which is how runStep detects that this
      // Suspended instance is actually mid-rollback.
      insert new Workflow_Step_Execution__c(
        Workflow_Instance__c = inst.Id,
        Step_Name__c = 'WorkflowEngineMocksBTest.CalloutCompensationStep',
        Status__c = 'Completed',
        Output__c = '{}'
      );
      insert new Workflow_Step_Execution__c(
        Workflow_Instance__c = inst.Id,
        Step_Name__c = 'WorkflowEngineMocksBTest.CalloutCompensationStep_Compensate',
        Status__c = 'Pending'
      );

      // The signal that resumes the suspended compensation step.
      insert new Workflow_Signal__c(
        Workflow_Instance__c = inst.Id,
        Signal_Name__c = 'CompSig',
        Payload__c = 'go',
        Status__c = 'Received'
      );

      Test.startTest();
      WorkflowEngine.runStep(inst.Id, null); // resumes CalloutCompensationStep_Compensate
      Test.stopTest();

      Workflow_Step_Execution__c compExec = [
        SELECT Status__c, Output__c
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :inst.Id
          AND Step_Name__c = 'WorkflowEngineMocksBTest.CalloutCompensationStep_Compensate'
        ORDER BY CreatedDate DESC, Id DESC
        LIMIT 1
      ];
      System.assertEquals(
        'Compensated',
        compExec.Status__c,
        'A signal-resumed CalloutStep compensation must complete its callout; the Suspended->Compensating status DML must be deferred past compensate()'
      );
      System.assert(
        compExec.Output__c != null && compExec.Output__c.contains('204'),
        'compensation callout response should be recorded, got: ' +
        compExec.Output__c
      );
    }
  }

  @IsTest
  static void testSignalStoredWhileCompensating() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
        Status__c = 'Compensating',
        Compensation_Stack__c = JSON.serialize(
          new List<String>{ 'WorkflowEngineMocksBTest.CalloutCompensationStep' }
        ),
        Input__c = '{}'
      );
      insert inst;

      // No startTest/stopTest: enqueueResume queues an orchestrator that does not
      // execute during the test, so this isolates signal()'s store-vs-reject choice.
      WorkflowEngine.signal(inst.Id, 'CompSig', '{"ok":true}');

      List<Workflow_Signal__c> sigs = [
        SELECT Id
        FROM Workflow_Signal__c
        WHERE Workflow_Instance__c = :inst.Id AND Signal_Name__c = 'CompSig'
      ];
      System.assertEquals(
        1,
        sigs.size(),
        'A signal sent while Compensating must be stored for the compensation step, not rejected as no-active-workflow'
      );
    }
  }

  @IsTest
  static void testForwardStepNamedCompensateNotMisroutedAsCompensation() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id instanceId = WorkflowEngine.start(
        'WorkflowEngineMocksATest.SuffixForwardWorkflow',
        'SuffixKey',
        null
      );
      // First run: forward step suspends waiting for 'Go'. It must NOT be treated
      // as a compensation despite its '_Compensate' suffix (empty stack).
      new WorkflowOrchestrator(instanceId).execute(null);
      WorkflowEngine.signal('SuffixKey', 'Go', '{}');
      // Resume: signal() flipped the instance to Running. The suffix heuristic must
      // still route forward (no matching compensation stack), not to compensation.
      new WorkflowOrchestrator(instanceId).execute(null);

      Workflow_Instance__c inst = [
        SELECT Status__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      System.assertEquals(
        'Completed',
        inst.Status__c,
        'A forward step named *_Compensate with no compensation stack must resume forward, not be marked Compensated'
      );
    }
  }

  @IsTest
  static void testSignalDrivenCompensationResumes() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
        Status__c = 'Compensating',
        Correlation_Key__c = 'CompKey',
        Compensation_Stack__c = JSON.serialize(
          new List<String>{
            'WorkflowEngineMocksBTest.SignalWaitCompensationStep'
          }
        ),
        Input__c = '{"test": true}'
      );
      insert inst;
      insert new Workflow_Step_Execution__c(
        Workflow_Instance__c = inst.Id,
        Step_Name__c = 'WorkflowEngineMocksBTest.SignalWaitCompensationStep',
        Status__c = 'Completed',
        Output__c = '{}'
      );

      // First run: compensate() suspends waiting for the Rollback signal.
      WorkflowEngine.runStep(inst.Id, null);
      System.assertEquals(
        'Suspended',
        [SELECT Status__c FROM Workflow_Instance__c WHERE Id = :inst.Id]
        .Status__c,
        'Compensation should suspend until the signal arrives'
      );

      // Signal arrives: signal() flips the instance to Running and enqueues a resume.
      WorkflowEngine.signal('CompKey', 'Rollback', '{}');

      // Resume run: must route back into compensation (not the forward path) and finish.
      WorkflowEngine.runStep(inst.Id, null);

      System.assertEquals(
        'Compensated',
        [SELECT Status__c FROM Workflow_Instance__c WHERE Id = :inst.Id]
        .Status__c,
        'A signal-driven compensation must resume and complete, not stay stuck Running'
      );
      Workflow_Step_Execution__c compExec = [
        SELECT Status__c
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :inst.Id
          AND Step_Name__c = 'WorkflowEngineMocksBTest.SignalWaitCompensationStep_Compensate'
        ORDER BY CreatedDate DESC, Id DESC
        LIMIT 1
      ];
      System.assertEquals('Compensated', compExec.Status__c);
    }
  }

  @IsTest
  static void testCompensationFailureAndRetry() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
        Status__c = 'Compensating',
        Compensation_Stack__c = JSON.serialize(
          new List<String>{
            'WorkflowEngineMocksATest.CompensatableFailingStep'
          }
        ),
        Input__c = '{"test": true}'
      );
      insert inst;

      WorkflowEngineMocksATest.compensationShouldFail = true;

      Test.startTest();
      // First execution - should result in RETRY and schedule a retry job
      WorkflowEngine.runStep(inst.Id, null);

      // Find step execution and manually simulate retry attempts
      List<Workflow_Step_Execution__c> execs = [
        SELECT Id, Status__c, Retry_Count__c
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :inst.Id
          AND Step_Name__c = 'WorkflowEngineMocksATest.CompensatableFailingStep_Compensate'
      ];
      System.assertEquals(1, execs.size());
      System.assertEquals('Retrying', execs[0].Status__c);
      System.assertEquals(1, execs[0].Retry_Count__c);

      // Run second time - should exceed maximum attempts (maximumAttempts = 2) and fail
      WorkflowEngine.runStep(inst.Id, null);
      Test.stopTest();

      Workflow_Instance__c failedInst = [
        SELECT
          Status__c,
          Error_Message__c,
          Sleep_Until__c,
          Async_Job_Id__c,
          Failure_Category__c
        FROM Workflow_Instance__c
        WHERE Id = :inst.Id
      ];
      // Exhausting the RetryPolicy budget yields the recoverable "rollback incomplete"
      // condition, NOT a generic terminal Failed.
      System.assertEquals('CompensationFailed', failedInst.Status__c);
      System.assert(
        failedInst.Error_Message__c.contains('failed after max retries')
      );
      System.assertEquals(
        'COMPENSATION_FAILED',
        failedInst.Failure_Category__c
      );
      // The elapsed retry deadline must be cleared so the watchdog cannot prematurely
      // wake a remaining SUSPEND/approval gate once the rollback is resumed.
      System.assertEquals(null, failedInst.Sleep_Until__c);
      System.assertEquals(null, failedInst.Async_Job_Id__c);

      Workflow_Step_Execution__c failedExec = [
        SELECT Status__c, Retry_Count__c
        FROM Workflow_Step_Execution__c
        WHERE Id = :execs[0].Id
      ];
      System.assertEquals('Failed', failedExec.Status__c);
      System.assertEquals(2, failedExec.Retry_Count__c);

      // Now resume the stalled rollback from exactly the failed compensation point.
      WorkflowEngineMocksATest.compensationShouldFail = false;

      WorkflowCompensation.resumeCompensation(inst.Id);
      WorkflowEngine.runStep(inst.Id, null); // Runs the fresh compensation attempt (completes)
      WorkflowEngine.runStep(inst.Id, null); // Stack empty -> transition status to Compensated

      Workflow_Instance__c retriedInst = [
        SELECT Status__c, Error_Message__c, Failure_Category__c
        FROM Workflow_Instance__c
        WHERE Id = :inst.Id
      ];
      System.assertEquals('Compensated', retriedInst.Status__c);
      System.assertEquals(null, retriedInst.Failure_Category__c);

      // Append-only: the original failed attempt's record is preserved untouched.
      Workflow_Step_Execution__c preservedFailedExec = [
        SELECT Status__c, Retry_Count__c
        FROM Workflow_Step_Execution__c
        WHERE Id = :execs[0].Id
      ];
      System.assertEquals('Failed', preservedFailedExec.Status__c);
      System.assertEquals(2, preservedFailedExec.Retry_Count__c);

      // A fresh, successful compensation attempt was appended for the same step.
      List<Workflow_Step_Execution__c> compAttempts = [
        SELECT Status__c, Output__c
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :inst.Id
          AND Step_Name__c = 'WorkflowEngineMocksATest.CompensatableFailingStep_Compensate'
        ORDER BY CreatedDate ASC, Id ASC
      ];
      System.assertEquals(
        2,
        compAttempts.size(),
        'Failed attempt preserved alongside the successful resume attempt'
      );
      Workflow_Step_Execution__c successfulAttempt = compAttempts[
        compAttempts.size() - 1
      ];
      System.assertEquals('Compensated', successfulAttempt.Status__c);
      System.assertEquals('"CompensatedFailing"', successfulAttempt.Output__c);
    }
  }

  @IsTest
  static void testCancelWorkflowActiveNoCompensations() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      Id instanceId = WorkflowEngine.start(
        'WorkflowEngineTest.SuspendingWorkflow',
        'CancelKey1',
        null
      );
      Test.stopTest(); // Executes initial step and suspends

      Workflow_Instance__c inst = [
        SELECT Status__c, Current_Step__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      System.assertEquals('Suspended', inst.Status__c);
      System.assertEquals(
        'WorkflowEngineTest.SuspendingStep',
        inst.Current_Step__c
      );

      WorkflowEngine.cancel(instanceId);

      inst = [
        SELECT Status__c, Current_Step__c, Error_Message__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      System.assertEquals('Cancelled', inst.Status__c);
      System.assertEquals('Cancelled by user.', inst.Error_Message__c);

      List<Workflow_Step_Execution__c> steps = [
        SELECT Status__c
        FROM Workflow_Step_Execution__c
        WHERE Workflow_Instance__c = :instanceId
      ];
      System.assert(!steps.isEmpty());
      for (Workflow_Step_Execution__c s : steps) {
        System.assertEquals('Cancelled', s.Status__c);
      }
    }
  }

  @IsTest
  static void testCancelWorkflowActiveWithCompensations() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;

      // Use SagaWorkflowExample for saga stack building
      Id instanceId = WorkflowEngine.start(
        'SagaWorkflowExample.SagaWorkflow',
        'CancelKey2',
        null
      );

      // Run first step (ChargeCreditCardStep) to push to stack
      WorkflowEngine.runStep(instanceId, null);

      Workflow_Instance__c inst = [
        SELECT Status__c, Current_Step__c, Compensation_Stack__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      System.assertEquals(
        'SagaWorkflowExample.ProvisionServiceStep',
        inst.Current_Step__c
      );
      System.assert(
        inst.Compensation_Stack__c.contains(
          'SagaWorkflowExample.ChargeCreditCardStep'
        )
      );

      Test.startTest();
      // Cancel with compensations
      WorkflowEngine.cancelWithCompensations(instanceId);

      // Assert status is now Cancelling
      inst = [
        SELECT Status__c, Current_Step__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      System.assertEquals('Cancelling', inst.Status__c);

      // Execute the compensation step (pops ChargeCreditCardStep)
      WorkflowEngine.runStep(instanceId, null);

      // Finish compensation loop
      WorkflowEngine.runStep(instanceId, null);
      Test.stopTest();

      inst = [
        SELECT Status__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      System.assertEquals('Cancelled', inst.Status__c);
    }
  }

  @IsTest
  static void testCancelWorkflowSleeping() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      Id instanceId = WorkflowEngine.start(
        'WorkflowEngineMocksATest.SleepingWorkflow',
        'CancelKey3',
        null
      );
      Test.stopTest(); // Runs the queueable and puts the workflow to Sleep (Suspended)

      Workflow_Instance__c inst = [
        SELECT Status__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      System.assertEquals('Suspended', inst.Status__c);

      // Cancel sleeping workflow
      WorkflowEngine.cancel(instanceId);

      inst = [
        SELECT Status__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      System.assertEquals('Cancelled', inst.Status__c);
    }
  }

  @IsTest
  static void testCancelWorkflowParentChild() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Id parentId = WorkflowEngine.start(
        'WorkflowEngineMocksATest.ParentWorkflow',
        'CancelParent',
        null
      );

      // Execute parent, which starts child and suspends
      WorkflowEngine.runStep(parentId, null);

      Workflow_Instance__c childInst = [
        SELECT Id, Status__c
        FROM Workflow_Instance__c
        WHERE Parent_Instance__c = :parentId
        LIMIT 1
      ];
      System.assertEquals('Pending', childInst.Status__c);

      Test.startTest();
      // Cancel parent, should recursively cancel child
      WorkflowEngine.cancel(parentId);
      Test.stopTest();

      Workflow_Instance__c parent = [
        SELECT Status__c
        FROM Workflow_Instance__c
        WHERE Id = :parentId
      ];
      childInst = [
        SELECT Status__c
        FROM Workflow_Instance__c
        WHERE Id = :childInst.Id
      ];

      System.assertEquals('Cancelled', parent.Status__c);
      System.assertEquals('Cancelled', childInst.Status__c);
    }
  }

  @IsTest
  static void testCancelWorkflowViaSignal() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Id instanceId = WorkflowEngine.start(
        'WorkflowEngineTest.HappyWorkflow',
        'CancelSignalKey',
        null
      );

      Test.startTest();
      // Signal cancellation
      WorkflowEngine.signal(
        'CancelSignalKey',
        'Cancel',
        '{"runCompensations": false}'
      );
      Test.stopTest();

      Workflow_Instance__c inst = [
        SELECT Status__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      System.assertEquals('Cancelled', inst.Status__c);
    }
  }

  @IsTest
  static void testPreStartTimeout() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Id instanceId = WorkflowEngine.start(
        'WorkflowEngineTest.HappyWorkflow',
        'PreStartTimeoutKey',
        null
      );

      // Let's manually create a Pending step execution
      Workflow_Step_Execution__c stepExec = new Workflow_Step_Execution__c(
        Workflow_Instance__c = instanceId,
        Step_Name__c = 'WorkflowEngineTest.HappyStep1',
        Status__c = 'Pending'
      );
      insert stepExec;

      // We make instance Running
      Workflow_Instance__c inst = [
        SELECT Id
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      inst.Status__c = 'Running';
      inst.Current_Step__c = 'WorkflowEngineTest.HappyStep1';
      update inst;

      stepExec.Timeout_At__c = DateTime.now().addSeconds(-10);
      update as system stepExec;

      // Run the watchdog
      Test.startTest();
      WorkflowEngine.processWatchdogHeartbeat();
      Test.stopTest();

      // Verify step execution is marked Failed with 'Step execution timed out before starting.'
      Workflow_Step_Execution__c timedOutStep = [
        SELECT Status__c, Error_Details__c
        FROM Workflow_Step_Execution__c
        WHERE Id = :stepExec.Id
      ];
      System.assertEquals('Failed', timedOutStep.Status__c);
      System.assertEquals(
        'Step execution timed out before starting.',
        timedOutStep.Error_Details__c
      );

      // Verify workflow instance transitions to Failed
      Workflow_Instance__c timedOutInst = [
        SELECT Status__c, Error_Message__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      System.assertEquals('Failed', timedOutInst.Status__c);
      System.assert(
        timedOutInst.Error_Message__c.contains(
          'Step execution timed out before starting.'
        )
      );
    }
  }

  @IsTest
  static void testCompensationTimeout() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
        Status__c = 'Compensating',
        Compensation_Stack__c = JSON.serialize(
          new List<String>{ 'WorkflowEngineTest.CompensatableHappyStep' }
        ),
        Input__c = '{"test": true}'
      );
      insert inst;

      Workflow_Step_Execution__c compExec = new Workflow_Step_Execution__c(
        Workflow_Instance__c = inst.Id,
        Step_Name__c = 'WorkflowEngineTest.CompensatableHappyStep_Compensate',
        Status__c = 'Running'
      );
      insert compExec;

      compExec.Timeout_At__c = DateTime.now().addSeconds(-10);
      update as system compExec;

      // Run the watchdog for the compensation step
      Test.startTest();
      WorkflowEngine.processWatchdogHeartbeat();
      Test.stopTest();

      // Verify step execution status is Failed
      Workflow_Step_Execution__c timedOutStep = [
        SELECT Status__c, Error_Details__c
        FROM Workflow_Step_Execution__c
        WHERE Id = :compExec.Id
      ];
      System.assertEquals('Failed', timedOutStep.Status__c);

      // Verify instance status transitions to Failed and does not get stuck in Compensating
      Workflow_Instance__c timedOutInst = [
        SELECT
          Status__c,
          Error_Message__c,
          Compensation_Stack__c,
          Failure_Category__c
        FROM Workflow_Instance__c
        WHERE Id = :inst.Id
      ];
      System.assertEquals('CompensationFailed', timedOutInst.Status__c);
      System.assert(timedOutInst.Error_Message__c.contains('timed out'));
      System.assertEquals(
        'COMPENSATION_FAILED',
        timedOutInst.Failure_Category__c
      );
      // Compensation stack should NOT be popped
      List<String> stack = (List<String>) JSON.deserialize(
        timedOutInst.Compensation_Stack__c,
        List<String>.class
      );
      System.assertEquals(1, stack.size());
      System.assertEquals(
        'WorkflowEngineTest.CompensatableHappyStep',
        stack[0]
      );
    }
  }

  @IsTest
  static void testCompensationFailureRollback() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
        Status__c = 'Compensating',
        Compensation_Stack__c = JSON.serialize(
          new List<String>{ 'WorkflowEngineMocksBTest.CompensatableCrashStep' }
        ),
        Input__c = '{"test": true}'
      );
      insert inst;

      // Run the step compensation (will crash because of the mock class)
      Test.startTest();
      WorkflowEngine.runStep(inst.Id, null);
      Test.stopTest();

      // Verify instance transitions to Failed and does not pop the stack
      Workflow_Instance__c failedInst = [
        SELECT
          Status__c,
          Error_Message__c,
          Compensation_Stack__c,
          Failure_Category__c
        FROM Workflow_Instance__c
        WHERE Id = :inst.Id
      ];
      System.assertEquals('CompensationFailed', failedInst.Status__c);
      System.assert(
        failedInst.Error_Message__c.contains('Compensation crash simulation')
      );
      System.assertEquals(
        'COMPENSATION_FAILED',
        failedInst.Failure_Category__c
      );

      List<String> stack = (List<String>) JSON.deserialize(
        failedInst.Compensation_Stack__c,
        List<String>.class
      );
      System.assertEquals(1, stack.size());
      System.assertEquals(
        'WorkflowEngineMocksBTest.CompensatableCrashStep',
        stack[0]
      );
    }
  }

  @IsTest
  static void testStalledCancellationResumesToCancelled() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // A user-cancelled rollback that stalls must remember it was cancel-driven, so
      // that resuming it terminates as 'Cancelled' (not 'Compensated').
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
        Status__c = 'Cancelling',
        Error_Message__c = 'Cancelled by user. Compensating.',
        Compensation_Stack__c = JSON.serialize(
          new List<String>{
            'WorkflowEngineMocksATest.CompensatableFailingStep'
          }
        ),
        Input__c = '{"test": true}'
      );
      insert inst;

      WorkflowEngineMocksATest.compensationShouldFail = true;

      Test.startTest();
      WorkflowEngine.runStep(inst.Id, null); // RETRY (attempt 1)
      WorkflowEngine.runStep(inst.Id, null); // exhausts retries -> stalls

      Workflow_Instance__c stalled = [
        SELECT Status__c, Error_Message__c
        FROM Workflow_Instance__c
        WHERE Id = :inst.Id
      ];
      System.assertEquals('CompensationFailed', stalled.Status__c);
      // The cancel-driven phase marker must survive the stall.
      System.assert(
        stalled.Error_Message__c.contains('Cancelled'),
        'Stalled cancel rollback must retain its Cancelled marker: ' +
        stalled.Error_Message__c
      );

      // The transient failure clears; the operator resumes the rollback.
      WorkflowEngineMocksATest.compensationShouldFail = false;
      WorkflowCompensation.resumeCompensation(inst.Id);

      // The resumed rollback must remain cancel-driven, with the 'Cancelled' marker
      // intact so that a suspend (RETRY/SLEEP) before the stack drains still restores
      // the phase as 'Cancelling' rather than 'Compensating'.
      Workflow_Instance__c resumed = [
        SELECT Status__c, Error_Message__c
        FROM Workflow_Instance__c
        WHERE Id = :inst.Id
      ];
      System.assertEquals('Cancelling', resumed.Status__c);
      System.assert(
        resumed.Error_Message__c != null &&
        resumed.Error_Message__c.contains('Cancelled'),
        'Resumed cancel rollback must retain the Cancelled phase marker: ' +
        resumed.Error_Message__c
      );

      WorkflowEngine.runStep(inst.Id, null); // compensate succeeds -> stack drains
      Test.stopTest();

      Workflow_Instance__c finalInst = [
        SELECT Status__c
        FROM Workflow_Instance__c
        WHERE Id = :inst.Id
      ];
      System.assertEquals(
        'Cancelled',
        finalInst.Status__c,
        'A resumed cancel-driven rollback must terminate as Cancelled, not Compensated'
      );
    }
  }

  @IsTest
  static void testStalledRollbackReservesCorrelationKey() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // A stalled rollback still has un-reversed side effects, so its correlation key
      // must stay reserved: starting a second workflow with the same key must be blocked.
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
        Status__c = 'CompensationFailed',
        Correlation_Key__c = 'StalledReservedKey',
        Compensation_Stack__c = JSON.serialize(
          new List<String>{ 'WorkflowEngineTest.CompensatableHappyStep' }
        ),
        Error_Message__c = 'Rollback incomplete: ...'
      );
      insert inst;

      // The trigger should keep the active key reserved for the stalled saga.
      Workflow_Instance__c reloaded = [
        SELECT Active_Correlation_Key__c
        FROM Workflow_Instance__c
        WHERE Id = :inst.Id
      ];
      System.assertEquals(
        'StalledReservedKey',
        reloaded.Active_Correlation_Key__c,
        'CompensationFailed must retain its active correlation key'
      );

      Test.startTest();
      // Get-or-start: because CompensationFailed is an active status, a second start
      // with the same key must dedup to the stalled instance rather than create a
      // duplicate active workflow while side effects are still un-reversed.
      Id deduped = WorkflowEngine.start(
        'WorkflowEngineTest.HappyWorkflow',
        'StalledReservedKey',
        null
      );
      Test.stopTest();

      System.assertEquals(
        inst.Id,
        deduped,
        'A start colliding with a stalled rollback must resolve to the stalled instance'
      );
      Integer activeCount = [
        SELECT COUNT()
        FROM Workflow_Instance__c
        WHERE Correlation_Key__c = 'StalledReservedKey'
      ];
      System.assertEquals(
        1,
        activeCount,
        'No duplicate instance may be created while the rollback is stalled'
      );
    }
  }
}
