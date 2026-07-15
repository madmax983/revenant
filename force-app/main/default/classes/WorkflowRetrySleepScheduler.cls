/**
 * @description Sleep- and retry-job (re)scheduling primitives for the Revenant
 * engine. Schedules the async job that wakes a Suspended instance after a retry
 * backoff or a sleep/admission-retry delay, choosing a minute-granular Queueable
 * fast path when the delay qualifies and falling back to a deterministically
 * named Scheduled Apex cron job otherwise. Scheduling is best-effort and gated on
 * `WorkflowEngine.useDynamicScheduling`; the watchdog heartbeat is the backstop
 * when a scheduling limit is hit. Extracted from `WorkflowEngine`.
 */
public inherited sharing class WorkflowRetrySleepScheduler {
  /**
   * Determines whether a delay can be scheduled as a minute-granular queueable job.
   * @param delaySeconds the configured delay in seconds
   * @return true when the delay qualifies for a minute-granular queueable job
   *   (outside test, 60-600s, whole minutes) and queueable budget remains
   */
  private static Boolean qualifiesForMinuteQueueable(Integer delaySeconds) {
    return !Test.isRunningTest() &&
      delaySeconds >= 60 &&
      delaySeconds <= 600 &&
      Math.mod(delaySeconds, 60) == 0 &&
      Limits.getQueueableJobs() < Limits.getLimitQueueableJobs();
  }

  /**
   * @description Schedules the retry job that re-drives a step after a backoff
   * delay, returning the async job Id (or null when dynamic scheduling is off or
   * a scheduling limit is hit).
   * @param instanceId Id of the instance to re-drive
   * @param stepName name of the step to retry
   * @param delaySeconds the backoff delay in seconds
   * @return the scheduled/enqueued job Id, or null when not scheduled
   */
  public static String scheduleRetry(
    Id instanceId,
    String stepName,
    Integer delaySeconds
  ) {
    if (!WorkflowEngine.useDynamicScheduling) {
      return null;
    }
    try {
      if (qualifiesForMinuteQueueable(delaySeconds)) {
        return String.valueOf(
          System.enqueueJob(
            new WorkflowRetryJob.QueueableRetryJob(instanceId, stepName),
            delaySeconds / 60
          )
        );
      }
      WorkflowRetryJob job = new WorkflowRetryJob(instanceId, stepName);
      Datetime runTime = Datetime.now()
        .addSeconds(Test.isRunningTest() ? delaySeconds + 60 : delaySeconds);
      String cronStr =
        runTime.second() +
        ' ' +
        runTime.minute() +
        ' ' +
        runTime.hour() +
        ' ' +
        runTime.day() +
        ' ' +
        runTime.month() +
        ' ? ' +
        runTime.year();
      return String.valueOf(
        System.schedule(
          'WorkflowRetry_' + instanceId + '_' + runTime.getTime(),
          cronStr,
          job
        )
      );
    } catch (AsyncException ignored) {
      // Scheduling limit reached; the watchdog heartbeat re-drives the retry instead.
      return null;
    } catch (Exception ignored) {
      // Retry scheduling is best-effort; the watchdog heartbeat is the backstop.
      return null;
    }
  }

  /**
   * @description Schedules the sleep-resume job that wakes a Suspended instance
   * after a sleep or admission-retry delay, returning the async job Id (or null
   * when dynamic scheduling is off or a scheduling limit is hit).
   * @param instanceId Id of the sleeping instance
   * @param stepName name of the sleeping step
   * @param delaySeconds the sleep delay in seconds
   * @return the scheduled/enqueued job Id, or null when not scheduled
   */
  public static String scheduleSleepResume(
    Id instanceId,
    String stepName,
    Integer delaySeconds
  ) {
    if (!WorkflowEngine.useDynamicScheduling) {
      return null;
    }
    try {
      if (qualifiesForMinuteQueueable(delaySeconds)) {
        return String.valueOf(
          System.enqueueJob(
            new WorkflowSleepJob.QueueableSleepJob(instanceId, stepName),
            delaySeconds / 60
          )
        );
      }
      WorkflowSleepJob job = new WorkflowSleepJob(instanceId, stepName);
      Datetime runTime = Datetime.now()
        .addSeconds(Test.isRunningTest() ? delaySeconds + 60 : delaySeconds);
      String cronStr =
        runTime.second() +
        ' ' +
        runTime.minute() +
        ' ' +
        runTime.hour() +
        ' ' +
        runTime.day() +
        ' ' +
        runTime.month() +
        ' ? ' +
        runTime.year();
      String jobName =
        WorkflowStepTimeoutConfig.getSleepJobPrefix(instanceId, stepName) +
        '_' +
        runTime.getTime();
      return String.valueOf(System.schedule(jobName, cronStr, job));
    } catch (AsyncException ignored) {
      // Scheduling limit reached; the watchdog heartbeat resumes the sleep instead.
      return null;
    } catch (Exception ignored) {
      // Sleep scheduling is best-effort; the watchdog heartbeat is the backstop.
      return null;
    }
  }
}
