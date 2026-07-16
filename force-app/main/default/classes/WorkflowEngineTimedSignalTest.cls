@IsTest
public class WorkflowEngineTimedSignalTest {
  @IsTest
  static void testUnroutedSignalCapturedSingleMethod() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Sending a signal when no active instance matches must create an Unrouted
      // Workflow_Signal__c row instead of throwing.
      WorkflowEngine.disableQueueableInTest = true;

      Test.startTest();
      WorkflowEngine.signal('NoSuchKey-Single', 'WakeUp', '{"x":1}');
      Test.stopTest();

      List<Workflow_Signal__c> captured = [
        SELECT
          Id,
          Status__c,
          Correlation_Key__c,
          Signal_Name__c,
          Payload__c,
          Workflow_Instance__c
        FROM Workflow_Signal__c
        WHERE Correlation_Key__c = 'NoSuchKey-Single'
      ];
      System.assertEquals(
        1,
        captured.size(),
        'Unmatched signal must be captured as one row'
      );
      System.assertEquals(
        'Unrouted',
        captured[0].Status__c,
        'Captured signal must have Unrouted status'
      );
      System.assertEquals('WakeUp', captured[0].Signal_Name__c);
      System.assertEquals('{"x":1}', captured[0].Payload__c);
      System.assertEquals(
        null,
        captured[0].Workflow_Instance__c,
        'Unrouted signal must have no parent instance'
      );

