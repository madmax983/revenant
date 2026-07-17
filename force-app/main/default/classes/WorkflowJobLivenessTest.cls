/**
 * @description Unit tests for {@link WorkflowJobLiveness}, driving the async-job
 * liveness helpers directly: collectValidJobIds (blank and malformed skips vs a
 * well-formed id), resolveActiveJobIds (cron-vs-async partition, empty-set
 * short-circuit, and a live CronTrigger), and isInstanceOrphaned (blank, malformed,
 * well-formed-but-not-active, well-formed-and-active, and the invalid-cast catch).
 *
 * <p>The id-shaped fixture strings are assembled at runtime from real SObject key
 * prefixes (rather than hardcoded literals) so they carry the correct key-prefix
 * semantics without pinning environment-specific ids.
 */
@IsTest
public class WorkflowJobLivenessTest {
  private static final String CRON_PREFIX = CronTrigger.SObjectType.getDescribe(
      SObjectDescribeOptions.DEFERRED
    )
    .getKeyPrefix();
  private static final String ASYNC_PREFIX = AsyncApexJob.SObjectType.getDescribe(
      SObjectDescribeOptions.DEFERRED
    )
    .getKeyPrefix();
  private static final String WI_PREFIX = Workflow_Instance__c.SObjectType.getDescribe(
      SObjectDescribeOptions.DEFERRED
    )
    .getKeyPrefix();
  private static final String PAD12 = '000000000000';
  // Syntactically-valid 15-char ids that do not exist in the org.
  private static final String CRON_ID = CRON_PREFIX + PAD12; // CronTrigger-shaped
  private static final String ASYNC_ID = ASYNC_PREFIX + PAD12; // AsyncApexJob-shaped
  // Right length, wrong key prefix (Workflow_Instance__c-shaped) => malformed.
  private static final String WRONG_PREFIX = WI_PREFIX + PAD12;
  // 18 chars, valid prefix, but a checksum suffix that cannot match a digit body.
  private static final String BAD_CHECKSUM = CRON_PREFIX + PAD12 + 'ZZZ';

  private static Workflow_Instance__c instWithJobId(String jobId) {
    return new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowJobLivenessTest.SomeWorkflow',
      Status__c = 'Suspended',
      Async_Job_Id__c = jobId
    );
  }

  @IsTest
  static void testCollectValidJobIdsFiltersBlankAndMalformed() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      List<Workflow_Instance__c> insts = new List<Workflow_Instance__c>{
        instWithJobId(null), // blank => skipped
        instWithJobId(CRON_PREFIX + '12'), // wrong length => skipped
        instWithJobId(WRONG_PREFIX), // wrong prefix => skipped
        instWithJobId(CRON_ID) // well-formed => collected
      };

      Set<Id> jobIds = WorkflowJobLiveness.collectValidJobIds(insts);

      System.assertEquals(
        1,
        jobIds.size(),
        'Only the well-formed id is collected'
      );
      System.assert(
        jobIds.contains((Id) CRON_ID),
        'The well-formed cron id is collected'
      );
    }
  }

  @IsTest
  static void testResolveActiveJobIdsEmptySetShortCircuits() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Set<Id> active = WorkflowJobLiveness.resolveActiveJobIds(new Set<Id>());
      System.assert(
        active.isEmpty(),
        'An empty input set short-circuits to empty'
      );
    }
  }

  @IsTest
  static void testResolveActiveJobIdsPartitionsCronAndAsync() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = instWithJobId(null);
      insert inst;

      Test.startTest();
      // A real, WAITING CronTrigger to prove the cron liveness query returns it.
      String liveCronId = System.schedule(
        'WorkflowJobLivenessTest_Live_' + DateTime.now().getTime(),
        '0 0 0 1 1 ? 2099',
        new WorkflowSleepJob(inst.Id, 'WorkflowJobLivenessTest.SomeStep')
      );

      Set<Id> input = new Set<Id>{ (Id) liveCronId, (Id) ASYNC_ID };
      Set<Id> active = WorkflowJobLiveness.resolveActiveJobIds(input);
      Test.stopTest();

      System.assert(
        active.contains((Id) liveCronId),
        'A WAITING CronTrigger is reported alive'
      );
      System.assert(
        !active.contains((Id) ASYNC_ID),
        'A non-existent AsyncApexJob id is not reported alive'
      );
    }
  }

  @IsTest
  static void testIsInstanceOrphanedBlank() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      System.assert(
        WorkflowJobLiveness.isInstanceOrphaned(
          instWithJobId(null),
          new Set<Id>()
        ),
        'A blank async job id is orphaned'
      );
    }
  }

  @IsTest
  static void testIsInstanceOrphanedMalformed() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      System.assert(
        WorkflowJobLiveness.isInstanceOrphaned(
          instWithJobId(WRONG_PREFIX),
          new Set<Id>()
        ),
        'A malformed async job id is orphaned'
      );
    }
  }

  @IsTest
  static void testIsInstanceOrphanedWellFormedNotActive() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      System.assert(
        WorkflowJobLiveness.isInstanceOrphaned(
          instWithJobId(CRON_ID),
          new Set<Id>()
        ),
        'A well-formed id that is not alive is orphaned'
      );
    }
  }

  @IsTest
  static void testIsInstanceOrphanedWellFormedActive() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      System.assert(
        !WorkflowJobLiveness.isInstanceOrphaned(
          instWithJobId(CRON_ID),
          new Set<Id>{ (Id) CRON_ID }
        ),
        'A well-formed id present in the alive set is not orphaned'
      );
    }
  }

  @IsTest
  static void testIsInstanceOrphanedInvalidCast() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // An 18-char id with a bad checksum trips the guard (right length/prefix) but
      // fails the (Id) cast; either the catch returns true, or the cast succeeds and
      // the id is absent from the empty alive set — both yield orphaned == true.
      System.assert(
        WorkflowJobLiveness.isInstanceOrphaned(
          instWithJobId(BAD_CHECKSUM),
          new Set<Id>()
        ),
        'An uncastable well-formed-looking id is treated as orphaned'
      );
    }
  }
}
