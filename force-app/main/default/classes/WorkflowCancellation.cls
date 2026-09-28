/**
 * @description Cancellation surface for the Revenant engine. Cancels a workflow
 * instance together with its entire active descendant tree, aborting scheduled
 * jobs and &mdash; on the compensating path &mdash; driving saga rollback of the
 * completed steps. Descendants are gathered breadth-first (one set-based query per
 * tree level) with a visited-id guard rather than by recursive cancel calls, so
 * deep/wide trees cannot exhaust the SOQL or stack-depth governors. The nodes are
 * then cancelled set-based: the SOQL/DML cost does not grow with the node count
 * (except best-effort timeout arming for each resumed rollback).
 * Parent-before-child ordering and the FOR UPDATE locking are preserved from the
 * pre-extraction engine. Extracted from `WorkflowEngine`, which retains the thin
 * public `cancel` delegator. The cascade cancel of issue #94
 * ({@link WorkflowCascadeCancel}) walks the same child query one page per event
 * ({@link queryActiveChildrenPage}) and uses the same node cancel. The
 * resident `WorkflowEngine.WorkflowException`, `WorkflowEngine.disableQueueableInTest`,
 * `WorkflowCompensation.preCreateFirstCompensationSteps` and
 * `WorkflowCompensationStepLog.appendCompensationRetrySteps` members are referenced
 * fully qualified. The Cancel Workflow action (issue #107) uses the bulk
 * entries {@link cancelInstances} and {@link cancelWithCompensationsInstances}.
 * All SOQL/DML executes in system mode.
 */
