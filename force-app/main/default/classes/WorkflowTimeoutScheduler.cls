/**
 * @description Per-step dynamic timeout job scheduling for the Revenant engine.
 * Schedules the watchdog-enforced deadline job for a single step when a positive
 * timeout is configured and dynamic scheduling is enabled, choosing a
 * minute-granular Queueable fast path when the timeout qualifies and falling back
 * to a deterministically named Scheduled Apex cron job otherwise (clearing any
 * stale same-named job first). All scheduling is best-effort and gated on
 * `WorkflowEngine.useDynamicScheduling`; the watchdog heartbeat is the backstop.
 * Extracted from `WorkflowEngine`; step timeout durations resolve via
 * {@link WorkflowStepTimeoutConfig}; instance-level arming lives on
 * {@link WorkflowTimeoutArming}.
 */
public inherited sharing class WorkflowTimeoutScheduler {
  /**
   * @description Schedules a dynamic timeout job for a step when one is configured,
   * resolving the workflow namespace from the instance.
   * @param instanceId Id of the instance owning the step
   * @param stepName name of the step to arm a timeout for
   */
  public static void scheduleTimeoutJobIfNeeded(
    Id instanceId,
    String stepName
  ) {
    scheduleTimeoutJobIfNeeded(instanceId, stepName, null);
  }

  /**
   * @description Schedules a dynamic timeout job for a step when a positive timeout
   * is configured and dynamic scheduling is enabled. The workflow name, when
   * supplied, avoids a namespace-resolving query.
   * @param instanceId Id of the instance owning the step
   * @param stepName name of the step to arm a timeout for
   * @param workflowName developer name of the workflow, or null to resolve it
   */
  public static void scheduleTimeoutJobIfNeeded(
    Id instanceId,
    String stepName,
    String workflowName
  ) {
    if (String.isBlank(stepName) || !WorkflowEngine.useDynamicScheduling) {
      return;
    }
    try {
      String ns = resolveNamespaceForStep(instanceId, workflowName);
      Integer timeoutSeconds = WorkflowStepTimeoutConfig.getStepTimeoutSeconds(
        stepName,
        ns
      );
      if (timeoutSeconds == null || timeoutSeconds <= 0) {
        return;
      }
      if (tryEnqueueTimeoutJob(instanceId, stepName, timeoutSeconds)) {
        return;
      }
      scheduleTimeoutCronJob(instanceId, stepName, timeoutSeconds);
    } catch (AsyncException ignored) {
      // Scheduling limit reached; the watchdog heartbeat enforces the timeout instead.
    } catch (Exception ignored) {
      // Timeout scheduling is best-effort; the watchdog heartbeat is the backstop.
    }
  }

  /**
   * Resolves the namespace for timeout scheduling, using the supplied workflow
   * name when present to avoid a query, otherwise looking it up by instance.
   * @param instanceId the instance owning the step
   * @param workflowName the workflow developer name, or null to resolve it
   * @return the resolved namespace, or null when it cannot be determined
   */
  private static String resolveNamespaceForStep(
    Id instanceId,
    String workflowName
  ) {
    if (String.isNotBlank(workflowName)) {
      return WorkflowTypeResolver.extractNamespace(workflowName);
    }
    List<Workflow_Instance__c> insts = [
      SELECT Workflow_Name__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
      WITH SYSTEM_MODE
      LIMIT 1
    ];
    if (insts.isEmpty()) {
      return null;
    }
    return WorkflowTypeResolver.extractNamespace(insts[0].Workflow_Name__c);
  }

  /**
   * Fast path: enqueues a minute-granular queueable timeout job when the timeout
   * qualifies (outside test, 60-600s, whole minutes) and queueable budget remains.
   * @param instanceId the instance owning the step
   * @param stepName the step to arm a timeout for
   * @param timeoutSeconds the configured positive timeout in seconds
   * @return true when a queueable job was enqueued (caller is done), else false
   */
  private static Boolean tryEnqueueTimeoutJob(
    Id instanceId,
    String stepName,
    Integer timeoutSeconds
  ) {
    if (
      Test.isRunningTest() ||
      timeoutSeconds < 60 ||
      timeoutSeconds > 600 ||
      Math.mod(timeoutSeconds, 60) != 0
    ) {
      return false;
    }
    if (Limits.getQueueableJobs() >= Limits.getLimitQueueableJobs()) {
      return false;
    }
    System.enqueueJob(
      new WorkflowTimeoutJob.QueueableTimeoutJob(instanceId, stepName),
      timeoutSeconds / 60
    );
    return true;
  }

  /**
   * Schedules a cron-based timeout job, first clearing any stale deterministically
   * -named job so a re-schedule is registered rather than silently dropped.
   * @param instanceId the instance owning the step
   * @param stepName the step to arm a timeout for
   * @param timeoutSeconds the configured positive timeout in seconds
   */
  private static void scheduleTimeoutCronJob(
    Id instanceId,
    String stepName,
    Integer timeoutSeconds
  ) {
    WorkflowTimeoutJob job = new WorkflowTimeoutJob(instanceId, stepName);
    Datetime runTime = Datetime.now()
      .addSeconds(Test.isRunningTest() ? timeoutSeconds + 60 : timeoutSeconds);
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
    String cleanStepName = stepName.replaceAll('[^a-zA-Z0-9]', '_');
    String jobName = 'Timeout_' + instanceId + '_' + cleanStepName;
    // The job name is deterministic, so a re-schedule (e.g. retry, or a yielded step
    // that re-enters before its prior timeout job fires) collides with the existing
    // scheduled job and System.schedule() throws. Clear any stale job with this name
    // first so the new timeout is actually registered instead of silently dropped.
    cancelTimeoutJob(instanceId, stepName);
    System.schedule(jobName, cronStr, job);
  }

  /**
   * @description Aborts the deterministically named timeout cron job for a step,
   * if one is currently scheduled. Abort failures are swallowed (the job may have
   * already fired or been removed).
   * @param instanceId Id of the instance owning the step
   * @param stepName name of the step whose timeout job is aborted
   */
  public static void cancelTimeoutJob(Id instanceId, String stepName) {
    String cleanStepName = stepName.replaceAll('[^a-zA-Z0-9]', '_');
    String jobName = 'Timeout_' + instanceId + '_' + cleanStepName;
    List<CronTrigger> triggers = [
      SELECT Id
      FROM CronTrigger
      WHERE CronJobDetail.Name = :jobName
      WITH SYSTEM_MODE
    ];
    for (CronTrigger triggerJob : triggers) {
      try {
        System.abortJob(triggerJob.Id);
      } catch (Exception ignored) {
        // Job may already have fired or been removed; nothing further to do.
      }
    }
  }
}