      List<Workflow_Step_Execution__c> steps = [
        SELECT Id
        FROM Workflow_Step_Execution__c
      ];
      System.assertEquals(
        0,
        steps.size(),
        'Signal capture must never write step-execution rows'
      );
    }
  }

  @IsTest
  static void testUnroutedSignalCapturedBulkMethod() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;

      List<WorkflowEngine.SignalRequest> reqs = new List<WorkflowEngine.SignalRequest>{
        new WorkflowEngine.SignalRequest('BulkKey-A', 'Ping', null),
        new WorkflowEngine.SignalRequest('BulkKey-B', 'Pong', '{"y":2}')
      };

      Test.startTest();
      WorkflowEngine.signal(reqs);
      Test.stopTest();

      List<Workflow_Signal__c> captured = [
        SELECT Id, Status__c, Correlation_Key__c, Signal_Name__c
        FROM Workflow_Signal__c
        WHERE Correlation_Key__c IN ('BulkKey-A', 'BulkKey-B')
        ORDER BY Correlation_Key__c ASC
      ];
      System.assertEquals(
        2,
        captured.size(),
        'Both unmatched bulk signals must be captured'
      );
      System.assertEquals('Unrouted', captured[0].Status__c);
      System.assertEquals('Unrouted', captured[1].Status__c);
      System.assertEquals('BulkKey-A', captured[0].Correlation_Key__c);
      System.assertEquals('BulkKey-B', captured[1].Correlation_Key__c);
    }
  }

  @IsTest
  static void testUnroutedSignalIdempotentSameDedupKey() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // The same signal delivered N times with the same dedupKey must produce
      // exactly one Unrouted row (at-least-once idempotency).
      WorkflowEngine.disableQueueableInTest = true;

      String dedupKey = 'idempotency-test-uuid-001';

      Test.startTest();
      WorkflowEngine.signal(
        new List<WorkflowEngine.SignalRequest>{
          new WorkflowEngine.SignalRequest('IdempKey', 'Arrive', '{"n":1}')
            .withDedupKey(dedupKey)
        }
      );
      WorkflowEngine.signal(
        new List<WorkflowEngine.SignalRequest>{
          new WorkflowEngine.SignalRequest('IdempKey', 'Arrive', '{"n":1}')
            .withDedupKey(dedupKey)
        }
      );
      WorkflowEngine.signal(
        new List<WorkflowEngine.SignalRequest>{
          new WorkflowEngine.SignalRequest('IdempKey', 'Arrive', '{"n":1}')
            .withDedupKey(dedupKey)
        }
      );
      Test.stopTest();

      List<Workflow_Signal__c> captured = [
        SELECT Id, Signal_Key__c
        FROM Workflow_Signal__c
        WHERE Correlation_Key__c = 'IdempKey'
      ];
      System.assertEquals(
        1,
        captured.size(),
        'N deliveries with the same dedupKey must produce exactly one captured row'
      );
      System.assertEquals(dedupKey, captured[0].Signal_Key__c);
    }
  }

  @IsTest
  static void testRedeliverCapturedSignalWakesInstance() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Re-delivering a captured signal to a now-waiting instance must wake it
      // and transition the captured row to Received with the instance FK set.
      WorkflowEngine.disableQueueableInTest = true;

      Workflow_Signal__c sig = new Workflow_Signal__c(
        Correlation_Key__c = 'Redeliver-Key',
        Signal_Name__c = 'WakeMe',
        Payload__c = null,
        Status__c = 'Unrouted'
      );
      insert sig;

      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
        Status__c = 'Suspended',
        Correlation_Key__c = 'Redeliver-Key'
      );
      insert inst;

      Test.startTest();
      Boolean matched = WorkflowUnroutedSignals.redeliverCapturedSignal(sig.Id);
      Test.stopTest();

      System.assertEquals(
        true,
        matched,
        'Re-delivery must return true when a match is found'
      );

      Workflow_Signal__c reloaded = [
        SELECT Id, Status__c, Workflow_Instance__c
        FROM Workflow_Signal__c
        WHERE Id = :sig.Id
      ];
      System.assertEquals(
        'Received',
        reloaded.Status__c,
        'Re-delivered signal must have Received status'
      );
      System.assertEquals(
        inst.Id,
        reloaded.Workflow_Instance__c,
        'Re-delivered signal must be parented to the matched instance'
      );

      Workflow_Instance__c reloadedInst = [
        SELECT Status__c
        FROM Workflow_Instance__c
        WHERE Id = :inst.Id
      ];
      System.assertEquals(
        'Running',
        reloadedInst.Status__c,
        'Suspended instance must be set to Running on re-delivery'
      );
    }
  }

  @IsTest
  static void testRedeliverCapturedSignalNoopWhenUnmatched() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;

      Workflow_Signal__c sig = new Workflow_Signal__c(
        Correlation_Key__c = 'Still-No-Match',
        Signal_Name__c = 'Orphan',
        Payload__c = null,
        Status__c = 'Unrouted'
      );
      insert sig;

      Test.startTest();
      Boolean matched = WorkflowUnroutedSignals.redeliverCapturedSignal(sig.Id);
      Test.stopTest();

      System.assertEquals(
        false,
        matched,
        'Re-delivery must return false when no active instance exists'
      );

      Workflow_Signal__c reloaded = [
        SELECT Status__c, Workflow_Instance__c
        FROM Workflow_Signal__c
        WHERE Id = :sig.Id
      ];
      System.assertEquals(
        'Unrouted',
        reloaded.Status__c,
        'Unmatched re-delivery must leave the row Unrouted'
      );
      System.assertEquals(null, reloaded.Workflow_Instance__c);
    }
  }

  @IsTest
  static void testUnroutedCancelSignalStillThrows() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // An unmatched Cancel signal must NOT be captured — it must still throw,
      // since re-delivering a cancel to a future instance would be incorrect.
      WorkflowEngine.disableQueueableInTest = true;

      Boolean threw = false;
      Test.startTest();
      try {
        WorkflowEngine.signal('NonExistentCancel', 'CancelWorkflow', null);
      } catch (WorkflowEngine.WorkflowException ex) {
        threw = true;
      }
      Test.stopTest();

      System.assert(
        threw,
        'An unmatched Cancel signal must still throw, not be captured'
      );

      List<Workflow_Signal__c> captured = [
        SELECT Id
        FROM Workflow_Signal__c
        WHERE Correlation_Key__c = 'NonExistentCancel'
      ];
      System.assertEquals(
        0,
        captured.size(),
        'No Unrouted row must be created for an unmatched Cancel'
      );
    }
  }

  @IsTest
  static void testMatchedSignalBehaviorUnchanged() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Signals that DO match an active instance must still follow the existing
      // path: Received status, parent FK set, instance woken — no regression.
      WorkflowEngine.disableQueueableInTest = true;

      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
        Status__c = 'Suspended',
        Correlation_Key__c = 'MatchedSignalKey'
      );
      insert inst;

      Test.startTest();
      WorkflowEngine.signal('MatchedSignalKey', 'Resume', '{"data":"go"}');
      Test.stopTest();

      List<Workflow_Signal__c> signals = [
        SELECT Status__c, Workflow_Instance__c, Signal_Name__c
        FROM Workflow_Signal__c
        WHERE Workflow_Instance__c = :inst.Id
      ];
      System.assertEquals(
        1,
        signals.size(),
        'Matched signal must produce exactly one Workflow_Signal__c row'
      );
      System.assertEquals(
        'Received',
        signals[0].Status__c,
        'Matched signal must have Received status (not Unrouted)'
      );
      System.assertEquals(inst.Id, signals[0].Workflow_Instance__c);

      Workflow_Instance__c reloaded = [
        SELECT Status__c
        FROM Workflow_Instance__c
        WHERE Id = :inst.Id
      ];
      System.assertEquals(
        'Running',
        reloaded.Status__c,
        'Matched suspended instance must be woken to Running'
      );

      List<Workflow_Step_Execution__c> steps = [
        SELECT Id
        FROM Workflow_Step_Execution__c
      ];
      System.assertEquals(
        0,
        steps.size(),
        'Signal delivery must not write step-execution rows'
      );
    }
  }

  @IsTest
  static void testWorkflowValidatorReportsMalformedDag() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // A deliberately malformed definition is reported with every structural
      // defect, and a well-formed one (HappyWorkflow) passes clean.
      WorkflowValidator.ValidationResult bad = WorkflowValidator.validate(
        'WorkflowEngineMocksATest.MalformedValidatorWorkflow'
      );
      System.assertEquals(
        false,
        bad.isValid(),
        'Malformed DAG must be invalid'
      );
      System.assert(
        bad.hasDefect(WorkflowValidator.INITIAL_STEP_NOT_DECLARED),
        'bad initial step not reported: ' + bad.getMessages()
      );
      System.assert(
        bad.hasDefect(WorkflowValidator.STEP_NOT_WORKFLOWSTEP),
        'non-WorkflowStep class not reported: ' + bad.getMessages()
      );
      System.assert(
        bad.hasDefect(WorkflowValidator.DANGLING_SUCCESSOR),
        'dangling successor not reported: ' + bad.getMessages()
      );

      WorkflowValidator.ValidationResult good = WorkflowValidator.validate(
        'WorkflowEngineTest.HappyWorkflow'
      );
      System.assertEquals(
        true,
        good.isValid(),
        'Well-formed HappyWorkflow should pass clean: ' + good.getMessages()
      );
    }
  }

  @IsTest
  static void testTimedSuspendTimeoutWins() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      WorkflowEngineMocksATest.capturedIsTimeoutResume = null;

      Id instanceId = WorkflowEngine.start(
        'WorkflowEngineTest.TimedSuspendWorkflow',
        'TimedSuspendKey',
        null
      );
      new WorkflowOrchestrator(instanceId).execute(null);

      // Assert the timed suspend armed the timer
      Workflow_Instance__c inst = [
        SELECT Status__c, Current_Step__c, Sleep_Until__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      System.assertEquals('Suspended', inst.Status__c, 'Should be Suspended');
      System.assertEquals(
        'WorkflowEngineTest.TimedSuspendStep',
        inst.Current_Step__c
      );
      System.assertNotEquals(
        null,
        inst.Sleep_Until__c,
        'Timer should be armed'
      );

      // Capture the wait step exec id and assert $timeoutStep is persisted
      Workflow_Step_Execution__c waitExec = [
        SELECT Id, Status__c, Output__c
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Step_Name__c = 'WorkflowEngineTest.TimedSuspendStep'
        LIMIT 1
      ];
      System.assertEquals('Pending', waitExec.Status__c);
      System.assert(
        waitExec.Output__c != null &&
          waitExec.Output__c.contains('"$timeoutStep"') &&
          waitExec.Output__c.contains('WorkflowEngineTest.TimeoutFallbackStep'),
        'Output should contain $timeoutStep: ' + waitExec.Output__c
      );
      Id waitExecId = waitExec.Id;
      String waitExecOutput = waitExec.Output__c;

      // Simulate the deadline firing
      inst.Sleep_Until__c = DateTime.now().addSeconds(-10);
      update as system inst;

      // Run the watchdog
      WorkflowEngine.processWatchdogHeartbeat();

      // Assert routing: Current_Step__c advanced to the fallback
      inst = [
        SELECT Status__c, Current_Step__c, Sleep_Until__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      System.assertEquals(
        'Running',
        inst.Status__c,
        'Should be Running after timeout'
      );
      System.assertEquals(
        'WorkflowEngineTest.TimeoutFallbackStep',
        inst.Current_Step__c,
        'Should route to timeout fallback step'
      );
      System.assertEquals(
        null,
        inst.Sleep_Until__c,
        'Timer should be disarmed'
      );

      // Assert a NEW Pending step exec was created for the fallback
      List<Workflow_Step_Execution__c> fallbackExecs = [
        SELECT Id, Status__c, Input__c
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Step_Name__c = 'WorkflowEngineTest.TimeoutFallbackStep'
      ];
      System.assertEquals(
        1,
        fallbackExecs.size(),
        'Should have exactly one fallback exec'
      );
      System.assertEquals('Pending', fallbackExecs[0].Status__c);

      // Assert the original wait exec is UNMUTATED (append-only)
      Workflow_Step_Execution__c unchangedWaitExec = [
        SELECT Id, Status__c, Output__c
        FROM Workflow_Step_Execution__c
        WHERE Id = :waitExecId
      ];
      System.assertEquals(
        'Pending',
        unchangedWaitExec.Status__c,
        'Wait exec must remain Pending (append-only)'
      );
      System.assertEquals(
        waitExecOutput,
        unchangedWaitExec.Output__c,
        'Wait exec Output must be unmutated'
      );

      // Run the fallback step
      new WorkflowOrchestrator(instanceId).execute(null);

      inst = [
        SELECT Status__c, Output__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      System.assertEquals('Completed', inst.Status__c);
      System.assertEquals('"timedout"', inst.Output__c);

      // Assert isTimeoutResume() was true in the fallback step
      System.assertEquals(
        true,
        WorkflowEngineMocksATest.capturedIsTimeoutResume,
        'isTimeoutResume() must be true in the fallback step'
      );

      // Assert $timeoutResume was stripped from ctx.inputJson (not visible to step author)
      Workflow_Step_Execution__c fallbackExec = [
        SELECT Input__c
        FROM Workflow_Step_Execution__c
        WHERE Id = :fallbackExecs[0].Id
      ];
      System.assert(
        fallbackExec.Input__c == null ||
        !fallbackExec.Input__c.contains('$timeoutResume'),
        'Engine marker $timeoutResume should not be visible in stored Input: ' +
        fallbackExec.Input__c
      );
    }
  }

  @IsTest
  static void testTimedSuspendSignalWins() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;

      Id instanceId = WorkflowEngine.start(
        'WorkflowEngineTest.TimedSuspendWorkflow',
        'TimedSuspendSignalKey',
        null
      );
      new WorkflowOrchestrator(instanceId).execute(null);

      // Verify timer was armed
      Workflow_Instance__c inst = [
        SELECT Status__c, Sleep_Until__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      System.assertEquals('Suspended', inst.Status__c);
      System.assertNotEquals(
        null,
        inst.Sleep_Until__c,
        'Timer should be armed'
      );

      // Send the winning signal (single-instance signal path)
      WorkflowEngine.signal('TimedSuspendSignalKey', 'Resume', '{}');

      // Assert signal disarmed the timer
      inst = [
        SELECT Status__c, Sleep_Until__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      System.assertEquals(
        'Running',
        inst.Status__c,
        'Should be Running after signal'
      );
      System.assertEquals(
        null,
        inst.Sleep_Until__c,
        'Signal win must disarm the timer (Sleep_Until__c must be null)'
      );

      // Run the resumed step
      new WorkflowOrchestrator(instanceId).execute(null);

      // Assert advanced to AfterTimedSignalStep and completed
      new WorkflowOrchestrator(instanceId).execute(null);

      inst = [
        SELECT Status__c, Output__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      System.assertEquals('Completed', inst.Status__c);
      System.assertEquals('"signaled"', inst.Output__c);

      // Assert no fallback step exec was ever created
      List<Workflow_Step_Execution__c> fallbackExecs = [
        SELECT Id
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Step_Name__c = 'WorkflowEngineTest.TimeoutFallbackStep'
      ];
      System.assertEquals(
        0,
        fallbackExecs.size(),
        'No fallback exec should exist when signal wins'
      );

      // Run the watchdog — confirm it does NOT mis-route (timer is cleared)
      WorkflowEngine.processWatchdogHeartbeat();

      List<Workflow_Step_Execution__c> fallbackExecsAfterWatchdog = [
        SELECT Id
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Step_Name__c = 'WorkflowEngineTest.TimeoutFallbackStep'
      ];
      System.assertEquals(
        0,
        fallbackExecsAfterWatchdog.size(),
        'Watchdog must not create fallback exec after signal wins'
      );
    }
  }

  @IsTest
  static void testTimedSuspendLateSignalAfterTimeoutIsNoOp() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      WorkflowEngineMocksATest.capturedIsTimeoutResume = null;

      Id instanceId = WorkflowEngine.start(
        'WorkflowEngineTest.TimedSuspendWorkflow',
        'TimedSuspendLateKey',
        null
      );
      new WorkflowOrchestrator(instanceId).execute(null);

      // Force timeout to fire
      Workflow_Instance__c inst = [
        SELECT Id, Sleep_Until__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      inst.Sleep_Until__c = DateTime.now().addSeconds(-10);
      update as system inst;
      WorkflowEngine.processWatchdogHeartbeat();

      // Run the fallback step to terminal
      new WorkflowOrchestrator(instanceId).execute(null);

      inst = [
        SELECT Status__c, Output__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      System.assertEquals('Completed', inst.Status__c);
      System.assertEquals('"timedout"', inst.Output__c);

      // Deliver the late signal — should be a no-op (captured as Unrouted)
      WorkflowEngine.signal('TimedSuspendLateKey', 'Resume', '{}');

      // Instance must not change
      inst = [
        SELECT Status__c, Output__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      System.assertEquals(
        'Completed',
        inst.Status__c,
        'Instance must stay Completed after late signal'
      );
      System.assertEquals('"timedout"', inst.Output__c);

      // The late signal is captured as Unrouted. An Unrouted capture has no active
      // instance to link to, so it is keyed by Correlation_Key__c with a null
      // Workflow_Instance__c — query by the correlation key, not the instance id.
      List<Workflow_Signal__c> unroutedSignals = [
        SELECT Status__c
        FROM Workflow_Signal__c
        WHERE
          Correlation_Key__c = 'TimedSuspendLateKey'
          AND Signal_Name__c = 'Resume'
          AND Status__c = 'Unrouted'
      ];
      System.assertEquals(
        1,
        unroutedSignals.size(),
        'Late signal should be captured as Unrouted'
      );
    }
  }

  @IsTest
  static void testTimedWaitBackCompatUntimedOverloadsUnchanged() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;

      // Untimed suspend should leave Sleep_Until__c null
      Id instanceId = WorkflowEngine.start(
        'WorkflowEngineTest.SuspendingWorkflow',
        'BackCompatSuspendKey',
        null
      );
      new WorkflowOrchestrator(instanceId).execute(null);

      Workflow_Instance__c inst = [
        SELECT Status__c, Sleep_Until__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      System.assertEquals('Suspended', inst.Status__c);
      System.assertEquals(
        null,
        inst.Sleep_Until__c,
        'Untimed suspend must NOT arm a timer'
      );

      // Untimed waitForApproval should leave Sleep_Until__c null
      Id approvalInstanceId = WorkflowEngine.start(
        'WorkflowEngineMocksATest.ApprovalWorkflow',
        'BackCompatApprovalKey',
        null
      );
      new WorkflowOrchestrator(approvalInstanceId).execute(null);

      Workflow_Instance__c approvalInst = [
        SELECT Status__c, Sleep_Until__c
        FROM Workflow_Instance__c
        WHERE Id = :approvalInstanceId
      ];
      System.assertEquals('Suspended', approvalInst.Status__c);
      System.assertEquals(
        null,
        approvalInst.Sleep_Until__c,
        'Untimed waitForApproval must NOT arm a timer'
      );
    }
  }

  @IsTest
  static void testTimedApprovalTimeoutWins() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;

      Id instanceId = WorkflowEngine.start(
        'WorkflowEngineMocksBTest.TimedApprovalWorkflow',
        'TimedApprovalKey',
        null
      );
      new WorkflowOrchestrator(instanceId).execute(null);

      Workflow_Instance__c inst = [
        SELECT Status__c, Current_Step__c, Sleep_Until__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      System.assertEquals('Suspended', inst.Status__c);
      System.assertNotEquals(
        null,
        inst.Sleep_Until__c,
        'Timed approval should arm a timer'
      );

      // Verify approval state JSON includes both existing keys and $timeoutStep
      Workflow_Step_Execution__c waitExec = [
        SELECT Status__c, Output__c
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Step_Name__c = 'WorkflowEngineMocksATest.TimedApprovalStep'
        LIMIT 1
      ];
      System.assertEquals('Pending', waitExec.Status__c);
      System.assert(
        waitExec.Output__c.contains('"waitingForApproval":true'),
        'Should retain waitingForApproval key'
      );
      System.assert(
        waitExec.Output__c.contains('"approvalKey":"TimedApproval"'),
        'Should retain approvalKey'
      );
      System.assert(
        waitExec.Output__c.contains('"approvalRole":"Manager"'),
        'Should retain approvalRole'
      );
      System.assert(
        waitExec.Output__c.contains('"$timeoutStep"') &&
        waitExec.Output__c.contains(
          'WorkflowEngineMocksBTest.ApprovalTimeoutFallbackStep'
        ),
        'Should contain $timeoutStep: ' + waitExec.Output__c
      );

      // Fire the deadline
      inst.Sleep_Until__c = DateTime.now().addSeconds(-10);
      update as system inst;
      WorkflowEngine.processWatchdogHeartbeat();

      inst = [
        SELECT Status__c, Current_Step__c, Sleep_Until__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      System.assertEquals('Running', inst.Status__c);
      System.assertEquals(
        'WorkflowEngineMocksBTest.ApprovalTimeoutFallbackStep',
        inst.Current_Step__c
      );
      System.assertEquals(null, inst.Sleep_Until__c);

      // Run the fallback step to completion
      new WorkflowOrchestrator(instanceId).execute(null);

      inst = [
        SELECT Status__c, Output__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      System.assertEquals('Completed', inst.Status__c);
      System.assertEquals('"approval_timedout"', inst.Output__c);
    }
  }

  @IsTest
  static void testTimedSuspendManualResumeDisarmsTimer() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // A manual resumeInstance() of an armed timed-wait must disarm Sleep_Until__c
      // (issue #35) so the watchdog does not later mis-route to the fallback step.
      WorkflowEngine.disableQueueableInTest = true;

      Id instanceId = WorkflowEngine.start(
        'WorkflowEngineTest.TimedSuspendWorkflow',
        'TimedSuspendResumeKey',
        null
      );
      new WorkflowOrchestrator(instanceId).execute(null);

      // Timer is armed by the timed suspend
      Workflow_Instance__c inst = [
        SELECT Status__c, Sleep_Until__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      System.assertEquals('Suspended', inst.Status__c);
      System.assertNotEquals(
        null,
        inst.Sleep_Until__c,
        'Timer should be armed'
      );

      // Manual resume (not via signal) must disarm the timer
      WorkflowResumeService.resumeInstance(instanceId, '{}');

      inst = [
        SELECT Status__c, Sleep_Until__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      System.assertEquals(
        'Running',
        inst.Status__c,
        'Should be Running after resume'
      );
      System.assertEquals(
        null,
        inst.Sleep_Until__c,
        'Manual resume must disarm the timed-wait timer (Sleep_Until__c must be null)'
      );

      // Watchdog must not mis-route to the fallback after a manual resume disarm
      WorkflowEngine.processWatchdogHeartbeat();
      List<Workflow_Step_Execution__c> fallbackExecs = [
        SELECT Id
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Step_Name__c = 'WorkflowEngineTest.TimeoutFallbackStep'
      ];
      System.assertEquals(
        0,
        fallbackExecs.size(),
        'Watchdog must not create a fallback exec after a manual resume wins'
      );
    }
  }

  @IsTest
  static void testManualCompensationValidation() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // 1. Create a non-completed instance and check it fails validation
      Workflow_Instance__c inst1 = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
        Status__c = 'Running'
      );
      insert inst1;

      try {
        WorkflowCompensation.compensate(inst1.Id);
        System.assert(
          false,
          'Should have thrown exception for non-completed status'
        );
      } catch (Exception ex) {
        System.assert(
          ex.getMessage().contains('Only Completed'),
          'Expected "Only Completed" error message: ' + ex.getMessage()
        );
      }

      // 2. Create a completed instance without compensation stack
      Workflow_Instance__c inst2 = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
        Status__c = 'Completed',
        Compensation_Stack__c = null
      );
      insert inst2;

      try {
        WorkflowCompensation.compensate(inst2.Id);
        System.assert(false, 'Should have thrown exception for missing stack');
      } catch (Exception ex) {
        System.assert(
          ex.getMessage().contains('No compensation stack found'),
          'Expected "No compensation stack found" error message: ' +
          ex.getMessage()
        );
      }
    }
  }

  @IsTest
  static void testManualCompensationHappyPath() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;

      // Create a target Completed workflow instance with compensation stack
      Workflow_Instance__c target = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
        Status__c = 'Completed',
        Compensation_Stack__c = JSON.serialize(
          new List<String>{
            'WorkflowEngineTest.NonCompensatableStep',
            'WorkflowEngineTest.CompensatableHappyStep'
          }
        ),
        Correlation_Key__c = 'TestKey_Comp',
        Input__c = '{"key": "val"}'
      );
      insert target;

      // Create the original completed step execution for the compensatable step so the compensation context can resolve it
      Workflow_Step_Execution__c origExec = new Workflow_Step_Execution__c(
        Workflow_Instance__c = target.Id,
        Step_Name__c = 'WorkflowEngineTest.CompensatableHappyStep',
        Status__c = 'Completed',
        Input__c = '{"stepInput": 1}',
        Output__c = '{"stepOutput": 2}'
      );
      insert origExec;

      Test.startTest();
      Id compensatingId = WorkflowCompensation.compensate(target.Id);
      Test.stopTest();

      System.assertNotEquals(
        null,
        compensatingId,
        'Compensating run ID should be returned'
      );

      // Verify original target instance is linked to the new compensating instance
      Workflow_Instance__c targetReload = [
        SELECT Compensated_By__c, Status__c
        FROM Workflow_Instance__c
        WHERE Id = :target.Id
      ];
      System.assertEquals(
        compensatingId,
        targetReload.Compensated_By__c,
        'Compensated_By__c should link to compensating run'
      );
      System.assertEquals(
        'Completed',
        targetReload.Status__c,
        'Original instance status must stay Completed'
      );

      // Verify the new compensating instance details
      Workflow_Instance__c compInst = [
        SELECT
          Status__c,
          Previous_Instance__c,
          Correlation_Key__c,
          Root_Correlation_Key__c,
          Compensation_Stack__c
        FROM Workflow_Instance__c
        WHERE Id = :compensatingId
      ];
      System.assertEquals(
        'Compensating',
        compInst.Status__c,
        'New run status must start as Compensating'
      );
      System.assertEquals(
        target.Id,
        compInst.Previous_Instance__c,
        'Previous_Instance__c should link to the original target run'
      );
      System.assertEquals(
        target.Correlation_Key__c,
        compInst.Correlation_Key__c,
        'Correlation key should carry forward'
      );
      System.assertEquals(
        target.Correlation_Key__c,
        compInst.Root_Correlation_Key__c,
        'Root correlation key should carry forward'
      );
      System.assertEquals(
        target.Compensation_Stack__c,
        compInst.Compensation_Stack__c,
        'Compensation stack should be copied'
      );

      // Drive the compensation execution
      WorkflowEngine.runStep(compensatingId, null); // Runs CompensatableHappyStep
      WorkflowEngine.runStep(compensatingId, null); // Runs NonCompensatableStep (skipped)
      WorkflowEngine.runStep(compensatingId, null); // Stack empty -> transition status to Compensated

      compInst = [
        SELECT Status__c
        FROM Workflow_Instance__c
        WHERE Id = :compensatingId
      ];
      System.assertEquals(
        'Compensated',
        compInst.Status__c,
        'Spawned compensating run should end in Compensated status'
      );

      List<Workflow_Step_Execution__c> stepExecs = [
        SELECT Step_Name__c, Status__c, Output__c
        FROM Workflow_Step_Execution__c
        WHERE Workflow_Instance__c = :compensatingId
        ORDER BY CreatedDate ASC, Id ASC
      ];
      System.assertEquals(
        2,
        stepExecs.size(),
        'Should have created step execution logs on compensating run'
      );
      System.assertEquals(
        'WorkflowEngineTest.CompensatableHappyStep_Compensate',
        stepExecs[0].Step_Name__c
      );
      System.assertEquals('Compensated', stepExecs[0].Status__c);
      System.assertEquals('"Compensated"', stepExecs[0].Output__c);
    }
  }

  @IsTest
  static void testManualCompensationLineageAndParentIsolation() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;

      // 1. Start Parent
      Id parentId = WorkflowEngine.start(
        'WorkflowEngineMocksATest.ParentWorkflow',
        'ParentKey',
        null
      );

      // Execute ParentStep once to spawn child and suspend parent
      new WorkflowOrchestrator(parentId).execute(null);

      // Find the spawned child
      Workflow_Instance__c child = [
        SELECT
          Id,
          Status__c,
          Parent_Instance__c,
          Correlation_Key__c,
          Causation_Id__c
        FROM Workflow_Instance__c
        WHERE Parent_Instance__c = :parentId
        LIMIT 1
      ];
      Id childId = child.Id;

      System.assertEquals('Pending', child.Status__c);
      System.assertEquals(parentId, child.Parent_Instance__c);
      System.assertEquals(parentId, child.Causation_Id__c);

      // Complete the Child by running it
      new WorkflowOrchestrator(childId).execute(null);

      // Verify Child completed
      child = [
        SELECT Status__c, Compensation_Stack__c, Correlation_Key__c
        FROM Workflow_Instance__c
        WHERE Id = :childId
      ];
      System.assertEquals('Completed', child.Status__c);

      // Manually stamp compensation stack on completed child so it can be compensated
      child.Compensation_Stack__c = JSON.serialize(
        new List<String>{ 'WorkflowEngineTest.CompensatableHappyStep' }
      );
      update child;

      // Set up a mock completed step execution so compensation has something to run
      Workflow_Step_Execution__c origExec = new Workflow_Step_Execution__c(
        Workflow_Instance__c = childId,
        Step_Name__c = 'WorkflowEngineTest.CompensatableHappyStep',
        Status__c = 'Completed',
        Input__c = '"Input"',
        Output__c = '"Output"'
      );
      insert origExec;

      // 3. Compensate the completed child
      Id compensatingId = WorkflowCompensation.compensate(childId);
      System.assertNotEquals(null, compensatingId);

      // Verify the compensating run has NO Parent_Instance__c but DOES have Causation_Id__c!
      Workflow_Instance__c compInst = [
        SELECT Status__c, Parent_Instance__c, Causation_Id__c
        FROM Workflow_Instance__c
        WHERE Id = :compensatingId
      ];
      System.assertEquals(
        null,
        compInst.Parent_Instance__c,
        'Must NOT set Parent_Instance__c on manual compensation run'
      );
      System.assertEquals(
        parentId,
        compInst.Causation_Id__c,
        'Must preserve Causation_Id__c'
      );

      // Verify lineage walk from the compensating run successfully reaches the parent
      List<WorkflowEngine.WorkflowStatus> lineage = WorkflowCausationLineage.getCausationLineage(
        compensatingId
      );
      System.assertEquals(2, lineage.size());
      System.assertEquals(compensatingId, lineage[0].instanceId);
      System.assertEquals(parentId, lineage[1].instanceId);

      // Parent is currently Suspended (waiting for child completions). Verify this.
      Workflow_Instance__c parentReload = [
        SELECT Status__c
        FROM Workflow_Instance__c
        WHERE Id = :parentId
      ];
      System.assertEquals('Suspended', parentReload.Status__c);

      // 4. Drive the compensating run to completion
      new WorkflowOrchestrator(compensatingId).execute(null);

      // Verify compensating run is Compensated
      compInst = [
        SELECT Status__c
        FROM Workflow_Instance__c
        WHERE Id = :compensatingId
      ];
      System.assertEquals('Compensated', compInst.Status__c);

      // Verify Parent is STILL Suspended (its state was NOT corrupted/altered by notifications from the compensating run)
      parentReload = [
        SELECT Status__c
        FROM Workflow_Instance__c
        WHERE Id = :parentId
      ];
      System.assertEquals(
        'Suspended',
        parentReload.Status__c,
        'Parent must remain Suspended; compensation run completion must be isolated'
      );
    }
  }

  @IsTest
  static void testScalarStartOrGetHonorsInputJsonWhenInputNull() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Regression: the scalar startOrGet(StartRequest) path must persist the
      // pre-serialized req.inputJson onto the instance's Input__c when the
      // structured req.input is null (mirroring the bulk start path). The scalar
      // doStart previously ignored inputJson on this branch and stored null.
      WorkflowEngine.disableQueueableInTest = true;

      WorkflowEngine.StartRequest req = new WorkflowEngine.StartRequest(
        'WorkflowEngineTest.HappyWorkflow',
        'ScalarInputJsonKey',
        null
      );
      req.inputJson = '{"fromInputJson":true}';

      Test.startTest();
      WorkflowEngine.StartResult res = WorkflowEngine.startOrGet(req);
      Test.stopTest();

      Workflow_Instance__c inst = [
        SELECT Input__c
        FROM Workflow_Instance__c
        WHERE Id = :res.instanceId
      ];
      // Asserts the instance carries the inputJson payload, not null.
      System.assertEquals(
        '{"fromInputJson":true}',
        inst.Input__c,
        'Scalar startOrGet must persist req.inputJson onto Input__c when input is null'
      );
    }
  }

  @IsTest
  static void testScalarUnroutedSignalIdempotentSameDedupKey() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Regression: the scalar signal(SignalRequest) unrouted-capture path must
      // carry req.dedupKey through to the captured Workflow_Signal__c, exactly
      // like the bulk path (see testUnroutedSignalIdempotentSameDedupKey). N
      // deliveries with the same dedupKey to an unmatched key must produce
      // exactly ONE Unrouted row. The scalar path previously dropped dedupKey,
      // so each redelivery captured a duplicate row.
      WorkflowEngine.disableQueueableInTest = true;

      String dedupKey = 'scalar-idempotency-uuid-001';

      Test.startTest();
      WorkflowEngine.signal(
        new WorkflowEngine.SignalRequest('ScalarIdempKey', 'Arrive', '{"n":1}')
          .withDedupKey(dedupKey)
      );
      WorkflowEngine.signal(
        new WorkflowEngine.SignalRequest('ScalarIdempKey', 'Arrive', '{"n":1}')
          .withDedupKey(dedupKey)
      );
      WorkflowEngine.signal(
        new WorkflowEngine.SignalRequest('ScalarIdempKey', 'Arrive', '{"n":1}')
          .withDedupKey(dedupKey)
      );
      Test.stopTest();

      List<Workflow_Signal__c> captured = [
        SELECT Id, Signal_Key__c
        FROM Workflow_Signal__c
        WHERE Correlation_Key__c = 'ScalarIdempKey'
      ];
      // Asserts dedup was honored: exactly one row, keyed by the dedupKey.
      System.assertEquals(
        1,
        captured.size(),
        'N scalar deliveries with the same dedupKey must produce exactly one captured row'
      );
      System.assertEquals(dedupKey, captured[0].Signal_Key__c);
    }
  }
}