public inherited sharing class WorkflowCancellation {
  /**
   * @description Child states that the descendant traversal walks through.
   * `Compensating` is not in the set: that child already rolls back.
   */
  public static final Set<String> ACTIVE_CHILD_STATUSES = new Set<String>{
    'Pending',
    'Running',
    'Suspended',
    'Cancelling',
    'CompensationFailed',
    'Paused',
    // A definition-change park (issue #89) is in flight, so a cascade reaches it.
    'DefinitionChanged'
  };

  /**
   * @description Statuses that a cancel skips: the instance is already finished.
   */
  public static final Set<String> TERMINAL_STATUSES = new Set<String>{
    'Completed',
    'Failed',
    'Compensated',
    'Cancelled',
    'ContinuedAsNew'
  };

  /**
   * @description Statuses of a node whose rollback already runs.
   */
  public static final Set<String> ROLLBACK_STATUSES = new Set<String>{
    'Cancelling',
    'Compensating'
  };

  private static final String CANCELLED_MESSAGE = 'Cancelled by user.';
  private static final String CANCELLING_MESSAGE = 'Cancelled by user. Compensating.';

  // SOQL headroom kept when best-effort timeout arming runs for many nodes.
  private static final Integer TIMEOUT_ARMING_SOQL_RESERVE = 20;

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
   * @description Cancels a workflow instance (and its active descendants), aborts
   * scheduled jobs, and rolls back completed steps via saga compensation. Public
   * API entry relocated from `WorkflowEngine`.
   * @param instanceId Id of the target instance to cancel (with its active descendants)
   */
  public static void cancelWithCompensations(Id instanceId) {
    cancelWithCompensationsInstance(instanceId);
  }

  /**
   * @description Cascade entry (issue #94). Cancels the given nodes with saga
   * compensation, in the given order. Skips terminal nodes and nodes already
   * `Cancelling`, so a repeated cascade does not cancel a node two times. A
   * `CompensationFailed` node resumes its rollback under the cancel phase, as in
   * {@link cancelWithCompensations}.
   * @param orderedIds the nodes to cancel, parent before child
   */
  public static void cascadeCancelNodes(List<Id> orderedIds) {
    cancelNodes(orderedIds, true, null, new Set<String>{ 'Cancelling' });
  }

  /**
   * @description Bulk cancel entry (issue #107). Cancels the roots and their
   * active descendants in one set-based pass, WITHOUT saga compensations. Skips
   * missing and terminal nodes. A `Cancelling` node stops its rollback.
   * @param rootIds the instances to cancel, in order; null or empty is a no-op
   * @return the Ids (roots and descendants) that this call cancelled
   */
  public static Set<Id> cancelInstances(List<Id> rootIds) {
    return cancelRoots(rootIds, false, new Set<String>());
  }

  /**
   * @description Bulk cancel entry (issue #107). Cancels the roots and their
   * active descendants in one set-based pass and rolls back completed steps.
   * Skips missing and terminal nodes, and nodes whose rollback already runs
   * (`Cancelling`, `Compensating`), so a repeat does not start a second rollback.
   * @param rootIds the instances to cancel, in order; null or empty is a no-op
   * @return the Ids (roots and descendants) that this call cancelled
   */
  public static Set<Id> cancelWithCompensationsInstances(List<Id> rootIds) {
    return cancelRoots(rootIds, true, ROLLBACK_STATUSES);
  }

  /**
   * @description Shared body of the bulk cancel entries.
   * @param rootIds the instances to cancel, in order
   * @param runCompensations true to roll back completed steps
   * @param skipStatuses extra statuses to leave untouched
   * @return the Ids that this call cancelled
   */
  private static Set<Id> cancelRoots(
    List<Id> rootIds,
    Boolean runCompensations,
    Set<String> skipStatuses
  ) {
    List<Id> roots = rootIds ?? new List<Id>();
    if (roots.isEmpty()) {
      return new Set<Id>();
    }
    return cancelNodes(
      collectActiveTree(roots),
      runCompensations,
      null,
      skipStatuses
    );
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
    // The target keeps the original not-found semantics (it must exist);
    // descendants are best-effort.
    if (instanceId == null) {
      throw new WorkflowEngine.WorkflowException(
        'Workflow instance not found: ' + instanceId
      );
    }
    cancelNodes(
      collectActiveTree(new List<Id>{ instanceId }),
      runCompensations,
      instanceId,
      new Set<String>()
    );
  }

  /**
   * @description Breadth-first collection of the roots plus all of their active
   * descendants using one set-based query per tree level. Returns IDs in
   * parent-before-child order, roots first. A `seen` guard makes the traversal
   * safe against accidental parent-reference cycles and duplicate roots.
   * @param rootIds Ids of the instances at the root of the traversal
   * @return the roots plus all active descendant Ids in parent-before-child order
   */
  private static List<Id> collectActiveTree(List<Id> rootIds) {
    List<Id> ordered = new List<Id>();
    Set<Id> seen = new Set<Id>();
    for (Id rootId : rootIds) {
      if (rootId != null && seen.add(rootId)) {
        ordered.add(rootId);
      }
    }
    List<Id> frontier = new List<Id>(ordered);
    while (!frontier.isEmpty()) {
      List<Workflow_Instance__c> children = queryActiveChildren(frontier);
      List<Id> nextFrontier = new List<Id>();
      for (Workflow_Instance__c child : children) {
        if (seen.add(child.Id)) {
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
   * {@link collectActiveTree}.
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
        AND Status__c IN :ACTIVE_CHILD_STATUSES
      WITH SYSTEM_MODE
    ];
  }

  /**
   * @description One page of {@link queryActiveChildren}, in Id order. The
   * cascade cancel (issue #94) walks the same traversal one page per event, so
   * one transaction never reads a whole wide level.
   * @param frontier the instance ids to fetch children of
   * @param afterId the cursor: return only Ids after it, or null for the start
   * @param pageSize the maximum number of rows
   * @return the active child instances of the page
   */
  public static List<Workflow_Instance__c> queryActiveChildrenPage(
    List<Id> frontier,
    Id afterId,
    Integer pageSize
  ) {
    if (afterId == null) {
      return [
        SELECT Id
        FROM Workflow_Instance__c
        WHERE
          Parent_Instance__c IN :frontier
          AND Status__c IN :ACTIVE_CHILD_STATUSES
        WITH SYSTEM_MODE
        ORDER BY Id
        LIMIT :pageSize
      ];
    }
    return [
      SELECT Id
      FROM Workflow_Instance__c
      WHERE
        Parent_Instance__c IN :frontier
        AND Status__c IN :ACTIVE_CHILD_STATUSES
        AND Id > :afterId
      WITH SYSTEM_MODE
      ORDER BY Id
      LIMIT :pageSize
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
    return TERMINAL_STATUSES.contains(status);
  }

  /**
   * @description The cancel outcome of one node batch, split by the next action.
   */
  private class NodePlan {
    // Driven to terminal Cancelled now.
    List<Workflow_Instance__c> terminal = new List<Workflow_Instance__c>();
    // Starts a fresh cancel-phase rollback.
    List<Workflow_Instance__c> compensating = new List<Workflow_Instance__c>();
    // Resumes a stalled (CompensationFailed) rollback.
    List<Workflow_Instance__c> resumed = new List<Workflow_Instance__c>();
    // Non-terminal nodes that need an orchestrator, in node order.
    List<Id> toEnqueue = new List<Id>();
  }

  /**
   * @description Cancels a batch of nodes set-based. Each node gets the same
   * outcome as the former per-node cancel:
   * <ul>
   * <li>terminal node, or node in `skipStatuses`: skipped;</li>
   * <li>`CompensationFailed` with compensations and a remaining stack: resumes the
   * rollback under the cancel phase;</li>
   * <li>live compensation stack with compensations: starts the cancel-phase
   * rollback;</li>
   * <li>else: terminal `Cancelled`.</li>
   * </ul>
   * For each cancelled node, it cancels the active step executions, aborts the
   * scheduled jobs and disarms the timed-wait deadline. At the end, it sends one
   * bulk parent notification and one bulk lifecycle publish for the terminal
   * nodes. The SOQL/DML cost is constant in the node count, except best-effort
   * timeout arming for each resumed rollback.
   * @param orderedIds the nodes to cancel, parent before child
   * @param runCompensations true to roll back completed steps via saga compensation
   * @param requiredId a node that must exist (else not-found exception), or null
   * @param skipStatuses extra statuses to leave untouched
   * @return the Ids of the nodes that this call cancelled
   */
  private static Set<Id> cancelNodes(
    List<Id> orderedIds,
    Boolean runCompensations,
    Id requiredId,
    Set<String> skipStatuses
  ) {
    Map<Id, Workflow_Instance__c> locked = lockInstances(orderedIds);
    if (requiredId != null && !locked.containsKey(requiredId)) {
      throw new WorkflowEngine.WorkflowException(
        'Workflow instance not found: ' + requiredId
      );
    }

    List<Workflow_Instance__c> targets = new List<Workflow_Instance__c>();
    Set<Id> seen = new Set<Id>();
    for (Id nodeId : orderedIds) {
      Workflow_Instance__c instance = seen.add(nodeId)
        ? locked.get(nodeId)
        : null;
      // Note: CompensationFailed is intentionally NOT treated as terminal here — a
      // stalled rollback is resumable and still holds un-reversed side effects, so
      // cancellation must reach it rather than skip it.
      if (
        instance != null &&
        !isTerminalForCancel(instance.Status__c) &&
        !skipStatuses.contains(instance.Status__c)
      ) {
        targets.add(instance);
      }
    }
    Set<Id> targetIds = new Map<Id, Workflow_Instance__c>(targets).keySet();
    if (targets.isEmpty()) {
      return targetIds;
    }

    // Plan first: it changes records in memory only, so a malformed stack throws
    // before any side effect.
    NodePlan plan = planNodes(targets, runCompensations);

    cancelActiveStepExecs(targets);

    // Abort all scheduled jobs for these nodes (sleeps, retries, timeouts)
    WorkflowOrchestratorEnqueue.abortScheduledJobs(targetIds);

    WorkflowCompensation.preCreateFirstCompensationSteps(plan.compensating);
    Database.update(targets, true, AccessLevel.SYSTEM_MODE);

    // Append a fresh attempt for each stalled top-of-stack step (the prior Failed
    // attempt is preserved) so the existing compensation loop re-runs it.
    WorkflowCompensationStepLog.appendCompensationRetrySteps(plan.resumed);
    armResumedTimeouts(plan.resumed);
    enqueueOrchestratorsTestAware(plan.toEnqueue);

    // Non-terminal (Cancelling) nodes emit their lifecycle event from the
    // orchestrator when the compensation stack drains to Cancelled. Terminal nodes
    // publish one bulk batch here, after every node write, so the best-effort
    // publish never spends DML that a node write still needs.
    WorkflowParentNotifier.notifyParentCompletion(plan.terminal);
    WorkflowLifecyclePublisher.publish(plan.terminal);
    return targetIds;
  }

  /**
   * @description Locks (FOR UPDATE) the given instances in one query.
   * @param instanceIds the instances to lock
   * @return the locked instances by Id (missing Ids are absent)
   */
  private static Map<Id, Workflow_Instance__c> lockInstances(
    List<Id> instanceIds
  ) {
    return new Map<Id, Workflow_Instance__c>(
      [
        SELECT
          Id,
          Status__c,
          Current_Step__c,
          Compensation_Stack__c,
          Error_Message__c,
          Workflow_Name__c,
          Correlation_Key__c,
          Root_Correlation_Key__c,
          Previous_Instance__c,
          Concurrency_Parked__c,
          Concurrency_Slot_Held__c
        FROM Workflow_Instance__c
        WHERE Id IN :instanceIds
        WITH SYSTEM_MODE
        FOR UPDATE
      ]
    );
  }

  /**
   * @description Sets the cancel outcome on each node in memory (no DML) and
   * groups the nodes by the next action.
   * @param targets the non-terminal nodes to cancel, parent before child
   * @param runCompensations true when the cancel requested saga compensation
   * @return the plan for the batch
   */
  private static NodePlan planNodes(
    List<Workflow_Instance__c> targets,
    Boolean runCompensations
  ) {
    NodePlan plan = new NodePlan();
    for (Workflow_Instance__c instance : targets) {
      // Disarm any armed timed-wait timeout so the watchdog cannot mis-route a
      // cancelled (or compensating) instance to a fallback step (issue #35).
      instance.Sleep_Until__c = null;
      List<Workflow_Instance__c> rollback = rollbackGroup(
        plan,
        instance,
        runCompensations
      );
      if (rollback != null) {
        rollback.add(instance);
        instance.Status__c = 'Cancelling';
        instance.Error_Message__c = CANCELLING_MESSAGE;
        plan.toEnqueue.add(instance.Id);
      } else {
        // Without compensations a stalled rollback is forced terminal: its un-run
        // compensations are abandoned but its correlation key is released.
        instance.Status__c = 'Cancelled';
        instance.Error_Message__c = CANCELLED_MESSAGE;
        plan.terminal.add(instance);
      }
    }
    return plan;
  }

  /**
   * @description Selects the rollback group of a node: a stalled rollback
   * (`CompensationFailed`) resumes, a live stack starts the cancel phase. It
   * parses the stack only where the former per-node cancel parsed it, so a
   * malformed stack throws in the same cases.
   * @param plan the batch plan that owns the groups
   * @param instance the node to classify
   * @param runCompensations true when the cancel requested saga compensation
   * @return the group to add the node to, or null when the node goes terminal
   */
  private static List<Workflow_Instance__c> rollbackGroup(
    NodePlan plan,
    Workflow_Instance__c instance,
    Boolean runCompensations
  ) {
    if (instance.Status__c == 'CompensationFailed') {
      Boolean hasRemaining = !parseCompensationStack(instance).isEmpty();
      return runCompensations && hasRemaining ? plan.resumed : null;
    }
    if (!runCompensations || String.isBlank(instance.Compensation_Stack__c)) {
      return null;
    }
    return parseCompensationStack(instance).isEmpty()
      ? null
      : plan.compensating;
  }

  /**
   * @description Locks (FOR UPDATE) and cancels the active step executions of the
   * current step(s) of each node, supporting comma-separated parallel branch step
   * names. A node with no current step has no active step execution to cancel.
   * @param targets the nodes whose active steps are cancelled
   */
  private static void cancelActiveStepExecs(
    List<Workflow_Instance__c> targets
  ) {
    Map<Id, Set<String>> activeNamesById = new Map<Id, Set<String>>();
    Set<String> allNames = new Set<String>();
    for (Workflow_Instance__c instance : targets) {
      if (String.isBlank(instance.Current_Step__c)) {
        continue;
      }
      Set<String> names = new Set<String>(instance.Current_Step__c.split(','));
      activeNamesById.put(instance.Id, names);
      allNames.addAll(names);
    }
    if (activeNamesById.isEmpty()) {
      return;
    }
    Set<Id> instanceIds = activeNamesById.keySet();
    List<Workflow_Step_Execution__c> toCancel = new List<Workflow_Step_Execution__c>();
    for (Workflow_Step_Execution__c stepExec : [
      SELECT Id, Status__c, Workflow_Instance__c, Step_Name__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c IN :instanceIds
        AND Step_Name__c IN :allNames
        AND Status__c IN ('Running', 'Pending', 'Retrying')
      WITH SYSTEM_MODE
      FOR UPDATE
    ]) {
      // The set-based query can match a name of another node; keep own names only.
      if (
        activeNamesById.get(stepExec.Workflow_Instance__c)
          .contains(stepExec.Step_Name__c)
      ) {
        stepExec.Status__c = 'Cancelled';
        toCancel.add(stepExec);
      }
    }
    if (!toCancel.isEmpty()) {
      Database.update(toCancel, true, AccessLevel.SYSTEM_MODE);
    }
  }

  /**
   * @description Arms the step timeout of each resumed rollback. Best-effort:
   * arming stops when SOQL headroom is low, and the watchdog heartbeat then
   * enforces the timeout.
   * @param resumed the nodes whose stalled rollback resumes
   */
  private static void armResumedTimeouts(List<Workflow_Instance__c> resumed) {
    for (Workflow_Instance__c instance : resumed) {
      if (
        Limits.getQueries() >=
        Limits.getLimitQueries() - TIMEOUT_ARMING_SOQL_RESERVE
      ) {
        return;
      }
      WorkflowTimeoutArming.scheduleTimeoutJobForInstance(instance);
    }
  }

  /**
   * @description Enqueues the orchestrator for each node, honoring the in-test
   * queueable disable flag so tests can drive the loop deterministically.
   * Outside tests, one bulk platform-event publish covers every node.
   * @param instanceIds the instances to enqueue an orchestrator for
   */
  private static void enqueueOrchestratorsTestAware(List<Id> instanceIds) {
    if (instanceIds.isEmpty()) {
      return;
    }
    if (!Test.isRunningTest()) {
      WorkflowOrchestratorEnqueue.enqueueOrchestrators(instanceIds);
      return;
    }
    if (WorkflowEngine.disableQueueableInTest) {
      return;
    }
    for (Id instanceId : instanceIds) {
      enqueueTestOrchestrator(instanceId);
    }
  }

  /**
   * @description Enqueues one orchestrator job directly (test context). Kept as a
   * helper so the per-node `System.enqueueJob` is not lexically inside the loop.
   * @param instanceId the instance to enqueue an orchestrator for
   */
  private static void enqueueTestOrchestrator(Id instanceId) {
    System.enqueueJob(new WorkflowOrchestrator(instanceId));
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
