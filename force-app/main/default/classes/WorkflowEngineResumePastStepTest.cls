@IsTest
public class WorkflowEngineResumePastStepTest {
  private class ResumePastParallelResult {
    private Workflow_Step_Execution__c stepAAfter;
    private Integer jobsBefore;
  }

  private static List<Workflow_Step_Execution__c> skipSkipTestStep2AndAssertOperatorSkipped(
    Id instanceId,
    String stepNameToSkip
  ) {
    Workflow_Instance__c inst2 = [
      SELECT Status__c, Current_Step__c, Error_Message__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals('Failed', inst2.Status__c);
    System.assertEquals(
      'WorkflowEngineMocksATest.SkipTestStep2',
      inst2.Current_Step__c
    );

    Test.startTest();
    WorkflowEngine.resumePastStep(
      instanceId,
      stepNameToSkip,
      '{"overrideVal": "skippedOutput"}'
    );
    Test.stopTest();

    List<Workflow_Step_Execution__c> stepExecs = [
      SELECT Status__c, Output__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :instanceId
        AND Step_Name__c = 'WorkflowEngineMocksATest.SkipTestStep2'
      ORDER BY CreatedDate DESC, Id DESC
    ];
    System.assertEquals(2, stepExecs.size());
    System.assertEquals('OperatorSkipped', stepExecs[0].Status__c);
    return stepExecs;
  }

  private static ResumePastParallelResult resumePastParallelBPreservingParkedBranch(
    Id instanceId,
    Workflow_Step_Execution__c parkedStepA,
    String expectedParkedState
  ) {
    update parkedStepA;

    new WorkflowOrchestrator(
        instanceId,
        'WorkflowEngineMocksATest.SkipParallelB'
      )
      .execute(null);

    Workflow_Instance__c inst2 = [
      SELECT Status__c, Current_Step__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals('Failed', inst2.Status__c);

    Integer jobsBefore = [
      SELECT COUNT()
      FROM AsyncApexJob
      WHERE JobType = 'Queueable'
    ];

    Test.startTest();
    WorkflowEngine.resumePastStep(
      instanceId,
      'WorkflowEngineMocksATest.SkipParallelB',
      '{"val": "skippedParallelB"}'
    );
    Test.stopTest();

    Workflow_Step_Execution__c stepAAfter = [
      SELECT Status__c, Retry_Count__c
      FROM Workflow_Step_Execution__c
      WHERE Id = :parkedStepA.Id
    ];
    System.assertEquals(expectedParkedState, stepAAfter.Status__c);

    ResumePastParallelResult result = new ResumePastParallelResult();
    result.stepAAfter = stepAAfter;
    result.jobsBefore = jobsBefore;
    return result;
  }

  @IsTest
  static void testResumePastStepSuccess() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;

      Id instanceId = WorkflowEngine.start(
        'WorkflowEngineMocksBTest.SkipTestWorkflow',
        'SkipSerialKey',
        'InitialInput'
      );

      // 1. Run step 1 (SkipTestStep1) -> should complete and transition current step to SkipTestStep2
      new WorkflowOrchestrator(instanceId).execute(null);
      Workflow_Instance__c inst1 = [
        SELECT Status__c, Current_Step__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      System.assertEquals('Running', inst1.Status__c);
      System.assertEquals(
        'WorkflowEngineMocksATest.SkipTestStep2',
        inst1.Current_Step__c
      );

      // 2. Run step 2 (SkipTestStep2) -> throws exception, transitions instance to Failed
      new WorkflowOrchestrator(instanceId).execute(null);
      // 3. Skip Step 2 by supplying JSON output output
      // 4. Verify step 2 execution is recorded as OperatorSkipped
      // There should be 2 execs: the failed one and the OperatorSkipped one
      List<Workflow_Step_Execution__c> stepExecs = skipSkipTestStep2AndAssertOperatorSkipped(
        instanceId,
        'WorkflowEngineMocksATest.SkipTestStep2'
      );
      System.assertEquals(
        '{"overrideVal": "skippedOutput"}',
        stepExecs[0].Output__c
      );

      // Verify operator intervention log was recorded
      List<Workflow_Log__c> logs = [
        SELECT Log_Type__c, Message__c
        FROM Workflow_Log__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Log_Type__c = 'OperatorIntervention'
      ];
      System.assertEquals(1, logs.size());
      System.assert(
        logs[0]
          .Message__c.contains(
            'skipped step WorkflowEngineMocksATest.SkipTestStep2'
          )
      );

      // 5. Run next step execution (should resume from SkipTestStep3 because WorkflowEngine.resumePastStep enqueued it)
      Workflow_Instance__c finalInst = [
        SELECT Status__c, Output__c, Compensation_Stack__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      System.assertEquals('Completed', finalInst.Status__c);
      System.assertEquals(
        '"StepThreeReceived_skippedOutput"',
        finalInst.Output__c
      );

      // Check that the skipped step was NOT added to the compensation stack
      Boolean isStackEmpty =
        String.isBlank(finalInst.Compensation_Stack__c) ||
        ((List<String>) JSON.deserialize(
            finalInst.Compensation_Stack__c,
            List<String>.class
          ))
          .isEmpty();
      System.assert(
        isStackEmpty,
        'Compensation stack should be empty because SkipTestStep2 was skipped'
      );
    }
  }

  @IsTest
  static void testResumePastStepParallelPreservesSleeping() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;

      Id instanceId = WorkflowEngine.start(
        'WorkflowEngineMocksATest.SkipParallelWorkflow',
        'SkipParallelSleepKey',
        'InitialInput'
      );

      // 1. Run split step (SkipParallelSplitStep) -> should create parallel executions
      new WorkflowOrchestrator(instanceId).execute(null);

      // 2. Put SkipParallelA in a Pending state simulation
      List<Workflow_Step_Execution__c> stepExecs = [
        SELECT Id, Status__c, Step_Name__c
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Step_Name__c = 'WorkflowEngineMocksBTest.SkipParallelA'
      ];
      System.assertEquals(1, stepExecs.size());
      stepExecs[0].Status__c = 'Pending';
      stepExecs[0].Retry_Count__c = 3;
      stepExecs[0].CPU_Time_Ms__c = 1;
      // 3. Run ParallelB -> fails and fails the workflow instance
      // 4. Resume past ParallelB and verify SkipParallelA stays parked (not reset)
      ResumePastParallelResult result = resumePastParallelBPreservingParkedBranch(
        instanceId,
        stepExecs[0],
        'Pending'
      );
      Workflow_Step_Execution__c stepAAfter = result.stepAAfter;
      Integer jobsBefore = result.jobsBefore;
      System.assertEquals(3, stepAAfter.Retry_Count__c);

      // Verify that the parent instance transitioned to Suspended (since branch A is still parked)
      Workflow_Instance__c instAfter = [
        SELECT Status__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      System.assertEquals(
        'Suspended',
        instAfter.Status__c,
        'Parent instance should stay Suspended when a sibling branch is parked'
      );

      // Verify that NO new job was enqueued
      Integer jobsAfter = [
        SELECT COUNT()
        FROM AsyncApexJob
        WHERE JobType = 'Queueable'
      ];
      System.assertEquals(
        jobsBefore,
        jobsAfter,
        'No new queueable jobs should have been enqueued for the sleeping branch'
      );
    }
  }

  @IsTest
  static void testResumePastStepCaseInsensitivity() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;

      Id instanceId = WorkflowEngine.start(
        'WorkflowEngineMocksBTest.SkipTestWorkflow',
        'SkipCaseInsensitivityKey',
        'InitialInput'
      );

      // 1. Run step 1 (SkipTestStep1) -> should complete and transition current step to SkipTestStep2
      new WorkflowOrchestrator(instanceId).execute(null);

      // 2. Run step 2 (SkipTestStep2) -> throws exception, transitions instance to Failed
      new WorkflowOrchestrator(instanceId).execute(null);
      // 3. Skip Step 2 by supplying JSON output with lowercase casing
      // 4. Verify step 2 execution is recorded as OperatorSkipped (using exact casing)
      skipSkipTestStep2AndAssertOperatorSkipped(
        instanceId,
        'workflowenginemocksatest.skipteststep2'
      );

      // 5. Run next step execution (should resume and complete)
      Workflow_Instance__c finalInst = [
        SELECT Status__c, Output__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      System.assertEquals('Completed', finalInst.Status__c);
    }
  }

