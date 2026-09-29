/**
 * @description Tests for BatchStepWorkflowExample (issue #138). The success
 * test runs the real ExampleAccountTagBatch. The failure test stubs the job
 * row, because a test cannot make a real batch job fail on purpose.
 */
@IsTest
private class BatchStepWorkflowExampleTest {
  private static final String WORKFLOW = 'BatchStepWorkflowExample.AccountTagWorkflow';
  private static final String RESERVE = 'BatchStepWorkflowExample.ReserveTagStep';
  private static final String TAG_STEP = 'BatchStepWorkflowExample.TagAccountsStep';
  private static final String CONFIRM = 'BatchStepWorkflowExample.ConfirmStep';
  private static final String ROLLBACK_STEP = 'BatchStepWorkflowExample.RollbackStep';

  private static String workflowInput() {
    return JSON.serialize(
      new Map<String, Object>{ 'namePrefix' => 'BatchStepEx', 'tag' => 'Q3-Review' }
    );
  }

  @IsTest
  static void testRealBatchTagsAccountsAndCompletes() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      insert new List<Account>{
        new Account(Name = 'BatchStepEx 1'),
        new Account(Name = 'BatchStepEx 2'),
        new Account(Name = 'Other 3')
      };
      Test.startTest();
      Id instanceId = WorkflowEngine.start(WORKFLOW, 'batch-ex-ok', workflowInput());
      WorkflowTestHarness harness = new WorkflowTestHarness(instanceId);
      WorkflowTestHarness.Result r = harness.drive();
      Assert.isTrue(r.isSuspended, 'The workflow waits for the batch');
      Assert.isTrue(r.completedSteps.contains(RESERVE));
      // The batch job and the queued orchestrator run here.
      Test.stopTest();

      WorkflowEngine.processWatchdogHeartbeat();
      r = harness.drive();

      Assert.areEqual('Completed', r.status);
      Assert.isTrue(r.completedSteps.contains(TAG_STEP));
      Assert.isTrue(r.completedSteps.contains(CONFIRM));
      Assert.isFalse(r.executedSteps.contains(ROLLBACK_STEP));
      Assert.areEqual(
        2,
        [SELECT COUNT() FROM Account WHERE Description = 'Q3-Review'],
        'The batch tags the matching accounts only'
      );
      Assert.areEqual(
        1,
        [
          SELECT COUNT()
          FROM AsyncApexJob
          WHERE JobType = 'BatchApex' AND ApexClass.Name = 'ExampleAccountTagBatch'
        ],
        'Zero double-launch'
      );
    }
  }

  @IsTest
  static void testFailedBatchRoutesToRollbackAndCompensates() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id jobId = '707000000000009';
      WorkflowBatchJobs.stubLaunchId = jobId;
      Test.startTest();
      Id instanceId = WorkflowEngine.start(WORKFLOW, 'batch-ex-fail', workflowInput());
      WorkflowTestHarness harness = new WorkflowTestHarness(instanceId);
      Assert.isTrue(harness.drive().isSuspended);

      WorkflowBatchJobs.stubJobs = new Map<Id, AsyncApexJob>{
        jobId => (AsyncApexJob) JSON.deserialize(
          JSON.serialize(
            new Map<String, Object>{
              'attributes' => new Map<String, Object>{ 'type' => 'AsyncApexJob' },
              'Id' => jobId,
              'Status' => 'Failed',
              'TotalJobItems' => 0,
              'JobItemsProcessed' => 0,
              'NumberOfErrors' => 0,
              'ExtendedStatus' => 'start() threw'
            }
          ),
          AsyncApexJob.class
        )
      };
      WorkflowEngine.processWatchdogHeartbeat();
      WorkflowTestHarness.Result r = harness.drive();
      Test.stopTest();

      Assert.areEqual('Compensated', r.status, 'A failed batch is not a stall');
      Assert.isTrue(r.executedSteps.contains(ROLLBACK_STEP), 'getNextStep routes it');
      Assert.areEqual(
        new List<String>{ RESERVE + '_Compensate' },
        r.compensatedSteps,
        'The step before the batch is compensated'
      );
      Assert.areEqual(1, WorkflowBatchJobs.launchCount, 'Zero double-launch');
    }
  }
}
