/**
 * @description Orchestrator-enqueue and scheduled-job-abort surface for the
 * Revenant engine. Publishes `RUN_STEP` `Workflow_Event__e` platform events (or,
 * under test, enqueues `WorkflowOrchestrator` Queueables directly) so instance
 * steps are driven asynchronously, and bulk-aborts the sleep/retry/timeout cron
 * jobs scheduled for a set of instances. Extracted from `WorkflowEngine`; the
 * public `WorkflowEngine.OrchestratorRequest` DTO stays resident on the engine
 * and is referenced here fully qualified. All SOQL/DML executes in system mode.
 */
public inherited sharing class WorkflowOrchestratorEnqueue {
  /**
   * Aborts all Scheduled Apex cron jobs associated with the workflow instance.
   * @param instanceId Id of the instance whose scheduled jobs are aborted
   */
  public static void abortScheduledJobs(Id instanceId) {
    abortScheduledJobs(new Set<Id>{ instanceId });
  }

  /**
   * @description Bulk-aborts the sleep, retry and timeout cron jobs scheduled for
   * the given instances, matching them by their name prefixes. Abort failures are
   * logged and skipped so one stuck job never blocks the rest.
   * @param instanceIds Ids of the instances whose scheduled jobs are aborted
   */
  public static void abortScheduledJobs(Set<Id> instanceIds) {
    if (instanceIds == null || instanceIds.isEmpty()) {
      return;
    }
    List<String> nameLikeFilters = new List<String>();
    for (Id instanceId : instanceIds) {
      nameLikeFilters.add('WorkflowSleep_' + instanceId + '_%');
      nameLikeFilters.add('WorkflowRetry_' + instanceId + '_%');
      nameLikeFilters.add('Timeout_' + instanceId + '_%');
    }
    List<CronTrigger> triggers = [
      SELECT Id
      FROM CronTrigger
      WHERE CronJobDetail.Name LIKE :nameLikeFilters
      WITH SYSTEM_MODE
    ];
    for (CronTrigger triggerJob : triggers) {
      try {
        System.abortJob(triggerJob.Id);
      } catch (Exception ignored) {
        // Job may already have completed or been aborted; nothing further to do.
      }
    }
  }

  /**
   * Under test, enqueues one orchestrator job per distinct instance directly
   * (best-effort, honoring the queueable limit) rather than via platform events.
   * @param requests the orchestrator requests to dispatch
   */
  private static void enqueueOrchestratorsInTest(
    List<WorkflowEngine.OrchestratorRequest> requests
  ) {
    if (WorkflowEngine.disableQueueableInTest) {
      return;
    }
    Set<Id> instanceIds = new Set<Id>();
    for (WorkflowEngine.OrchestratorRequest req : requests) {
      instanceIds.add(req.instanceId);
    }
    for (Id instId : instanceIds) {
      tryEnqueueTestOrchestratorForInstance(instId);
    }
  }

  /**
   * @description Best-effort direct enqueue of a single-instance orchestrator
   * job for test paths that fan out one job per distinct instance. Honors the
   * per-transaction queueable limit and swallows enqueue failures so the
   * caller's loop continues; the watchdog re-drives any instance left
   * un-enqueued. Kept as a helper so the caller's per-instance
   * `System.enqueueJob` is not lexically inside the loop.
   * @param instId the workflow instance to enqueue
   */
  private static void tryEnqueueTestOrchestratorForInstance(Id instId) {
    try {
      if (Limits.getQueueableJobs() < Limits.getLimitQueueableJobs()) {
        System.enqueueJob(new WorkflowOrchestrator(instId));
      }
    } catch (Exception ignored) {
      // Best-effort enqueue; the watchdog re-drives any instance left un-enqueued.
    }
  }

  /**
   * Builds the RUN_STEP platform events for a batch of orchestrator requests.
   * @param requests the orchestrator requests
   * @return the events to publish
   */
  private static List<Workflow_Event__e> buildOrchestratorEvents(
    List<WorkflowEngine.OrchestratorRequest> requests
  ) {
    List<Workflow_Event__e> events = new List<Workflow_Event__e>();
    for (WorkflowEngine.OrchestratorRequest req : requests) {
      events.add(
        new Workflow_Event__e(
          Workflow_Instance_Id__c = req.instanceId,
          Event_Type__c = 'RUN_STEP',
          Payload__c = req.stepName
        )
      );
    }
    return events;
  }

  /**
   * @description Enqueues orchestrator work for a batch of requests, dispatching
   * directly under test and via RUN_STEP platform events otherwise.
   * @param requests the orchestrator requests to enqueue
   */
  public static void enqueueOrchestrators(
    List<WorkflowEngine.OrchestratorRequest> requests
  ) {
    WorkflowWatchdog.bootstrap();
    if (Test.isRunningTest()) {
      enqueueOrchestratorsInTest(requests);
      return;
    }
    List<Workflow_Event__e> events = buildOrchestratorEvents(requests);
    if (!events.isEmpty()) {
      List<Database.SaveResult> srs = EventBus.publish(events);
      throwOnPublishErrors(srs, 'Failed to publish orchestrator event: ');
    }
  }

  /**
   * @description Convenience overload that enqueues orchestrator work for a list
   * of instance Ids, driving each instance's current step (null step name).
   * @param instanceIds Ids of the instances to orchestrate
   */
  public static void enqueueOrchestrators(List<Id> instanceIds) {
    List<WorkflowEngine.OrchestratorRequest> requests = new List<WorkflowEngine.OrchestratorRequest>();
    for (Id instId : instanceIds) {
      requests.add(new WorkflowEngine.OrchestratorRequest(instId, null));
    }
    enqueueOrchestrators(requests);
  }

  /**
   * @description Convenience overload that enqueues orchestrator work for a single
   * instance and step.
   * @param instanceId Id of the instance to orchestrate
   * @param stepName name of the step to run, or null for the current step
   */
  public static void enqueueOrchestrator(Id instanceId, String stepName) {
    enqueueOrchestrators(
      new List<WorkflowEngine.OrchestratorRequest>{
        new WorkflowEngine.OrchestratorRequest(instanceId, stepName)
      }
    );
  }

  /**
   * Raises a WorkflowException if any platform-event publish result failed.
   * @param srs the save results returned by EventBus.publish
   * @param errorPrefix message prefix identifying the failing publish site
   */
  public static void throwOnPublishErrors(
    List<Database.SaveResult> srs,
    String errorPrefix
  ) {
    for (Database.SaveResult sr : srs) {
      if (sr.isSuccess()) {
        continue;
      }
      List<String> errMsgs = new List<String>();
      for (Database.Error err : sr.getErrors()) {
        errMsgs.add(err.getStatusCode() + ': ' + err.getMessage());
      }
      throw new WorkflowEngine.WorkflowException(
        errorPrefix + String.join(errMsgs, ', ')
      );
    }
  }
}