  @IsTest
  static void testResumePastStepParallelPreservesRetrying() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;

      Id instanceId = WorkflowEngine.start(
        'WorkflowEngineMocksATest.SkipParallelWorkflow',
        'SkipParallelRetryingKey',
        'InitialInput'
      );

      // 1. Run split step (SkipParallelSplitStep) -> should create parallel executions
      new WorkflowOrchestrator(instanceId).execute(null);

      // 2. Put SkipParallelA in a Retrying state simulation (representing a retry backoff)
      List<Workflow_Step_Execution__c> stepExecs = [
        SELECT Id, Status__c, Step_Name__c
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Step_Name__c = 'WorkflowEngineMocksBTest.SkipParallelA'
      ];
      System.assertEquals(1, stepExecs.size());
      stepExecs[0].Status__c = 'Retrying';
      stepExecs[0].Retry_Count__c = 1;
      stepExecs[0].CPU_Time_Ms__c = 10;
      // 3. Run ParallelB -> fails and fails the workflow instance
      // 4. Resume past ParallelB and verify SkipParallelA stays parked (not reset)
      ResumePastParallelResult result = resumePastParallelBPreservingParkedBranch(
        instanceId,
        stepExecs[0],
        'Retrying'
      );
      Workflow_Step_Execution__c stepAAfter = result.stepAAfter;
      Integer jobsBefore = result.jobsBefore;
      System.assertEquals(1, stepAAfter.Retry_Count__c);

