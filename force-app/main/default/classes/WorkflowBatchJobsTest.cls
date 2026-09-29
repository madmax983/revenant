/**
 * @description Tests for WorkflowBatchJobs (issue #138): the launch, the
 * terminal outcome read and the parallel-branch check.
 */
@IsTest
private class WorkflowBatchJobsTest {
  private static final Id RUNNING_ID = '707000000000001';
  private static final Id DONE_ID = '707000000000002';
  private static final Id GONE_ID = '707000000000003';

  /** @description A Batchable with no Revenant code. */
  public class CountBatch implements Database.Batchable<SObject> {
    /**
     * @description Selects the test accounts.
     * @param bc The batch context.
     * @return The query locator.
     */
    public Database.QueryLocator start(Database.BatchableContext bc) {
      return Database.getQueryLocator(
        [
          SELECT Id
          FROM Account
          WHERE Name LIKE 'BatchJobsTest%'
          WITH SYSTEM_MODE
        ]
      );
    }

    /**
     * @description Does nothing.
     * @param bc The batch context.
     * @param scope The records of this chunk.
     */
    public void execute(Database.BatchableContext bc, List<SObject> scope) {
      return;
    }

    /**
     * @description Does nothing.
     * @param bc The batch context.
     */
    public void finish(Database.BatchableContext bc) {
      return;
    }
  }

  private static AsyncApexJob job(Id jobId, String status, Integer errors) {
    return (AsyncApexJob) JSON.deserialize(
      JSON.serialize(
        new Map<String, Object>{
          'attributes' => new Map<String, Object>{ 'type' => 'AsyncApexJob' },
          'Id' => jobId,
          'Status' => status,
          'TotalJobItems' => 4,
          'JobItemsProcessed' => 4,
          'NumberOfErrors' => errors,
          'ExtendedStatus' => errors > 0 ? 'First error: x' : null
        }
      ),
      AsyncApexJob.class
    );
  }

  @IsTest
  static void testTerminalOutcomesFiltersRunningAndReportsMissing() {
    WorkflowBatchJobs.stubJobs = new Map<Id, AsyncApexJob>{
      RUNNING_ID => job(RUNNING_ID, 'Processing', 0),
      DONE_ID => job(DONE_ID, 'Completed', 2)
    };
    Map<Id, Map<String, Object>> outcomes = WorkflowBatchJobs.terminalOutcomes(
      new Set<Id>{ RUNNING_ID, DONE_ID, GONE_ID }
    );

    Assert.isFalse(outcomes.containsKey(RUNNING_ID), 'A running job waits');
    Map<String, Object> done = outcomes.get(DONE_ID);
    Assert.areEqual('Completed', done.get('status'));
    Assert.areEqual(false, done.get('succeeded'), 'Chunk errors: no success');
    Assert.areEqual(2, done.get('numberOfErrors'));
    Assert.areEqual('First error: x', done.get('firstError'));
    Map<String, Object> gone = outcomes.get(GONE_ID);
    Assert.areEqual(WorkflowBatchJobs.STATUS_NOT_FOUND, gone.get('status'));
    Assert.areEqual(false, gone.get('succeeded'));
    Assert.areEqual(String.valueOf(GONE_ID), gone.get('jobId'));
  }

  @IsTest
  static void testEachHoldingStatusWaits() {
    Map<Id, AsyncApexJob> rows = new Map<Id, AsyncApexJob>();
    rows.put(RUNNING_ID, job(RUNNING_ID, 'Holding', 0));
    WorkflowBatchJobs.stubJobs = rows;
    for (
      String status : new List<String>{
        'Holding',
        'Queued',
        'Preparing',
        'Processing'
      }
    ) {
      rows.put(RUNNING_ID, job(RUNNING_ID, status, 0));
      Assert.isNull(WorkflowBatchJobs.terminalOutcome(RUNNING_ID), status);
    }
    for (String status : new List<String>{ 'Completed', 'Failed', 'Aborted' }) {
      rows.put(RUNNING_ID, job(RUNNING_ID, status, 0));
      Assert.areEqual(
        status,
        WorkflowBatchJobs.terminalOutcome(RUNNING_ID).get('status'),
        status
      );
    }
  }

  @IsTest
  static void testEmptyInputReadsNothing() {
    Assert.isTrue(WorkflowBatchJobs.terminalOutcomes(new Set<Id>()).isEmpty());
    Assert.isTrue(WorkflowBatchJobs.terminalOutcomes(null).isEmpty());
    Assert.areEqual(0, Limits.getQueries(), 'No SOQL for no job');
  }

  @IsTest
  static void testRealLaunchReachesCompleted() {
    insert new Account(Name = 'BatchJobsTest 1');
    Test.startTest();
    Id jobId = WorkflowBatchJobs.launch(new CountBatch(), 200);
    Assert.isNull(
      WorkflowBatchJobs.terminalOutcome(jobId),
      'A queued job is not terminal'
    );
    Test.stopTest();

    Map<String, Object> outcome = WorkflowBatchJobs.terminalOutcome(jobId);
    Assert.isNotNull(outcome, 'The job ends at stopTest');
    Assert.areEqual('Completed', outcome.get('status'));
    Assert.areEqual(true, outcome.get('succeeded'));
    Assert.areEqual(1, WorkflowBatchJobs.launchCount);
  }

  @IsTest
  static void testInParallelBranch() {
    Workflow_Instance__c serial = new Workflow_Instance__c(
      Workflow_Name__c = 'X',
      Status__c = 'Running',
      Current_Step__c = 'A',
      Correlation_Key__c = 'batch-jobs-serial'
    );
    Workflow_Instance__c branched = new Workflow_Instance__c(
      Workflow_Name__c = 'X',
      Status__c = 'Running',
      Current_Step__c = 'A,B',
      Correlation_Key__c = 'batch-jobs-branched'
    );
    insert new List<Workflow_Instance__c>{ serial, branched };

    Assert.isFalse(WorkflowBatchJobs.inParallelBranch(serial.Id));
    Assert.isTrue(WorkflowBatchJobs.inParallelBranch(branched.Id));
    Assert.isFalse(WorkflowBatchJobs.inParallelBranch(null));
  }
}
