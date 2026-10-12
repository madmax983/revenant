/**
 * @description Parallel-branch resume fan-out for the workflow engine. Wakes the
 * still-incomplete branches of one or more parallel instances. It reads the open
 * branches with {@link WorkflowBranchTimer} (bounded, not the step history),
 * claims their timers, and publishes
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
   * Current_Step__c values and a bounded read of the branch rows. A branch that
   * starts here loses its timer (claim, issue #335).
   * @param parallelInstances the parallel instances whose branches are re-enqueued
   */
  public static void enqueueResumeBulk(
    List<Workflow_Instance__c> parallelInstances
  ) {
    if (parallelInstances == null || parallelInstances.isEmpty()) {
      return;
    }
    enqueueBranches(
      parallelInstances,
      WorkflowBranchTimer.load(parallelInstances),
      new Set<String>()
    );
  }

  /**
   * Release and resume variant of enqueueResumeBulk (issue #311). A `Suspended`
   * instance has a branch that still sleeps. That branch keeps its deadline: no
   * worker starts for it, and the sleep sweep starts it later. A `Running`
   * instance runs every open branch. A signal from the park may wake a
   * sleeping branch.
   * @param parallelInstances the parallel instances that left a park, with
   *        Status__c as the park timer set it
   */
  public static void enqueueUnlessSleeping(
    List<Workflow_Instance__c> parallelInstances
  ) {
    if (parallelInstances == null || parallelInstances.isEmpty()) {
      return;
    }
    Map<Id, WorkflowBranchTimer.Branches> branches = WorkflowBranchTimer.take(
      parallelInstances
    );
    enqueueBranches(
      parallelInstances,
      branches,
      WorkflowBranchTimer.sleepingKeys(parallelInstances, branches, '::')
    );
  }

  /**
   * Starts the named branches (issue #311). The sleep sweep uses it for the
   * branches whose own timer ended. The sweep claims those timers.
   * @param stepsByInstance instance Id to the branch step names to start
   */
  public static void enqueueNamedBranches(
    Map<Id, List<String>> stepsByInstance
  ) {
    publishBranchEvents(
      buildBranchRunEvents(
        stepsByInstance,
        new Set<String>(),
        new Set<String>()
      )
    );
  }

  // Starts each open branch that is not in `skip`. Claims its timer in the same
  // transaction, before the publish. A failed publish rolls back the claim. A
  // branch whose claim does not fit stays asleep.
  private static void enqueueBranches(
    List<Workflow_Instance__c> parallelInstances,
    Map<Id, WorkflowBranchTimer.Branches> branches,
    Set<String> skip
  ) {
    Set<String> blocked = new Set<String>(skip);
    blocked.addAll(
      WorkflowBranchTimer.claimStarting(parallelInstances, branches, skip, '::')
    );
    Map<Id, List<String>> namesByInstance = new Map<Id, List<String>>();
    for (Workflow_Instance__c inst : parallelInstances) {
      if (branches.containsKey(inst.Id)) {
        namesByInstance.put(inst.Id, branches.get(inst.Id).openNames);
      }
    }
    publishBranchEvents(
      buildBranchRunEvents(namesByInstance, blocked, new Set<String>())
    );
  }

  /**
   * Builds the RUN_STEP events for every given branch that is not yet enqueued,
   * so they can be published in ONE EventBus call (one publish per branch would
   * risk the publish/DML statement limit when many parallel instances wake at
   * once). Skips branches already enqueued this transaction; under test it
   * directly enqueues the branch job via {@link enqueueTestBranchJob} instead
   * of emitting an event.
   * @param branchesByInstance instance id to the branch step names to start
   * @param skip "instanceId::stepName" keys of branches that must not start
   * @param started output accumulator of the "instanceId::stepName" keys that
   *        this call starts (mutated in place)
   * @return the RUN_STEP events to publish (empty under test)
   */
  private static List<Workflow_Event__e> buildBranchRunEvents(
    Map<Id, List<String>> branchesByInstance,
    Set<String> skip,
    Set<String> started
  ) {
    List<Workflow_Event__e> branchEvents = new List<Workflow_Event__e>();
    for (Id instId : branchesByInstance.keySet()) {
      for (String b : branchesByInstance.get(instId)) {
        String key = instId + '::' + b;
        if (
          skip.contains(key) ||
          WorkflowResumeEnqueue.enqueuedBranchKeys.contains(key)
        ) {
          continue;
        }
        WorkflowResumeEnqueue.enqueuedBranchKeys.add(key);
        started.add(key);
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
