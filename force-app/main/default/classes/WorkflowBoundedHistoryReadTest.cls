/**
 * @description Tests for the bounded history reads (issue #261). The detail pane
 * reads a bounded window of rows. The first compensation step uses the last
 * Completed visit of the forward step.
 */
@IsTest
private class WorkflowBoundedHistoryReadTest {
  private static final String FWD = 'Fwd.Step';
  private static final String COMP = 'Fwd.Step_Compensate';
  private static final String CAN_START = 'Test.Workflow';

  @TestSetup
  static void seedLongHistory() {
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = CAN_START,
      Status__c = 'Running',
      Correlation_Key__c = 'long-history'
    );
    insert inst;
    insertRows(inst.Id, 'Loop.Step', 'Completed', 5000, 0);
  }

  private static Workflow_Instance__c longInstance() {
    return [
      SELECT Id
      FROM Workflow_Instance__c
      WHERE Correlation_Key__c = 'long-history'
    ];
  }

  // Inserts `count` rows in chunks. Input/Output carry the row number.
  private static void insertRows(
    Id instanceId,
    String stepName,
    String status,
    Integer count,
    Integer firstNumber
  ) {
    List<Workflow_Step_Execution__c> chunk = new List<Workflow_Step_Execution__c>();
    for (Integer i = 0; i < count; i++) {
      chunk.add(
        new Workflow_Step_Execution__c(
          Workflow_Instance__c = instanceId,
          Step_Name__c = stepName,
          Status__c = status,
          Input__c = 'in-' + (firstNumber + i),
          Output__c = 'out-' + (firstNumber + i)
        )
      );
      if (chunk.size() == 500) {
        insert chunk;
        chunk = new List<Workflow_Step_Execution__c>();
      }
    }
    if (!chunk.isEmpty()) {
      insert chunk;
    }
  }

  private static Workflow_Instance__c compensatingInstance() {
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = CAN_START,
      Status__c = 'Compensating',
      Compensation_Stack__c = JSON.serialize(new List<String>{ FWD })
    );
    insert inst;
    return inst;
  }

  // Two visits of the forward step: a Completed one, then a Failed one.
  private static void seedLoopedForwardStep(Id instanceId) {
    insert new Workflow_Step_Execution__c(
      Workflow_Instance__c = instanceId,
      Step_Name__c = FWD,
      Status__c = 'Completed',
      Input__c = 'in-done',
      Output__c = 'out-done'
    );
    insert new Workflow_Step_Execution__c(
      Workflow_Instance__c = instanceId,
      Step_Name__c = FWD,
      Status__c = 'Failed',
      Input__c = 'in-failed',
      Output__c = 'out-failed'
    );
  }

  private static Workflow_Step_Execution__c compensationRow(Id instanceId) {
    return [
      SELECT Input__c, Output__c, Status__c
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c = :instanceId AND Step_Name__c = :COMP
      ORDER BY CreatedDate DESC, Id DESC
      LIMIT 1
    ];
  }

  // ============================================================
  // Detail pane
  // ============================================================

  @IsTest
  static void detailPaneOpensWithTenThousandRows() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = longInstance();
      insertRows(inst.Id, 'Loop.Step', 'Completed', 5000, 5000);
      Assert.areEqual(
        10000,
        [
          SELECT COUNT()
          FROM Workflow_Step_Execution__c
          WHERE Workflow_Instance__c = :inst.Id
        ],
        'The fixture has 10,000 rows'
      );

      Test.startTest();
      Integer rowsBefore = Limits.getQueryRows();
      Map<String, Object> details = WorkflowInstanceDetailService.loadDetails(
        inst.Id
      );
      Integer rowsUsed = Limits.getQueryRows() - rowsBefore;
      Test.stopTest();

      Assert.isTrue(rowsUsed < 1000, 'The read is bounded: ' + rowsUsed);

      List<Workflow_Step_Execution__c> steps = (List<Workflow_Step_Execution__c>) details.get(
        'steps'
      );
      Assert.areEqual(
        WorkflowInstanceDetailService.MAX_STEP_ROWS,
        steps.size(),
        'The pane returns a bounded window'
      );
      Assert.areEqual(
        true,
        details.get('stepsTruncated'),
        'The pane says the window is partial'
      );
      Assert.areEqual(
        10000,
        details.get('stepCount'),
        'The pane reports the row count'
      );
    }
  }

  @IsTest
  static void detailWindowHoldsTheNewestRowsInOrder() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = longInstance();
      insertRows(inst.Id, 'Loop.Step', 'Completed', 1000, 5000);

      Map<String, Object> details = WorkflowInstanceDetailService.loadDetails(
        inst.Id
      );
      List<Workflow_Step_Execution__c> steps = (List<Workflow_Step_Execution__c>) details.get(
        'steps'
      );
      Workflow_Step_Execution__c last = steps[steps.size() - 1];
      Assert.areEqual(
        'in-5999',
        last.Input__c,
        'The newest row is last (ascending order)'
      );
      Assert.areEqual(
        'in-5950',
        steps[steps.size() - WorkflowInstanceDetailService.LONG_TEXT_ROWS]
          .Input__c,
        'The rows keep ascending order'
      );
      Assert.isNull(steps[0].Input__c, 'The oldest row has no long text');
    }
  }

  @IsTest
  static void longTextIsReadForTheNewestRowsOnly() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = longInstance();
      insertRows(inst.Id, 'Loop.Step', 'Completed', 600, 5000);

      Map<String, Object> details = WorkflowInstanceDetailService.loadDetails(
        inst.Id
      );
      List<Workflow_Step_Execution__c> steps = (List<Workflow_Step_Execution__c>) details.get(
        'steps'
      );
      Integer withText = 0;
      for (Workflow_Step_Execution__c step : steps) {
        if (step.Input__c != null || step.Output__c != null) {
          withText++;
        }
      }
      Assert.areEqual(
        WorkflowInstanceDetailService.LONG_TEXT_ROWS,
        withText,
        'Only the newest rows carry Input and Output'
      );
      Assert.isNotNull(
        steps[steps.size() - 1].Output__c,
        'The newest row carries its Output'
      );
      Assert.isNull(
        steps[0].Output__c,
        'An older row of the window has no Output'
      );
    }
  }

  @IsTest
  static void longTextReadStopsAtTheHeapBudget() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = CAN_START,
        Status__c = 'Running'
      );
      insert inst;
      insertRows(inst.Id, 'Big.Step', 'Completed', 10, 0);
      WorkflowInstanceDetailService.textHeapBudget = 1;

      Map<String, Object> details = WorkflowInstanceDetailService.loadDetails(
        inst.Id
      );

      List<Workflow_Step_Execution__c> steps = (List<Workflow_Step_Execution__c>) details.get(
        'steps'
      );
      Assert.areEqual(10, steps.size(), 'No row is hidden');
      Assert.areEqual(2, details.get('stepTextRows'), 'One chunk is read');
      Assert.isNotNull(steps[9].Output__c, 'The newest row has text');
      Assert.isNull(steps[7].Output__c, 'A row past the budget has no text');
    }
  }

  @IsTest
  static void longTextReadStopsAboveTheHeapCeiling() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = CAN_START,
        Status__c = 'Running'
      );
      insert inst;
      insertRows(inst.Id, 'Big.Step', 'Completed', 10, 0);
      WorkflowInstanceDetailService.heapCeiling = 1;

      Map<String, Object> details = WorkflowInstanceDetailService.loadDetails(
        inst.Id
      );

      Assert.areEqual(2, details.get('stepTextRows'), 'One chunk is read');
    }
  }

  @IsTest
  static void textCountSkipsAParkedRowThatIsNotNewest() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = CAN_START,
        Status__c = 'Suspended'
      );
      insert inst;
      insertRows(inst.Id, 'Park.Step', 'Pending', 1, 0);
      insertRows(inst.Id, 'Loop.Step', 'Completed', 5, 1);
      WorkflowInstanceDetailService.textHeapBudget = 1;

      Map<String, Object> details = WorkflowInstanceDetailService.loadDetails(
        inst.Id
      );

      // One chunk: the parked row and the newest row. Only the newest counts.
      Assert.areEqual(1, details.get('stepTextRows'), 'No gap in the count');
    }
  }

  @IsTest
  static void longTextReadStopsWhenTheQueriesRunLow() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = CAN_START,
        Status__c = 'Running'
      );
      insert inst;
      insertRows(inst.Id, 'Big.Step', 'Completed', 10, 0);
      WorkflowInstanceDetailService.queryReserve = Limits.getLimitQueries();

      Map<String, Object> details = WorkflowInstanceDetailService.loadDetails(
        inst.Id
      );

      Assert.areEqual(2, details.get('stepTextRows'), 'One chunk is read');
    }
  }

  @IsTest
  static void shortHistoryIsNotTruncated() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = CAN_START,
        Status__c = 'Running'
      );
      insert inst;
      insertRows(inst.Id, 'Short.Step', 'Completed', 3, 0);

      Map<String, Object> details = WorkflowInstanceDetailService.loadDetails(
        inst.Id
      );
      List<Workflow_Step_Execution__c> steps = (List<Workflow_Step_Execution__c>) details.get(
        'steps'
      );
      Assert.areEqual(3, steps.size(), 'All rows are returned');
      Assert.areEqual(false, details.get('stepsTruncated'), 'Not partial');
      Assert.areEqual(3, details.get('stepCount'), 'Row count');
      Assert.areEqual('in-0', steps[0].Input__c, 'Ascending order');
      Assert.areEqual('out-2', steps[2].Output__c, 'Long text is present');
    }
  }

  @IsTest
  static void windowEdgeIsExact() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c exact = new Workflow_Instance__c(
        Workflow_Name__c = CAN_START,
        Status__c = 'Running'
      );
      Workflow_Instance__c over = new Workflow_Instance__c(
        Workflow_Name__c = CAN_START,
        Status__c = 'Running'
      );
      insert new List<Workflow_Instance__c>{ exact, over };
      insertRows(exact.Id, 'Edge.Step', 'Completed', 500, 0);
      insertRows(over.Id, 'Edge.Step', 'Completed', 501, 0);

      Map<String, Object> exactDetails = WorkflowInstanceDetailService.loadDetails(
        exact.Id
      );
      Map<String, Object> overDetails = WorkflowInstanceDetailService.loadDetails(
        over.Id
      );

      Assert.areEqual(false, exactDetails.get('stepsTruncated'), '500 rows');
      Assert.areEqual(true, overDetails.get('stepsTruncated'), '501 rows');
      Assert.areEqual(501, overDetails.get('stepCount'), 'The count is exact');
    }
  }

  @IsTest
  static void parkedRowOutsideTheWindowCountsAsShown() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = CAN_START,
        Status__c = 'Suspended'
      );
      insert inst;
      insertRows(inst.Id, 'Park.Step', 'Pending', 1, 0);
      insertRows(inst.Id, 'Loop.Step', 'Completed', 500, 1);

      Map<String, Object> details = WorkflowInstanceDetailService.loadDetails(
        inst.Id
      );

      List<Workflow_Step_Execution__c> steps = (List<Workflow_Step_Execution__c>) details.get(
        'steps'
      );
      Assert.areEqual(501, steps.size(), 'All rows are returned');
      Assert.areEqual(false, details.get('stepsTruncated'), 'No row is hidden');
      Assert.areEqual(501, details.get('stepWindow'), 'The window is shown');
    }
  }

  @IsTest
  static void parkedStepInsideTheWindowIsNotDuplicated() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = CAN_START,
        Status__c = 'Suspended'
      );
      insert inst;
      insertRows(inst.Id, 'Short.Step', 'Completed', 3, 0);
      insertRows(inst.Id, 'Park.Step', 'Pending', 1, 3);

      Map<String, Object> details = WorkflowInstanceDetailService.loadDetails(
        inst.Id
      );

      List<Workflow_Step_Execution__c> steps = (List<Workflow_Step_Execution__c>) details.get(
        'steps'
      );
      Assert.areEqual(4, steps.size(), 'No row is duplicated');
    }
  }

  @IsTest
  static void parkedStepOutsideTheWindowStillGivesTheWaitDescriptor() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = CAN_START,
        Status__c = 'Suspended'
      );
      insert inst;
      insert new Workflow_Step_Execution__c(
        Workflow_Instance__c = inst.Id,
        Step_Name__c = 'Park.Step',
        Status__c = 'Pending',
        Output__c = '{"waitingForApproval":true,"approvalKey":"k1","approvalRole":"r1"}'
      );
      insertRows(inst.Id, 'Loop.Step', 'Completed', 700, 0);

      Map<String, Object> details = WorkflowInstanceDetailService.loadDetails(
        inst.Id
      );
      Map<String, Object> descriptor = (Map<String, Object>) details.get(
        'waitDescriptor'
      );
      List<Workflow_Step_Execution__c> steps = (List<Workflow_Step_Execution__c>) details.get(
        'steps'
      );
      Assert.areEqual(
        WorkflowInstanceDetailService.MAX_STEP_ROWS + 1,
        steps.size(),
        'The parked row is added outside the window'
      );
      Assert.isNotNull(steps[0].Output__c, 'The parked row has its Output');
      Assert.isNull(steps[1].Output__c, 'A window row has no Output');
      Assert.isNotNull(descriptor, 'The parked step is still read');
      Assert.areEqual(
        WorkflowWaitDescriptorService.TYPE_APPROVAL,
        descriptor.get('type'),
        'The wait is an approval'
      );
    }
  }

  // ============================================================
  // First compensation step
  // ============================================================

  @IsTest
  static void singlePathSeedsFromTheLastCompletedVisit() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = compensatingInstance();
      seedLoopedForwardStep(inst.Id);

      WorkflowCompensation.preCreateFirstCompensationStep(inst);

      Workflow_Step_Execution__c seeded = compensationRow(inst.Id);
      Assert.areEqual('in-done', seeded.Input__c, 'Input of Completed visit');
      Assert.areEqual('out-done', seeded.Output__c, 'Output of Completed');
    }
  }

  @IsTest
  static void bulkPathSeedsFromTheLastCompletedVisit() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c first = compensatingInstance();
      Workflow_Instance__c second = compensatingInstance();
      seedLoopedForwardStep(first.Id);
      seedLoopedForwardStep(second.Id);

      WorkflowCompensation.preCreateFirstCompensationSteps(
        new List<Workflow_Instance__c>{ first, second }
      );

      for (
        Workflow_Instance__c inst : new List<Workflow_Instance__c>{
          first,
          second
        }
      ) {
        Workflow_Step_Execution__c seeded = compensationRow(inst.Id);
        Assert.areEqual('in-done', seeded.Input__c, 'Input of Completed');
        Assert.areEqual('out-done', seeded.Output__c, 'Output of Completed');
      }
    }
  }

  @IsTest
  static void laterCompletedVisitWinsOverAnEarlierOne() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = compensatingInstance();
      insert new Workflow_Step_Execution__c(
        Workflow_Instance__c = inst.Id,
        Step_Name__c = FWD,
        Status__c = 'Completed',
        Input__c = 'in-1',
        Output__c = 'out-1'
      );
      insert new Workflow_Step_Execution__c(
        Workflow_Instance__c = inst.Id,
        Step_Name__c = FWD,
        Status__c = 'Completed',
        Input__c = 'in-2',
        Output__c = 'out-2'
      );

      WorkflowCompensation.preCreateFirstCompensationStep(inst);

      Assert.areEqual('in-2', compensationRow(inst.Id).Input__c, 'Last visit');
    }
  }

  @IsTest
  static void noCompletedVisitSeedsNothing() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = compensatingInstance();
      insert new Workflow_Step_Execution__c(
        Workflow_Instance__c = inst.Id,
        Step_Name__c = FWD,
        Status__c = 'Failed',
        Input__c = 'in-failed',
        Output__c = 'out-failed'
      );

      WorkflowCompensation.preCreateFirstCompensationStep(inst);

      Workflow_Step_Execution__c seeded = compensationRow(inst.Id);
      Assert.isNull(seeded.Input__c, 'A failed visit does not seed Input');
      Assert.isNull(seeded.Output__c, 'A failed visit does not seed Output');
    }
  }

  @IsTest
  static void bulkPathHandlesInstancesWithAndWithoutACompletedVisit() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c failedOnly = compensatingInstance();
      Workflow_Instance__c looped = compensatingInstance();
      insert new Workflow_Step_Execution__c(
        Workflow_Instance__c = failedOnly.Id,
        Step_Name__c = FWD,
        Status__c = 'Failed',
        Input__c = 'in-failed'
      );
      seedLoopedForwardStep(looped.Id);

      WorkflowCompensation.preCreateFirstCompensationSteps(
        new List<Workflow_Instance__c>{ failedOnly, looped }
      );

      Assert.isNull(compensationRow(failedOnly.Id).Input__c, 'No seed');
      Assert.areEqual('in-done', compensationRow(looped.Id).Input__c, 'Seed');
    }
  }

  @IsTest
  static void retryWithoutACheckpointFallsBackToTheCompletedVisit() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = compensatingInstance();
      seedLoopedForwardStep(inst.Id);
      insert new Workflow_Step_Execution__c(
        Workflow_Instance__c = inst.Id,
        Step_Name__c = COMP,
        Status__c = 'Failed'
      );

      WorkflowCompensationStepLog.appendCompensationRetryStep(
        inst,
        new List<String>{ FWD }
      );

      Workflow_Step_Execution__c seeded = compensationRow(inst.Id);
      Assert.areEqual('Pending', seeded.Status__c, 'A new attempt');
      Assert.areEqual('out-done', seeded.Output__c, 'Completed visit');
    }
  }

  @IsTest
  static void liveDriveSeedsFromTheLastCompletedVisit() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = compensatingInstance();
      seedLoopedForwardStep(inst.Id);
      WorkflowCompensationRunner.CompensationRun run = new WorkflowCompensationRunner.CompensationRun();
      run.instance = inst;
      run.compensationStepLogName = COMP;
      run.activeStepName = FWD;
      run.forwardSourceInstanceId = inst.Id;

      Boolean ready = WorkflowCompensationStepLog.prepareCompensationStepExec(
        run
      );

      Assert.isTrue(ready, 'A new attempt is ready');
      Assert.areEqual('in-done', run.stepExec.Input__c, 'Input of Completed');
      Assert.areEqual(
        'out-done',
        run.stepExec.Output__c,
        'Output of Completed'
      );
    }
  }

  @IsTest
  static void retryPathSeedsFromTheLastCompletedVisit() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = compensatingInstance();
      seedLoopedForwardStep(inst.Id);

      WorkflowCompensationStepLog.appendCompensationRetryStep(
        inst,
        new List<String>{ FWD }
      );

      Workflow_Step_Execution__c seeded = compensationRow(inst.Id);
      Assert.areEqual('Pending', seeded.Status__c, 'A new attempt');
      Assert.areEqual('in-done', seeded.Input__c, 'Input of Completed');
      Assert.areEqual('out-done', seeded.Output__c, 'Output of Completed');
    }
  }

  @IsTest
  static void bulkRetryPathSeedsFromTheLastCompletedVisit() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = compensatingInstance();
      seedLoopedForwardStep(inst.Id);

      WorkflowCompensationStepLog.appendCompensationRetrySteps(
        new List<Workflow_Instance__c>{ inst }
      );

      Workflow_Step_Execution__c seeded = compensationRow(inst.Id);
      Assert.areEqual('in-done', seeded.Input__c, 'Input of Completed');
      Assert.areEqual('out-done', seeded.Output__c, 'Output of Completed');
    }
  }

  @IsTest
  static void retryKeepsTheCheckpointOfTheFailedCompensation() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = compensatingInstance();
      seedLoopedForwardStep(inst.Id);
      insert new Workflow_Step_Execution__c(
        Workflow_Instance__c = inst.Id,
        Step_Name__c = COMP,
        Status__c = 'Failed',
        Input__c = 'in-comp',
        Output__c = 'out-checkpoint'
      );

      WorkflowCompensationStepLog.appendCompensationRetryStep(
        inst,
        new List<String>{ FWD }
      );

      Workflow_Step_Execution__c seeded = compensationRow(inst.Id);
      Assert.areEqual('Pending', seeded.Status__c, 'A new attempt');
      Assert.areEqual('in-comp', seeded.Input__c, 'The checkpoint input stays');
      Assert.areEqual('out-checkpoint', seeded.Output__c, 'Checkpoint stays');
    }
  }

  // ============================================================
  // Visit read of the _Compensate rows
  // ============================================================

  @IsTest
  static void visitCountAndReuseStillWorkAfterTheLightRead() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = compensatingInstance();
      insertRows(inst.Id, COMP, 'Compensated', 2, 0);
      insert new Workflow_Step_Execution__c(
        Workflow_Instance__c = inst.Id,
        Step_Name__c = COMP,
        Status__c = 'Pending',
        Input__c = 'in-pending',
        Output__c = 'out-pending'
      );
      WorkflowCompensationRunner.CompensationRun run = new WorkflowCompensationRunner.CompensationRun();
      run.instance = inst;
      run.compensationStepLogName = COMP;
      run.activeStepName = FWD;
      run.forwardSourceInstanceId = inst.Id;

      Boolean ready = WorkflowCompensationStepLog.prepareCompensationStepExec(
        run
      );

      Assert.isTrue(ready, 'The pending attempt is reused');
      Assert.areEqual(2, run.compensateVisit, 'Two prior visits');
      Assert.areEqual('in-pending', run.stepExec.Input__c, 'Input is read');
      Assert.areEqual('out-pending', run.stepExec.Output__c, 'Output is read');
      Assert.areEqual('Running', run.stepExec.Status__c, 'Attempt runs');
    }
  }

  @IsTest
  static void largeTimedApprovalStateStaysASignalWait() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      ContentVersion cv = new ContentVersion(
        Title = 'BigTimedState',
        PathOnClient = 'timed.json',
        VersionData = Blob.valueOf(
          '{"waitingForApproval":true,"approvalKey":"k1","pad":"' +
            'X'.repeat(WorkflowWaitDescriptorService.MAX_STATE_BYTES) +
            '"}'
        )
      );
      insert cv;
      Id docId = [
        SELECT ContentDocumentId
        FROM ContentVersion
        WHERE Id = :cv.Id
      ]
      .ContentDocumentId;
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = CAN_START,
        Status__c = 'Suspended',
        Sleep_Until__c = System.now().addHours(1)
      );
      insert inst;
      insert new Workflow_Step_Execution__c(
        Workflow_Instance__c = inst.Id,
        Step_Name__c = 'Park.Step',
        Status__c = 'Pending',
        Wait_Type__c = WorkflowWaitDescriptorService.TYPE_APPROVAL,
        Output__c = '{"$attachmentId":"' + docId + '"}'
      );

      Map<String, Object> details = WorkflowInstanceDetailService.loadDetails(
        inst.Id
      );

      Assert.isNotNull(
        details.get('waitDescriptor'),
        'A timed signal wait is not shown as a timer wait'
      );
    }
  }

  @IsTest
  static void largeOffloadedWaitStateIsNotRead() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      ContentVersion cv = new ContentVersion(
        Title = 'BigState',
        PathOnClient = 'state.json',
        VersionData = Blob.valueOf(
          '{"waitingForApproval":true,"approvalKey":"k1","pad":"' +
            'X'.repeat(WorkflowWaitDescriptorService.MAX_STATE_BYTES) +
            '"}'
        )
      );
      insert cv;
      Id docId = [
        SELECT ContentDocumentId
        FROM ContentVersion
        WHERE Id = :cv.Id
      ]
      .ContentDocumentId;
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = CAN_START,
        Status__c = 'Suspended'
      );
      insert inst;
      insert new Workflow_Step_Execution__c(
        Workflow_Instance__c = inst.Id,
        Step_Name__c = 'Park.Step',
        Status__c = 'Pending',
        Output__c = '{"$attachmentId":"' + docId + '"}'
      );

      Map<String, Object> details = WorkflowInstanceDetailService.loadDetails(
        inst.Id
      );

      Map<String, Object> descriptor = (Map<String, Object>) details.get(
        'waitDescriptor'
      );
      Assert.isNotNull(descriptor, 'The wait is still shown');
      Assert.areEqual(
        WorkflowWaitDescriptorService.TYPE_GENERIC,
        descriptor.get('type'),
        'The large state is not read, so the wait is generic'
      );
    }
  }
}