      // Verify that the parent instance transitioned to Suspended (since branch A is in Retrying state, which counts as parked)
      Workflow_Instance__c instAfter = [
        SELECT Status__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      System.assertEquals(
        'Suspended',
        instAfter.Status__c,
        'Parent instance should stay Suspended when a sibling branch is retrying'
      );

      // Verify that NO new job was enqueued
      Integer jobsAfter = [
        SELECT COUNT()
        FROM AsyncApexJob
        WHERE JobType = 'Queueable'
      ];
      System.assertEquals(
        jobsBefore,
        jobsAfter,
        'No new queueable jobs should have been enqueued for the retrying branch'
      );
    }
  }

  @IsTest
  static void testResumePastStepParallelSuccess() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;

      Id instanceId = WorkflowEngine.start(
        'WorkflowEngineMocksATest.SkipParallelWorkflow',
        'SkipParallelKey',
        'InitialInput'
      );

      // 1. Run split step (SkipParallelSplitStep) -> should create parallel executions
      new WorkflowOrchestrator(instanceId).execute(null);
      Workflow_Instance__c inst1 = [
        SELECT Status__c, Current_Step__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      System.assertEquals('Running', inst1.Status__c);
      System.assert(
        inst1.Current_Step__c.contains('WorkflowEngineMocksBTest.SkipParallelA')
      );
      System.assert(
        inst1.Current_Step__c.contains('WorkflowEngineMocksATest.SkipParallelB')
      );

      // 2. Run ParallelA -> completes successfully
      new WorkflowOrchestrator(
          instanceId,
          'WorkflowEngineMocksBTest.SkipParallelA'
        )
        .execute(null);

      // 3. Run ParallelB -> fails and fails the workflow instance
      new WorkflowOrchestrator(
          instanceId,
          'WorkflowEngineMocksATest.SkipParallelB'
        )
        .execute(null);

      Workflow_Instance__c inst2 = [
        SELECT Status__c, Current_Step__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      System.assertEquals('Failed', inst2.Status__c);

      // 4. Resume past ParallelB
      Test.startTest();
      WorkflowEngine.resumePastStep(
        instanceId,
        'WorkflowEngineMocksATest.SkipParallelB',
        '{"val": "skippedParallelB"}'
      );
      Test.stopTest();

      // 5. Verify workflow finishes successfully after join step runs
      Workflow_Instance__c finalInst = [
        SELECT Status__c, Output__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      System.assertEquals('Completed', finalInst.Status__c);
      System.assertEquals(
        '"Join_OutputA_skippedParallelB"',
        finalInst.Output__c
      );
    }
  }

  @IsTest
  static void testResumePastStepParallelSignalSkippedIsNoop() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;

      Id instanceId = WorkflowEngine.start(
        'WorkflowEngineMocksATest.SkipParallelWorkflow',
        'SkipParallelSignalKey',
        'InitialInput'
      );

      // 1. Run split step (SkipParallelSplitStep) -> should create parallel executions
      new WorkflowOrchestrator(instanceId).execute(null);

      // 2. Run ParallelB -> fails and fails the workflow instance
      new WorkflowOrchestrator(
          instanceId,
          'WorkflowEngineMocksATest.SkipParallelB'
        )
        .execute(null);

      // 3. Resume past ParallelB (sets it to OperatorSkipped)
      WorkflowEngine.resumePastStep(
        instanceId,
        'WorkflowEngineMocksATest.SkipParallelB',
        '{"val": "skippedParallelB"}'
      );

      // 4. Try executing runStep directly on the skipped step ParallelB (simulating a signal or duplicate orchestrator run)
      WorkflowEngine.runStep(
        instanceId,
        'WorkflowEngineMocksATest.SkipParallelB'
      );

      // Verify status remains OperatorSkipped
      List<Workflow_Step_Execution__c> stepsAfter = [
        SELECT Status__c
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Step_Name__c = 'WorkflowEngineMocksATest.SkipParallelB'
        ORDER BY CreatedDate DESC, Id DESC
      ];
      System.assertEquals(
        'OperatorSkipped',
        stepsAfter[0].Status__c,
        'Bypassed step should not be re-run'
      );
    }
  }

  @IsTest
  static void testResumePastStepParallelReParksParkedBranches() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;

      Id instanceId = WorkflowEngine.start(
        'WorkflowEngineMocksBTest.SkipThreeParallelWorkflow',
        'SkipThreeParallelSignalKey',
        'InitialInput'
      );

      // 1. Run split step (SkipThreeParallelSplitStep) -> should create parallel executions
      new WorkflowOrchestrator(instanceId).execute(null);

      // 2. Put SkipParallelA in a Pending state simulation (parked)
      List<Workflow_Step_Execution__c> stepExecsA = [
        SELECT Id, Status__c, Step_Name__c
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Step_Name__c = 'WorkflowEngineMocksBTest.SkipParallelA'
      ];
      stepExecsA[0].Status__c = 'Pending';
      stepExecsA[0].CPU_Time_Ms__c = 1;
      update stepExecsA[0];

      // 3. Run ParallelB -> fails and fails the workflow instance
      new WorkflowOrchestrator(
          instanceId,
          'WorkflowEngineMocksATest.SkipParallelB'
        )
        .execute(null);

      // 4. Run ParallelC -> fails as well
      new WorkflowOrchestrator(
          instanceId,
          'WorkflowEngineMocksATest.SkipParallelC'
        )
        .execute(null);

      // Verify parent is Failed
      Workflow_Instance__c instFailed = [
        SELECT Status__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      System.assertEquals('Failed', instFailed.Status__c);

      // 5. Resume past ParallelB
      WorkflowEngine.resumePastStep(
        instanceId,
        'WorkflowEngineMocksATest.SkipParallelB',
        '{"val": "skippedParallelB"}'
      );

      // 6. Sibling C was reset and is now Pending. We set failParallelC to false and run it manually.
      WorkflowEngineMocksATest.failParallelC = false;
      new WorkflowOrchestrator(
          instanceId,
          'WorkflowEngineMocksATest.SkipParallelC'
        )
        .execute(null);

      // 7. Verify that parent is set back to Suspended because A is still parked
      Workflow_Instance__c instFinal = [
        SELECT Status__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      System.assertEquals(
        'Suspended',
        instFinal.Status__c,
        'Parent should be Suspended since A is still parked'
      );
    }
  }

  @IsTest
  static void testResumePastStepParallelEnqueuesUndrivenPendingSibling() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = false;
      Id instanceId = WorkflowEngine.start(
        'WorkflowEngineMocksBTest.SkipThreeParallelWorkflow',
        'SkipThreeParallelSignalKey2',
        'InitialInput'
      );
      WorkflowEngine.disableQueueableInTest = true;

      // 1. Run split step (SkipThreeParallelSplitStep) -> should create parallel executions
      new WorkflowOrchestrator(instanceId).execute(null);

      // Sibling A is left as Pending (undriven, CPU_Time_Ms__c is null).
      // Sibling B fails and fails the workflow instance.
      new WorkflowOrchestrator(
          instanceId,
          'WorkflowEngineMocksATest.SkipParallelB'
        )
        .execute(null);

      // Verify parent is Failed
      Workflow_Instance__c instFailed = [
        SELECT Status__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      System.assertEquals('Failed', instFailed.Status__c);

      // 2. Resume past ParallelB.
      // Since A is Pending but has never run (CPU_Time_Ms__c is null), it is NOT treated as parked.
      // So the parent should become 'Running' (not 'Suspended').
      // And A should be enqueued to run.
      WorkflowEngineMocksATest.failParallelC = false;

      // Both A and C will be reset/enqueued in memory or as no-ops since disableQueueableInTest is true.
      // We run them manually to drive their execution synchronously.
      WorkflowEngine.resumePastStep(
        instanceId,
        'WorkflowEngineMocksATest.SkipParallelB',
        '{"val": "skippedParallelB"}'
      );

      // Run branch A and branch C manually. Wrap C in startTest/stopTest to execute the enqueued Join step.
      new WorkflowOrchestrator(
          instanceId,
          'WorkflowEngineMocksBTest.SkipParallelA'
        )
        .execute(null);
      Test.startTest();
      new WorkflowOrchestrator(
          instanceId,
          'WorkflowEngineMocksATest.SkipParallelC'
        )
        .execute(null);
      Test.stopTest();

      // Verify parent is Completed (since all A, B, C completed/skipped)
      Workflow_Instance__c instFinal = [
        SELECT Status__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      System.assertEquals('Completed', instFinal.Status__c);
    }
  }

  @IsTest
  static void testResumePastStepRestampsTerminalTime() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;

      Id instanceId = WorkflowEngine.start(
        'WorkflowEngineMocksBTest.TerminalSkipWorkflow',
        'TerminalSkipKey',
        'InitialInput'
      );

      // 1. Run the only step -> fails and transitions instance to Failed
      new WorkflowOrchestrator(instanceId).execute(null);

      Workflow_Instance__c instFailed = [
        SELECT Status__c, Terminal_At__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      System.assertEquals('Failed', instFailed.Status__c);
      System.assertNotEquals(null, instFailed.Terminal_At__c);

      // Manually push Terminal_At__c back by 10 minutes so we can distinguish a new stamp
      Datetime tenMinutesAgo = Datetime.now().addMinutes(-10);
      instFailed.Terminal_At__c = tenMinutesAgo;
      update as system instFailed;

      // Verify it was updated in the DB
      Workflow_Instance__c instPreSkip = [
        SELECT Terminal_At__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      System.assertEquals(tenMinutesAgo, instPreSkip.Terminal_At__c);

      // 2. Skip the terminal step. This will transition status to 'Completed'.
      Test.startTest();
      WorkflowEngine.resumePastStep(
        instanceId,
        'WorkflowEngineMocksBTest.TerminalSkipStep',
        '{"overrideVal": "skippedOutput"}'
      );
      Test.stopTest();

      // 3. Verify that the parent instance transitioned to Completed and Terminal_At__c was restamped with the new time
      Workflow_Instance__c instFinal = [
        SELECT Status__c, Terminal_At__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      System.assertEquals('Completed', instFinal.Status__c);
      System.assertNotEquals(null, instFinal.Terminal_At__c);
      System.assert(
        instFinal.Terminal_At__c > tenMinutesAgo,
        'Terminal_At__c should have been restamped to a fresh value'
      );
    }
  }

  @IsTest
  static void testResumePastStepDynamicNextThrowsException() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;

      // 1. Insert a Failed instance of LoopExposeWorkflow
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowEngineMocksATest.LoopExposeWorkflow',
        Status__c = 'Failed',
        Current_Step__c = 'WorkflowEngineMocksBTest.LoopExposeStep',
        Correlation_Key__c = 'dynamic-skip-1'
      );
      insert inst;

      // 2. Insert a Failed step execution for LoopExposeStep
      Workflow_Step_Execution__c stepExec = new Workflow_Step_Execution__c(
        Workflow_Instance__c = inst.Id,
        Step_Name__c = 'WorkflowEngineMocksBTest.LoopExposeStep',
        Status__c = 'Failed',
        Retry_Count__c = 0
      );
      insert stepExec;

      // 3. Try to skip the step
      try {
        WorkflowEngine.resumePastStep(
          inst.Id,
          'WorkflowEngineMocksBTest.LoopExposeStep',
          '{}'
        );
        System.assert(false, 'Should have thrown a WorkflowException');
      } catch (WorkflowEngine.WorkflowException ex) {
        System.assertEquals(
          'Skip is not supported for dynamic-next step definitions.',
          ex.getMessage()
        );
      }
    }
  }

  @IsTest
  static void testResumePastStepRearmsPendingSiblingTimeout() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;

      Id instanceId = WorkflowEngine.start(
        'WorkflowEngineMocksBTest.SkipThreeParallelWorkflow',
        'SkipThreeParallelSignalKey3',
        'InitialInput'
      );

      // 1. Run split step -> creates parallel executions A, B, C.
      new WorkflowOrchestrator(instanceId).execute(null);

      // 2. Fetch the initial pending Sibling A step execution.
      Workflow_Step_Execution__c sibA = [
        SELECT Id, Timeout_At__c
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Step_Name__c = 'WorkflowEngineMocksBTest.SkipParallelA'
        LIMIT 1
      ];
      System.assertNotEquals(
        null,
        sibA.Timeout_At__c,
        'Sibling A should have an initial timeout set'
      );

      // Artificially modify Timeout_At__c to be in the past to simulate delay/stale timeout.
      Datetime pastTime = Datetime.now().addMinutes(-10);
      sibA.Timeout_At__c = pastTime;
      update sibA;

      // Fail Sibling B to fail the workflow instance.
      new WorkflowOrchestrator(
          instanceId,
          'WorkflowEngineMocksATest.SkipParallelB'
        )
        .execute(null);

      // 3. Resume past ParallelB (the skip).
      WorkflowEngine.resumePastStep(
        instanceId,
        'WorkflowEngineMocksATest.SkipParallelB',
        '{"val": "skippedParallelB"}'
      );

      // 4. Fetch Sibling A again to verify Timeout_At__c was re-armed (set to a future time, i.e., > pastTime)
      Workflow_Step_Execution__c sibAAfter = [
        SELECT Timeout_At__c
        FROM Workflow_Step_Execution__c
        WHERE Id = :sibA.Id
      ];
      System.assertNotEquals(
        null,
        sibAAfter.Timeout_At__c,
        'Sibling A should have its timeout set'
      );
      System.assert(
        sibAAfter.Timeout_At__c > pastTime,
        'Sibling A timeout should have been re-armed/advanced: ' +
        sibAAfter.Timeout_At__c
      );
    }
  }

  @IsTest
  static void testRunStepParallelReparksWithAlreadyRunningSibling() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;

      Id instanceId = WorkflowEngine.start(
        'WorkflowEngineMocksBTest.CompensatableParallelWorkflow',
        'CompensatableParallelSignalKey',
        'InitialInput'
      );

      // 1. Run split step -> creates parallel executions A and B
      new WorkflowOrchestrator(instanceId).execute(null);

      // 2. Put A in a Pending state simulation with CPU_Time_Ms__c = 10.0 (representing a parked branch)
      List<Workflow_Step_Execution__c> stepExecs = [
        SELECT Id, Status__c, CPU_Time_Ms__c
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Step_Name__c = 'WorkflowEngineMocksATest.CompensatableParallelA'
        LIMIT 1
      ];
      System.assertEquals(1, stepExecs.size());
      stepExecs[0].Status__c = 'Pending';
      stepExecs[0].CPU_Time_Ms__c = 10.0;
      update stepExecs;

      // 3. Mark the parent instance as Running to simulate that Sibling B is already running (or transaction entered in Running state)
      Workflow_Instance__c inst = [
        SELECT Id, Status__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      inst.Status__c = 'Running';
      update inst;

      // 4. Run Sibling B (which is CompensatableParallelB).
      // Because it is compensatable, it will execute `update as system instance;` during compensation-stack update.
      // At the end, in the `if (!allDone)` block, it should repark the instance as 'Suspended' since Sibling A is parked.
      new WorkflowOrchestrator(
          instanceId,
          'WorkflowEngineMocksATest.CompensatableParallelB'
        )
        .execute(null);

      // 5. Verify the parent instance was correctly updated to 'Suspended'
      Workflow_Instance__c instAfter = [
        SELECT Status__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      System.assertEquals(
        'Suspended',
        instAfter.Status__c,
        'Parent instance should be Suspended since Sibling A is parked'
      );
    }
  }
}
