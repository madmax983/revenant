/**
 * @description Parallel-branch resume fan-out for the workflow engine. Wakes the
 * still-incomplete branches of one or more parallel instances by resolving each
 * branch's latest status in a single batched step-execution query and publishing
 * one RUN_STEP event per unfinished branch in a single EventBus call (bounding the
 * publish/DML-statement cost when many parallel instances wake at once). Split out
 * of {@link WorkflowResumeEnqueue} to keep each resume unit under the complexity
 * budget; it consults that class's per-branch enqueue guard, called qualified. The
 * `WorkflowEngine.WorkflowException` type is referenced fully qualified. All DML
 * and SOQL run in system mode.
 */
public inherited sharing class WorkflowBranchResume {
  /**
   * Bulk variant of enqueueResume for the bulk signal() path: wakes the
   * incomplete branches of many parallel instances using the already-loaded
   * Current_Step__c values and ONE step-execution query across all of them,
   * instead of two queries per instance.
   * @param parallelInstances the parallel instances whose branches are re-enqueued
   */
  public static void enqueueResumeBulk(
    List<Workflow_Instance__c> parallelInstances
  ) {
    if (parallelInstances == null || parallelInstances.isEmpty()) {
      return;
    }
    Set<String> allBranchNames = new Set<String>();
    Map<Id, List<String>> branchesByInstance = mapBranchesByInstance(
      parallelInstances,
      allBranchNames
    );
    Map<String, String> latestStatusByKey = loadLatestBranchStatuses(
      branchesByInstance.keySet(),
      allBranchNames
    );
    List<Workflow_Event__e> branchEvents = buildBranchRunEvents(
      branchesByInstance,
      latestStatusByKey
    );
    publishBranchEvents(branchEvents);
  }

  /**
   * Maps each parallel instance to its trimmed branch step names and collects
   * every branch name across the batch for a single step-execution lookup.
   * @param parallelInstances the parallel instances whose Current_Step__c
   *        comma lists to split into branch names
   * @param allBranchNames output accumulator populated with every branch name
   *        seen across the batch (mutated in place)
   * @return a map of instance id to its ordered list of branch step names
   */
  private static Map<Id, List<String>> mapBranchesByInstance(
    List<Workflow_Instance__c> parallelInstances,
    Set<String> allBranchNames
  ) {
    Map<Id, List<String>> branchesByInstance = new Map<Id, List<String>>();
    for (Workflow_Instance__c inst : parallelInstances) {
      List<String> branches = new List<String>();
      for (String b : inst.Current_Step__c.split(',')) {
        branches.add(b.trim());
        allBranchNames.add(b.trim());
      }
      branchesByInstance.put(inst.Id, branches);
    }
    return branchesByInstance;
  }

  /**
   * Loads the latest step-execution status per (instance, branch step name)
   * across the whole batch in a single query. Newest-first ordering means the
   * first row seen for a key is the latest, so earlier map entries win.
   * @param instanceIds the parallel instance ids to load branch statuses for
   * @param allBranchNames the branch step names to restrict the query to
   * @return a map of "instanceId::stepName" to the latest execution status
   */
  private static Map<String, String> loadLatestBranchStatuses(
    Set<Id> instanceIds,
    Set<String> allBranchNames
  ) {
    Map<String, String> latestStatusByKey = new Map<String, String>();
    for (Workflow_Step_Execution__c se : [
      SELECT Workflow_Instance__c, Step_Name__c, Status__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c IN :instanceIds
        AND Step_Name__c IN :allBranchNames
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC, Id DESC
    ]) {
      String key = se.Workflow_Instance__c + '::' + se.Step_Name__c;
      if (!latestStatusByKey.containsKey(key)) {
        latestStatusByKey.put(key, se.Status__c);
      }
    }
    return latestStatusByKey;
  }

  /**
   * Builds the RUN_STEP events for every incomplete, not-yet-enqueued branch,
   * so they can be published in ONE EventBus call (one publish per branch would
   * risk the publish/DML statement limit when many parallel instances wake at
   * once). Skips branches already Completed/OperatorSkipped and branches
   * already enqueued this transaction; under test it directly enqueues the
   * branch job via {@link enqueueTestBranchJob} instead of emitting an event.
   * @param branchesByInstance instance id to its branch step names
   * @param latestStatusByKey "instanceId::stepName" to latest branch status
   * @return the RUN_STEP events to publish (empty under test)
   */
  private static List<Workflow_Event__e> buildBranchRunEvents(
    Map<Id, List<String>> branchesByInstance,
    Map<String, String> latestStatusByKey
  ) {
    List<Workflow_Event__e> branchEvents = new List<Workflow_Event__e>();
    for (Id instId : branchesByInstance.keySet()) {
      for (String b : branchesByInstance.get(instId)) {
        String key = instId + '::' + b;
        String status = latestStatusByKey.get(key);
        if (status == 'Completed' || status == 'OperatorSkipped') {
          continue; // branch already finished
        }
        if (WorkflowResumeEnqueue.enqueuedBranchKeys.contains(key)) {
          continue;
        }
        WorkflowResumeEnqueue.enqueuedBranchKeys.add(key);
        if (Test.isRunningTest()) {
          enqueueTestBranchJob(instId, b);
        } else {
          branchEvents.add(
            new Workflow_Event__e(
              Workflow_Instance_Id__c = instId,
              Event_Type__c = 'RUN_STEP',
              Payload__c = b
            )
          );
        }
      }
    }
    return branchEvents;
  }

  /**
   * Publishes the collected branch RUN_STEP events in one EventBus call and
   * bootstraps the watchdog. Throws WorkflowException on any per-event publish
   * failure. No-op when there are no events (e.g. under test).
   * @param branchEvents the RUN_STEP events to publish
   */
  private static void publishBranchEvents(
    List<Workflow_Event__e> branchEvents
  ) {
    if (branchEvents.isEmpty()) {
      return;
    }
    WorkflowWatchdog.bootstrap();
    List<Database.SaveResult> srs = EventBus.publish(branchEvents);
    for (Database.SaveResult sr : srs) {
      if (!sr.isSuccess()) {
        List<String> errMsgs = new List<String>();
        for (Database.Error err : sr.getErrors()) {
          errMsgs.add(err.getStatusCode() + ': ' + err.getMessage());
        }
        throw new WorkflowEngine.WorkflowException(
          'Failed to publish resumed branch event: ' +
          String.join(errMsgs, ', ')
        );
      }
    }
  }

  /**
   * @description Direct-enqueues one branch orchestrator job for the test-only
   * branch of `enqueueResumeBulk`. Kept as a helper so the per-branch
   * `System.enqueueJob` is not lexically inside `enqueueResumeBulk`'s nested
   * loop. Production still batches every branch into a single
   * `EventBus.publish`; this helper is only invoked when `Test.isRunningTest()`
   * is true. Honors `disableQueueableInTest` so tests that suppress queueable
   * dispatch remain suppressed.
   * @param instId the parent workflow instance whose branch is being driven
   * @param branchName the branch step name to enqueue
   */
  private static void enqueueTestBranchJob(Id instId, String branchName) {
    if (!WorkflowEngine.disableQueueableInTest) {
      System.enqueueJob(new WorkflowOrchestrator(instId, branchName));
    }
  }
}
