/**
 * @description Tests for WorkflowBatchAwaitSweep (issue #138). The sweep
 * finds instances that wait on a batch job that ended, and sets their wake
 * time. The sleep-resume sweep then resumes them.
 */
@IsTest
private class WorkflowBatchAwaitSweepTest {
  private static final Id DONE_ID = '707000000000001';
  private static final Id RUNNING_ID = '707000000000002';

  private static AsyncApexJob job(Id jobId, String status) {
    return (AsyncApexJob) JSON.deserialize(
      JSON.serialize(
        new Map<String, Object>{
          'attributes' => new Map<String, Object>{ 'type' => 'AsyncApexJob' },
          'Id' => jobId,
          'Status' => status,
          'TotalJobItems' => 1,
          'JobItemsProcessed' => 1,
          'NumberOfErrors' => 0
        }
      ),
      AsyncApexJob.class
    );
  }

  private static void stubJobs() {
    WorkflowBatchJobs.stubJobs = new Map<Id, AsyncApexJob>{
      DONE_ID => job(DONE_ID, 'Completed'),
      RUNNING_ID => job(RUNNING_ID, 'Processing')
    };
  }

  private static Workflow_Instance__c waiting(String key, String jobId) {
    return new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowBatchStepTest.BatchWorkflow',
      Status__c = 'Suspended',
      Current_Step__c = 'WorkflowBatchStepTest.BoundStep',
      Correlation_Key__c = key,
      Awaited_Batch_Job_Id__c = jobId
    );
  }

  private static Workflow_Instance__c load(Id instanceId) {
    return [
      SELECT Status__c, Awaited_Batch_Job_Id__c, Sleep_Until__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
  }

  @IsTest
  static void testEndedJobSetsWakeTimeAndClearsField() {
    stubJobs();
    Workflow_Instance__c done = waiting('sweep-done', DONE_ID);
    Workflow_Instance__c running = waiting('sweep-running', RUNNING_ID);
    insert new List<Workflow_Instance__c>{ done, running };
    Datetime now = Datetime.now();

    Integer woken = WorkflowBatchAwaitSweep.reconcile(now);

    Assert.areEqual(1, woken);
    Workflow_Instance__c d = load(done.Id);
    Assert.isNull(d.Awaited_Batch_Job_Id__c);
    Assert.areEqual(now, d.Sleep_Until__c);
    Assert.areEqual('Suspended', d.Status__c, 'Section 2 owns the resume');
    Workflow_Instance__c r = load(running.Id);
    Assert.areEqual(String.valueOf(RUNNING_ID), r.Awaited_Batch_Job_Id__c);
    Assert.isNull(r.Sleep_Until__c);
  }

  @IsTest
  static void testSecondSweepDoesNothing() {
    stubJobs();
    Workflow_Instance__c done = waiting('sweep-once', DONE_ID);
    insert done;
    Assert.areEqual(1, WorkflowBatchAwaitSweep.reconcile(Datetime.now()));
    Assert.areEqual(0, WorkflowBatchAwaitSweep.reconcile(Datetime.now()));
  }

  @IsTest
  static void testOtherWaitsAndStatusesAreIgnored() {
    stubJobs();
    Workflow_Instance__c sleeping = waiting('sweep-sleep', DONE_ID);
    Datetime later = Datetime.now().addHours(1);
    sleeping.Sleep_Until__c = later;
    Workflow_Instance__c runningInst = waiting('sweep-run', DONE_ID);
    runningInst.Status__c = 'Running';
    Workflow_Instance__c cancelled = waiting('sweep-cancel', DONE_ID);
    cancelled.Status__c = 'Cancelled';
    insert new List<Workflow_Instance__c>{ sleeping, runningInst, cancelled };

    Assert.areEqual(0, WorkflowBatchAwaitSweep.reconcile(Datetime.now()));
    Assert.areEqual(later, load(sleeping.Id).Sleep_Until__c, 'A sleep keeps its time');
    Assert.areEqual('Running', load(runningInst.Id).Status__c);
    Assert.areEqual('Cancelled', load(cancelled.Id).Status__c);
  }

  @IsTest
  static void testMalformedValueWakesTheInstance() {
    stubJobs();
    Workflow_Instance__c bad = waiting('sweep-bad', 'not-an-id');
    insert bad;
    Assert.areEqual(1, WorkflowBatchAwaitSweep.reconcile(Datetime.now()));
    Assert.isNull(load(bad.Id).Awaited_Batch_Job_Id__c);
  }

  @IsTest
  static void testNoWaitingInstanceUsesOneQuery() {
    Integer before = Limits.getQueries();
    Assert.areEqual(0, WorkflowBatchAwaitSweep.reconcile(Datetime.now()));
    Assert.areEqual(1, Limits.getQueries() - before, 'One SOQL when idle');
    Assert.areEqual(0, Limits.getDmlStatements());
  }

  @IsTest
  static void testHeartbeatResumesInOneSweep() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      stubJobs();
      Workflow_Instance__c done = waiting('sweep-heartbeat', DONE_ID);
      insert done;
      insert new Workflow_Step_Execution__c(
        Workflow_Instance__c = done.Id,
        Step_Name__c = done.Current_Step__c,
        Status__c = 'Pending',
        Retry_Count__c = 0
      );
      Test.startTest();
      WorkflowEngine.processWatchdogHeartbeat();
      Test.stopTest();
      Workflow_Instance__c after = load(done.Id);
      Assert.areEqual('Running', after.Status__c);
      Assert.isNull(after.Awaited_Batch_Job_Id__c);
      Assert.isNull(after.Sleep_Until__c);
    }
  }

  @IsTest
  static void testSweepErrorDoesNotStopTheHeartbeat() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowBatchAwaitSweep.forceError = true;
      Test.startTest();
      WorkflowEngine.processWatchdogHeartbeat();
      Test.stopTest();
      Assert.isNotNull(
        WatchdogLiveness.evaluateNow().lastSweepAt,
        'The heartbeat writes its liveness stamp'
      );
    }
  }
}
