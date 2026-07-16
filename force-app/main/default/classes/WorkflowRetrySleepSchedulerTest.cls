/**
 * @description Unit tests for {@link WorkflowRetrySleepScheduler}, driving both public
 * scheduling primitives (scheduleRetry / scheduleSleepResume) directly.
 *
 * <p>Coverage notes on intentionally-uncovered branches:
 * <ul>
 *   <li>The minute-granular queueable fast path is gated behind
 *       {@code !Test.isRunningTest()} (qualifiesForMinuteQueueable), so it is
 *       unreachable under test — every in-test call deterministically takes the
 *       Scheduled Apex cron path instead.</li>
 *   <li>The AsyncException / Exception &rarr; null catch arms depend on hitting a
 *       platform scheduling limit, which cannot be forced deterministically, so
 *       they are left uncovered.</li>
 * </ul>
 * These tests therefore assert the dynamic-scheduling-off short-circuit and the
 * cron-scheduling path (including the sleep job-name prefix branch).
 */
@IsTest
public class WorkflowRetrySleepSchedulerTest {
  private static final String STEP_NAME = 'WorkflowRetrySleepSchedulerTest.SomeStep';

  private static Id newInstanceId() {
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowRetrySleepSchedulerTest.SomeWorkflow',
      Correlation_Key__c = 'sched-' + Math.abs(Crypto.getRandomInteger()),
      Status__c = 'Suspended'
    );
    insert inst;
    return inst.Id;
  }

  @IsTest
  static void testDynamicSchedulingOffReturnsNull() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id instanceId = newInstanceId();
      Boolean prior = WorkflowEngine.useDynamicScheduling;
      WorkflowEngine.useDynamicScheduling = false;
      try {
        String retryJob = WorkflowRetrySleepScheduler.scheduleRetry(
          instanceId,
          STEP_NAME,
          120
        );
        String sleepJob = WorkflowRetrySleepScheduler.scheduleSleepResume(
          instanceId,
          STEP_NAME,
          120
        );
        System.assertEquals(
          null,
          retryJob,
          'scheduleRetry returns null when dynamic scheduling is off'
        );
        System.assertEquals(
          null,
          sleepJob,
          'scheduleSleepResume returns null when dynamic scheduling is off'
        );
      } finally {
        WorkflowEngine.useDynamicScheduling = prior;
      }
    }
  }

  @IsTest
  static void testScheduleRetryTakesCronPath() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id instanceId = newInstanceId();
      WorkflowEngine.useDynamicScheduling = true;

      Test.startTest();
      // 130s is not a whole minute, and under test the queueable fast path is gated
      // off regardless, so this deterministically takes the cron-schedule path.
      String jobId = WorkflowRetrySleepScheduler.scheduleRetry(
        instanceId,
        STEP_NAME,
        130
      );
      Test.stopTest();

      System.assertNotEquals(
        null,
        jobId,
        'The cron path returns a scheduled job Id'
      );
      System.assertEquals(
        1,
        [
          SELECT COUNT()
          FROM CronTrigger
          WHERE Id = :jobId
        ],
        'A CronTrigger was created for the scheduled retry'
      );
    }
  }

  @IsTest
  static void testScheduleSleepResumeTakesCronPathWithJobNamePrefix() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id instanceId = newInstanceId();
      WorkflowEngine.useDynamicScheduling = true;

      Test.startTest();
      // Exercises the getSleepJobPrefix-based job-name branch on the cron path.
      String jobId = WorkflowRetrySleepScheduler.scheduleSleepResume(
        instanceId,
        STEP_NAME,
        130
      );
      Test.stopTest();

      System.assertNotEquals(
        null,
        jobId,
        'The cron path returns a scheduled sleep-resume job Id'
      );
      CronTrigger ct = [
        SELECT Id, CronJobDetail.Name
        FROM CronTrigger
        WHERE Id = :jobId
        LIMIT 1
      ];
      System.assert(
        ct.CronJobDetail.Name.startsWith('WorkflowSleep_'),
        'The sleep job name uses the WorkflowSleep_ prefix: ' +
        ct.CronJobDetail.Name
      );
    }
  }
}
