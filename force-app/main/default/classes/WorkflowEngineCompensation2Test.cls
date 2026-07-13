@IsTest
public class WorkflowEngineCompensation2Test {
  @IsTest
  static void testCancelTreeResumesStalledChildRollback() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Cancelling a parent tree with runCompensations=true must reach a stalled
      // (CompensationFailed) child and resume its rollback, draining it to Cancelled.
      WorkflowEngine.disableQueueableInTest = true;

      Workflow_Instance__c parent = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
        Status__c = 'Running',
        Current_Step__c = 'WorkflowEngineTest.HappyStep1',
        Correlation_Key__c = 'ParentCancelKey'
      );
      insert parent;

      Workflow_Instance__c child = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
        Status__c = 'CompensationFailed',
        Parent_Instance__c = parent.Id,
        Correlation_Key__c = 'ChildStalledKey',
        Compensation_Stack__c = JSON.serialize(
          new List<String>{ 'WorkflowEngineTest.CompensatableHappyStep' }
        ),
        Error_Message__c = 'Rollback incomplete: ...'
      );
      insert child;
      // The preserved (failed) compensation attempt that left the child stalled.
      insert new Workflow_Step_Execution__c(
        Workflow_Instance__c = child.Id,
        Step_Name__c = 'WorkflowEngineTest.CompensatableHappyStep_Compensate',
        Status__c = 'Failed'
      );

      Test.startTest();
      WorkflowEngine.cancelWithCompensations(parent.Id);

      // The stalled child must now be resumed under the cancel phase.
      Workflow_Instance__c resumedChild = [
        SELECT Status__c
        FROM Workflow_Instance__c
        WHERE Id = :child.Id
      ];
      System.assertEquals('Cancelling', resumedChild.Status__c);

      // Drive the resumed child rollback to completion.
      WorkflowEngine.runStep(child.Id, null); // compensate succeeds -> stack drains
      Test.stopTest();

      Workflow_Instance__c finalChild = [
        SELECT Status__c
        FROM Workflow_Instance__c
        WHERE Id = :child.Id
      ];
      System.assertEquals(
        'Cancelled',
        finalChild.Status__c,
        'Stalled child rollback should finish as Cancelled when its tree is cancelled'
      );
    }
  }

  @IsTest
  static void testCancelTreeForcesStalledChildTerminalWithoutCompensations() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Cancelling with runCompensations=false must force a stalled child terminal
      // (Cancelled), releasing its correlation key rather than leaving it orphaned.
      WorkflowEngine.disableQueueableInTest = true;

      Workflow_Instance__c parent = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
        Status__c = 'Running',
        Current_Step__c = 'WorkflowEngineTest.HappyStep1',
        Correlation_Key__c = 'ParentCancelKey2'
      );
      insert parent;

      Workflow_Instance__c child = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
        Status__c = 'CompensationFailed',
        Parent_Instance__c = parent.Id,
        Correlation_Key__c = 'ChildStalledKey2',
        Compensation_Stack__c = JSON.serialize(
          new List<String>{ 'WorkflowEngineTest.CompensatableHappyStep' }
        ),
        Error_Message__c = 'Rollback incomplete: ...'
      );
      insert child;

      Test.startTest();
      WorkflowEngine.cancel(parent.Id);
      Test.stopTest();

      Workflow_Instance__c finalChild = [
        SELECT Status__c, Active_Correlation_Key__c
        FROM Workflow_Instance__c
        WHERE Id = :child.Id
      ];
      System.assertEquals(
        'Cancelled',
        finalChild.Status__c,
        'Stalled child should be forced terminal when cancelling without compensations'
      );
      System.assertEquals(
        null,
        finalChild.Active_Correlation_Key__c,
        'A terminal Cancelled child must release its reserved correlation key'
      );
    }
  }

  @IsTest
  static void testCancelSignalReachesStalledRollback() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // A Cancel signal must reach a stalled rollback (CompensationFailed); a non-cancel
      // signal to the same instance must still be rejected as "no active workflow".
      WorkflowEngine.disableQueueableInTest = true;

      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
        Status__c = 'CompensationFailed',
        Correlation_Key__c = 'SignalStalledKey',
        Compensation_Stack__c = JSON.serialize(
          new List<String>{ 'WorkflowEngineTest.CompensatableHappyStep' }
        ),
        Error_Message__c = 'Rollback incomplete: ...'
      );
      insert inst;

      Test.startTest();
      // A non-cancel signal to a stalled (CompensationFailed) instance must be
      // captured as Unrouted rather than thrown — the rollback is not an active
      // forward-signal target, but the signal is preserved for later re-delivery.
      WorkflowEngine.signal('SignalStalledKey', 'SomethingElse', null);
      List<Workflow_Signal__c> captured = [
        SELECT Status__c, Correlation_Key__c
        FROM Workflow_Signal__c
        WHERE Correlation_Key__c = 'SignalStalledKey'
      ];
      System.assertEquals(
        1,
        captured.size(),
        'Non-cancel signal to a stalled rollback must be captured as Unrouted'
      );
      System.assertEquals('Unrouted', captured[0].Status__c);

      // A Cancel signal (without compensations) must reach it and force it terminal.
      WorkflowEngine.signal(
        'SignalStalledKey',
        'CancelWorkflow',
        '{"runCompensations":false}'
      );
      Test.stopTest();

      Workflow_Instance__c cancelled = [
        SELECT Status__c
        FROM Workflow_Instance__c
        WHERE Id = :inst.Id
      ];
      System.assertEquals(
        'Cancelled',
        cancelled.Status__c,
        'A Cancel signal must drive a stalled rollback to a terminal state'
      );
    }
  }

  @IsTest
  static void testFailureRollbackErrorContainingCancelledStillCompensates() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // A failure-driven rollback whose compensation error text merely contains the word
      // "Cancelled" must NOT be mistaken for a user cancellation on resume: it must finish
      // 'Compensated', not 'Cancelled'.
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
        Status__c = 'Compensating',
        Compensation_Stack__c = JSON.serialize(
          new List<String>{
            'WorkflowEngineMocksBTest.CompensatableCancelWordStep'
          }
        ),
        Input__c = '{"test": true}'
      );
      insert inst;

      WorkflowEngineMocksATest.cancelWordCompensationShouldFail = true;

      Test.startTest();
      WorkflowEngine.runStep(inst.Id, null); // compensate throws -> stalls

      Workflow_Instance__c stalled = [
        SELECT Status__c, Error_Message__c
        FROM Workflow_Instance__c
        WHERE Id = :inst.Id
      ];
      System.assertEquals('CompensationFailed', stalled.Status__c);
      // The error text contains "Cancelled" but not the engine-owned cancel marker.
      System.assert(
        stalled.Error_Message__c.contains('Cancelled'),
        'Sanity: stalled error contains the word Cancelled'
      );
      System.assert(
        !stalled.Error_Message__c.contains('Cancelled by user'),
        'This is a failure-driven rollback, not a user cancellation'
      );

      WorkflowEngineMocksATest.cancelWordCompensationShouldFail = false;
      WorkflowEngine.resumeCompensation(inst.Id);

      Workflow_Instance__c resumed = [
        SELECT Status__c
        FROM Workflow_Instance__c
        WHERE Id = :inst.Id
      ];
      System.assertEquals(
        'Compensating',
        resumed.Status__c,
        'Resume must treat this as a compensation, not a cancellation'
      );

      WorkflowEngine.runStep(inst.Id, null); // compensate succeeds -> stack drains
      Test.stopTest();

      Workflow_Instance__c finalInst = [
        SELECT Status__c
        FROM Workflow_Instance__c
        WHERE Id = :inst.Id
      ];
      System.assertEquals(
        'Compensated',
        finalInst.Status__c,
        'A failure-driven rollback must finish Compensated even when its error text contains "Cancelled"'
      );
    }
  }

  @IsTest
  static void testResumeSeedsFromCompensationCheckpoint() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // A resumed rollback must continue from the failed compensation's saved checkpoint
      // (YIELD progress stored in its Output__c) rather than restarting from the forward
      // execution output, so partial rollback work is not re-run.
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
        Status__c = 'CompensationFailed',
        Compensation_Stack__c = JSON.serialize(
          new List<String>{ 'WorkflowEngineTest.CompensatableHappyStep' }
        ),
        Error_Message__c = 'Rollback incomplete: ...'
      );
      insert inst;
      // Forward execution output = the initial undo context.
      insert new Workflow_Step_Execution__c(
        Workflow_Instance__c = inst.Id,
        Step_Name__c = 'WorkflowEngineTest.CompensatableHappyStep',
        Status__c = 'Completed',
        Output__c = '{"forward":"output"}'
      );
      // A failed compensation attempt that had checkpointed progress via YIELD.
      insert new Workflow_Step_Execution__c(
        Workflow_Instance__c = inst.Id,
        Step_Name__c = 'WorkflowEngineTest.CompensatableHappyStep_Compensate',
        Status__c = 'Failed',
        Output__c = '{"checkpoint":"progress"}'
      );

      Test.startTest();
      WorkflowEngine.resumeCompensation(inst.Id);
      Test.stopTest();

      List<Workflow_Step_Execution__c> attempts = [
        SELECT Status__c, Output__c
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :inst.Id
          AND Step_Name__c = 'WorkflowEngineTest.CompensatableHappyStep_Compensate'
        ORDER BY CreatedDate ASC, Id ASC
      ];
      System.assertEquals(
        2,
        attempts.size(),
        'A fresh attempt is appended alongside the preserved failed one'
      );
      Workflow_Step_Execution__c fresh = attempts[attempts.size() - 1];
      System.assertEquals('Pending', fresh.Status__c);
      System.assert(
        fresh.Output__c != null && fresh.Output__c.contains('checkpoint'),
        'Resume attempt must be seeded from the compensation checkpoint, got: ' +
        fresh.Output__c
      );
    }
  }

  @IsTest
  static void testCrashCreatedCompensationRowSeededFromOwnForwardStep() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // A finalizer crash that has to CREATE the top-of-stack compensation log must seed it
      // from that step's own forward execution, not the latest completed step overall (which,
      // after earlier compensations popped, belongs to an already-reversed step).
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
        Status__c = 'Compensating',
        Current_Step__c = 'WorkflowEngineTest.HappyStep1',
        Compensation_Stack__c = JSON.serialize(
          new List<String>{ 'WorkflowEngineTest.CompensatableHappyStep' }
        ),
        Input__c = '{"wf":"input"}'
      );
      insert inst;

      // The remaining stack entry's forward execution (the correct undo context).
      insert new Workflow_Step_Execution__c(
        Workflow_Instance__c = inst.Id,
        Step_Name__c = 'WorkflowEngineTest.CompensatableHappyStep',
        Status__c = 'Completed',
        Input__c = '{"a":"in"}',
        Output__c = '{"a":"out"}'
      );
      // A later-completed forward step that was already compensated/popped — this is the
      // "latest completed overall" row the old code would have wrongly seeded from.
      insert new Workflow_Step_Execution__c(
        Workflow_Instance__c = inst.Id,
        Step_Name__c = 'WorkflowEngineTest.HappyStep1',
        Status__c = 'Completed',
        Output__c = '{"b":"out"}'
      );

      Test.startTest();
      WorkflowEngine.handleCrash(
        inst.Id,
        new WorkflowEngine.WorkflowException('Crash before comp row created')
      );
      Test.stopTest();

      Workflow_Step_Execution__c createdComp = [
        SELECT Status__c, Input__c, Output__c
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :inst.Id
          AND Step_Name__c = 'WorkflowEngineTest.CompensatableHappyStep_Compensate'
        ORDER BY CreatedDate DESC, Id DESC
        LIMIT 1
      ];
      System.assertEquals('Failed', createdComp.Status__c);
      System.assertEquals(
        '{"a":"in"}',
        createdComp.Input__c,
        'Crash-created comp row must seed from its own forward step, not the latest completed overall'
      );
      System.assertEquals('{"a":"out"}', createdComp.Output__c);
    }
  }

  @IsTest
  static void testSuspendedCancelCompensationCrashStaysOnCancelPath() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // A cancel-driven rollback whose compensation was sleeping/approval-gated (Suspended)
      // when the crash hit. The persisted status is 'Suspended' (the in-transaction flip to
      // 'Cancelling' rolled back), but the engine-owned 'Cancelled by user' marker survives
      // in Error_Message__c. handleCrash must keep the saga on the cancel path so it ends
      // 'Cancelled' rather than 'Compensated' after resume.
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
        Status__c = 'Suspended',
        Error_Message__c = 'Cancelled by user. Compensating.',
        Current_Step__c = 'WorkflowEngineTest.HappyStep1',
        Compensation_Stack__c = JSON.serialize(
          new List<String>{ 'WorkflowEngineTest.CompensatableHappyStep' }
        ),
        Input__c = '{"test": true}'
      );
      insert inst;
      insert new Workflow_Step_Execution__c(
        Workflow_Instance__c = inst.Id,
        Step_Name__c = 'WorkflowEngineTest.CompensatableHappyStep_Compensate',
        Status__c = 'Pending',
        Retry_Count__c = 0
      );

      Test.startTest();
      WorkflowEngine.handleCrash(
        inst.Id,
        new WorkflowEngine.WorkflowException(
          'Crash resuming sleeping cancel compensation'
        )
      );

      Workflow_Instance__c stalled = [
        SELECT Status__c, Error_Message__c
        FROM Workflow_Instance__c
        WHERE Id = :inst.Id
      ];
      System.assertEquals('CompensationFailed', stalled.Status__c);
      System.assert(
        stalled.Error_Message__c.contains('Cancelled by user'),
        'The cancel marker must survive the suspended-compensation crash'
      );

      WorkflowEngine.resumeCompensation(inst.Id);
      WorkflowEngine.runStep(inst.Id, null);
      Test.stopTest();

      Workflow_Instance__c finalInst = [
        SELECT Status__c
        FROM Workflow_Instance__c
        WHERE Id = :inst.Id
      ];
      System.assertEquals(
        'Cancelled',
        finalInst.Status__c,
        'A cancel-driven rollback that crashed mid-sleep must finish Cancelled, not Compensated'
      );
    }
  }
}
