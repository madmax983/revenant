/**
 * @description Cancellation surface for the Revenant engine. Cancels a workflow
 * instance together with its entire active descendant tree, aborting scheduled
 * jobs and &mdash; on the compensating path &mdash; driving saga rollback of the
 * completed steps. Descendants are gathered breadth-first (one set-based query per
 * tree level) with a visited-id guard rather than by recursive cancel calls, so
 * deep/wide trees cannot exhaust the SOQL or stack-depth governors; parent-before
 * -child ordering and the FOR UPDATE locking are preserved from the pre-extraction
 * engine. Extracted from `WorkflowEngine`, which retains the thin public
 * `cancel`/`cancelWithCompensations` delegators. The resident
 * `WorkflowEngine.WorkflowException`, `WorkflowEngine.disableQueueableInTest`,
 * `WorkflowCompensation.preCreateFirstCompensationStep` and
 * `WorkflowCompensationStepLog.appendCompensationRetryStep` members are referenced fully
 * qualified. All SOQL/DML executes in system mode.
 */
public inherited sharing class WorkflowCancellation {
  /**
   * @description Cancels a workflow instance (and its active descendants) and
   * aborts scheduled jobs WITHOUT running saga compensations.
   * @param instanceId Id of the target instance to cancel (with its active
   * descendants)
   */
  public static void cancelInstance(Id instanceId) {
    cancelInstanceTree(instanceId, false);
  }

  /**
   * @description Cancels a workflow instance (and its active descendants), aborts
   * scheduled jobs, and rolls back completed steps via saga compensation.
   * @param instanceId Id of the target instance to cancel (with its active
   * descendants)
   */
  public static void cancelWithCompensationsInstance(Id instanceId) {
    cancelInstanceTree(instanceId, true);
  }

  /**
   * @description Cancels a workflow instance, aborts scheduled jobs, and optionally
   * runs saga compensations across the instance and its active descendant tree.
   * @param instanceId Id of the target instance to cancel (with its active
   * descendants)
   * @param runCompensations true to roll back completed steps via saga compensation
   */
  private static void cancelInstanceTree(
    Id instanceId,
    Boolean runCompensations
  ) {
    // Cancel the target instance and its entire active descendant tree. Descendants are
    // gathered iteratively (one set-based query per tree level) rather than via recursive
    // cancel() calls, so deep/wide trees cannot blow the SOQL or stack-depth governor
    // limits through uncontrolled recursion. Parent-before-child ordering is preserved.
    //
    // Note: each node still costs a handful of SOQL/DML in cancelSingleInstance(); a tree
    // with thousands of nodes would need async chunking. That is intentionally out of
    // scope here — the goal is to remove the recursion-driven multiplication.
    // The traversal always yields the target first, so it is cancelled with the original
    // not-found semantics (throwIfMissing = true); descendants are best-effort.
    //
    // Lifecycle events are collected and published in a single bulk batch AFTER every
    // node is cancelled, so the best-effort publish never spends a DML statement that a
    // later child cancellation still needs.
    List<Workflow_Instance__c> terminallyCancelled = new List<Workflow_Instance__c>();
    for (Id targetId : collectInstanceAndActiveDescendants(instanceId)) {
      Workflow_Instance__c cancelled = cancelSingleInstance(
        targetId,
        runCompensations,
        targetId == instanceId
      );
      if (cancelled != null) {
        terminallyCancelled.add(cancelled);
      }
    }
    WorkflowParentNotifier.notifyParentCompletion(terminallyCancelled);
    WorkflowLifecyclePublisher.publish(terminallyCancelled);
  }

  /**
   * @description Breadth-first collection of an instance plus all of its active
   * descendants using one set-based query per tree level. Returns IDs in
   * parent-before-child order. A `seen` guard makes the traversal safe against
   * accidental parent-reference cycles.
   * @param rootId Id of the instance at the root of the traversal
   * @return the root plus all active descendant Ids in parent-before-child order
   */
  private static List<Id> collectInstanceAndActiveDescendants(Id rootId) {
    List<Id> ordered = new List<Id>{ rootId };
    Set<Id> seen = new Set<Id>{ rootId };
    List<Id> frontier = new List<Id>{ rootId };
    while (!frontier.isEmpty()) {
      List<Workflow_Instance__c> children = queryActiveChildren(frontier);
      List<Id> nextFrontier = new List<Id>();
      for (Workflow_Instance__c child : children) {
        if (!seen.contains(child.Id)) {
          seen.add(child.Id);
          ordered.add(child.Id);
          nextFrontier.add(child.Id);
        }
      }
      frontier = nextFrontier;
    }
    return ordered;
  }

  /**
   * @description Fetches the active child instances of one BFS frontier level for
   * {@link collectInstanceAndActiveDescendants}.
   * <p><b>Intentional per-iteration SOQL.</b> This runs one SOQL query per
   * tree level of a breadth-first descendant traversal: the ids of level N+1
   * are only knowable after level N's children are read, so the traversal
   * cannot collapse into a single query. It is already optimal &mdash; one
   * <i>set-based</i> query per level (over the entire frontier at once), not
   * one query per node &mdash; and is governor-safe because the query count is
   * bounded by the <b>finite depth of the instance parent/child tree</b>, not
   * by the number of instances.
   * @param frontier the current BFS level's instance ids to fetch children of
   * @return the active (non-terminal) child instances whose parent is in the
   *         frontier
   */
  private static List<Workflow_Instance__c> queryActiveChildren(
    List<Id> frontier
  ) {
    return [
      SELECT Id
      FROM Workflow_Instance__c
      WHERE
        Parent_Instance__c IN :frontier
        AND Status__c IN (
          'Pending',
          'Running',
          'Suspended',
          'Cancelling',
          'CompensationFailed',
          'Paused'
        )
      WITH SYSTEM_MODE
    ];
  }

  /**
   * @description Tests whether a status is terminal for the purposes of
   * cancellation, i.e. cancellation should be skipped because the instance is
   * already finished.
   * @param status the instance status to test
   * @return true when the status is a terminal (non-cancellable) state
   */
  private static Boolean isTerminalForCancel(String status) {
    return status == 'Completed' ||
      status == 'Failed' ||
      status == 'Compensated' ||
      status == 'Cancelled' ||
      status == 'ContinuedAsNew';
  }

  /**
   * @description Enqueues the orchestrator for an instance, honoring the in-test
   * queueable disable flag so tests can drive the loop deterministically.
   * @param instanceId the instance to enqueue an orchestrator for
   */
  private static void enqueueOrchestratorTestAware(Id instanceId) {
    if (Test.isRunningTest()) {
      if (!WorkflowEngine.disableQueueableInTest) {
        System.enqueueJob(new WorkflowOrchestrator(instanceId));
      }
    } else {
      WorkflowOrchestratorEnqueue.enqueueOrchestrator(instanceId, null);
    }
  }

  /**
   * @description Locks (FOR UPDATE) the active step executions for the instance's
   * current step(s), supporting comma-separated parallel branch step names.
   * Returns an empty list when the instance has no current step.
   * @param instance the instance whose active steps are locked
   * @return the locked active step executions
   */
  private static List<Workflow_Step_Execution__c> lockActiveStepExecs(
    Workflow_Instance__c instance
  ) {
    List<Workflow_Step_Execution__c> stepExecs = new List<Workflow_Step_Execution__c>();
    if (String.isNotBlank(instance.Current_Step__c)) {
      List<String> activeStepNames = new List<String>();
      if (instance.Current_Step__c.contains(',')) {
        activeStepNames = instance.Current_Step__c.split(',');
      } else {
        activeStepNames.add(instance.Current_Step__c);
      }

      Id instanceId = instance.Id;
      stepExecs = [
        SELECT Id, Status__c
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Step_Name__c IN :activeStepNames
          AND Status__c IN ('Running', 'Pending', 'Retrying')
        WITH SYSTEM_MODE
        FOR UPDATE
      ];
    }
    return stepExecs;
  }

  /**
   * @description Cancels an instance stalled in CompensationFailed. With
   * compensations requested and remaining rollback work, it resumes the rollback
   * under the cancel phase (returns null, non-terminal); otherwise it forces the
   * instance terminal Cancelled (returns the instance for bulk lifecycle publish).
   * @param instance the CompensationFailed instance being cancelled
   * @param runCompensations true to drain remaining compensations before cancelling
   * @return the instance when driven terminal, otherwise null
   */
  private static Workflow_Instance__c cancelCompensationFailed(
    Workflow_Instance__c instance,
    Boolean runCompensations
  ) {
    List<String> remaining = parseCompensationStack(instance);
    if (runCompensations && !remaining.isEmpty()) {
      instance.Status__c = 'Cancelling';
      instance.Error_Message__c = 'Cancelled by user. Compensating.';
      Database.update(instance, true, AccessLevel.SYSTEM_MODE);

      // Append a fresh attempt for the stalled top-of-stack step (the prior Failed
      // attempt is preserved) so the existing compensation loop re-runs it.
      WorkflowCompensationStepLog.appendCompensationRetryStep(
        instance,
        remaining
      );
      WorkflowTimeoutArming.scheduleTimeoutJobForInstance(instance.Id);
      enqueueOrchestratorTestAware(instance.Id);
      // Not terminal yet — the orchestrator emits the lifecycle event when the
      // compensation stack drains to Cancelled.
      return null;
    }
    instance.Status__c = 'Cancelled';
    instance.Error_Message__c = 'Cancelled by user.';
    Database.update(instance, true, AccessLevel.SYSTEM_MODE);
    // Terminal immediately — hand back to cancel() for bulk lifecycle publish.
    return instance;
  }

  /**
   * @description Determines whether a cancel should first drain a live
   * compensation stack, i.e. compensations were requested and the instance has a
   * non-empty stack.
   * @param runCompensations true when the cancel requested saga compensation
   * @param instance the instance being cancelled
   * @return true when the cancel must run compensations before terminating
   */
  private static Boolean hasCancelCompensations(
    Boolean runCompensations,
    Workflow_Instance__c instance
  ) {
    if (!runCompensations || String.isBlank(instance.Compensation_Stack__c)) {
      return false;
    }
    return !parseCompensationStack(instance).isEmpty();
  }

  /**
   * @description Cancels a single workflow instance (no descendant traversal).
   * When throwIfMissing is true the original not-found exception is preserved for
   * the top-level target.
   *
   * Returns the instance when this call drove it to a terminal Cancelled state (the
   * no-compensation path), otherwise null. The caller (cancelInstanceTree())
   * collects these and publishes one bulk lifecycle batch AFTER the whole tree is
   * cancelled, so a per-node publish can never spend the DML budget that a later
   * child cancellation still needs. (The compensation path reaches Cancelled
   * asynchronously and emits its own event from the orchestrator.)
   * @param instanceId Id of the single instance to cancel
   * @param runCompensations true to roll back completed steps via saga compensation
   * @param throwIfMissing true to raise the not-found exception for the top-level
   * target
   * @return the instance when this call drove it to terminal Cancelled, otherwise
   * null
   */
  private static Workflow_Instance__c cancelSingleInstance(
    Id instanceId,
    Boolean runCompensations,
    Boolean throwIfMissing
  ) {
    List<Workflow_Instance__c> instances = [
      SELECT
        Id,
        Status__c,
        Current_Step__c,
        Compensation_Stack__c,
        Error_Message__c,
        Workflow_Name__c,
        Correlation_Key__c,
        Root_Correlation_Key__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
      WITH SYSTEM_MODE
      LIMIT 1
      FOR UPDATE
    ];
    if (instances.isEmpty()) {
      if (throwIfMissing) {
        throw new WorkflowEngine.WorkflowException(
          'Workflow instance not found: ' + instanceId
        );
      }
      return null;
    }

    Workflow_Instance__c instance = instances[0];
    if (isTerminalForCancel(instance.Status__c)) {
      return null; // Already in terminal state
    }
    // Note: CompensationFailed is intentionally NOT treated as terminal here — a stalled
    // rollback is resumable and still holds un-reversed side effects, so cancellation must
    // reach it (handled explicitly below) rather than skip it.

    // Lock active step executions FOR UPDATE second
    List<Workflow_Step_Execution__c> stepExecs = lockActiveStepExecs(instance);

    // Abort all scheduled jobs for this instance (sleeps, retries, timeouts)
    WorkflowOrchestratorEnqueue.abortScheduledJobs(instanceId);

    // Disarm any armed timed-wait timeout so the watchdog cannot mis-route a
    // cancelled (or compensating) instance to a fallback step (issue #35). Every
    // cancel branch below commits `instance`, so set it once here.
    instance.Sleep_Until__c = null;

    // Update step executions to Cancelled
    for (Workflow_Step_Execution__c stepExec : stepExecs) {
      stepExec.Status__c = 'Cancelled';
    }
    if (!stepExecs.isEmpty()) {
      Database.update(stepExecs, true, AccessLevel.SYSTEM_MODE);
    }

    // A stalled rollback (CompensationFailed) being cancelled is handled per cancel mode:
    // with compensations requested, resume the remaining rollback under the cancel phase so
    // it drains to 'Cancelled' (every remaining side effect reversed); without, force it
    // terminal 'Cancelled', abandoning the un-run compensations but releasing its key.
    if (instance.Status__c == 'CompensationFailed') {
      return cancelCompensationFailed(instance, runCompensations);
    }

    if (hasCancelCompensations(runCompensations, instance)) {
      instance.Status__c = 'Cancelling';
      instance.Error_Message__c = 'Cancelled by user. Compensating.';
      WorkflowCompensation.preCreateFirstCompensationStep(instance);
      Database.update(instance, true, AccessLevel.SYSTEM_MODE);

      // Kick off rollback loop
      enqueueOrchestratorTestAware(instance.Id);
      // Not terminal yet (Cancelling); the orchestrator emits the lifecycle event
      // when the compensation stack drains to Cancelled.
      return null;
    }

    instance.Status__c = 'Cancelled';
    instance.Error_Message__c = 'Cancelled by user.';
    Database.update(instance, true, AccessLevel.SYSTEM_MODE);
    // Terminal: hand the instance back to cancelInstanceTree() for a single bulk
    // publish after the whole descendant tree is cancelled (preserves DML headroom
    // mid-loop). Active child workflows are handled by the caller
    // (cancelInstanceTree()) via iterative descendant traversal, so no recursive
    // child cancellation happens here.
    return instance;
  }

  /**
   * @description Deserializes the compensation stack (empty when blank). A small
   * pure parse duplicated from `WorkflowEngine` (kept local to avoid publicizing
   * the resident helper). Unlike the reclaim path this intentionally lets
   * malformed JSON surface, matching the original retry semantics.
   * @param instance the instance whose Compensation_Stack__c is parsed
   * @return the LIFO compensation stack, or an empty list when blank
   */
  private static List<String> parseCompensationStack(
    Workflow_Instance__c instance
  ) {
    if (String.isBlank(instance.Compensation_Stack__c)) {
      return new List<String>();
    }
    return (List<String>) JSON.deserialize(
      instance.Compensation_Stack__c,
      List<String>.class
    );
  }
}
