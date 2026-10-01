/**
 * @description Cascade cancel of in-flight children when a parent fails
 * (issue #94).
 *
 * Flow:
 * 1. `WorkflowInstanceTrigger` (after update) calls {@link requestCascade} for
 *    each instance that enters `Failed`, `Compensated` or `CompensationFailed`.
 *    After insert, it calls {@link requestCascadeForLateChildren} for the
 *    parents of the new children. It requests a cascade for a parent that
 *    already failed. The pass then cancels a child that commits late
 *    (issue #241).
 * 2. {@link requestCascade} publishes one `CASCADE_CANCEL` `Workflow_Event__e`
 *    for each such parent. It runs no query. The event is `PublishAfterCommit`:
 *    a rolled-back failure sends no event.
 * 3. `WorkflowEventTriggerHandler` calls {@link handleEvents} in a new
 *    transaction with its own governor limits.
 * 4. Each pass walks one page of the cancel traversal: the active children of a
 *    frontier, in Id order. It cancels them with saga compensation through the
 *    node cancel that `WorkflowEngine.cancel()` uses. Then it publishes one event
 *    for the next level (the cancelled page) and, when the level has more rows,
 *    one event for the next page.
 *
 * Rules:
 * - The cascade never changes the parent. An error never fails the parent.
 * - Every event carries the failed parent. A parent that is no longer in a
 *   failure state (for example, redriven) keeps its children.
 * - Terminal and `Cancelling` descendants stay untouched, so a redelivered event
 *   is a no-op. The walk goes through `Cancelling` nodes. A `CompensationFailed`
 *   descendant resumes its rollback under the cancel phase.
 * - One pass reads at most {@link maxNodesPerPass} + 1 rows for each event and
 *   cancels at most {@link maxNodesPerPass} nodes. The order is root first: a
 *   node is cancelled before its children.
 * - A failed pass rolls back. A delayed {@link RetryJob} runs each request
 *   alone, with backoff, at most {@link MAX_ATTEMPTS} attempts in total. A row
 *   lock on a busy child clears; a bad node stops only its own request.
 * - Set `Revenant_Config__mdt.Cascade_Cancel_Children_On_Failure__c` (default
 *   on, surfaced as `WorkflowEngine.cascadeCancelChildrenOnFailure`) to false to
 *   stop the cascade.
 */
public inherited sharing class WorkflowCascadeCancel {
  public static final String EVENT_TYPE = 'CASCADE_CANCEL';
  public static final Integer MAX_ATTEMPTS = 5;

  // Parent states that start a cascade.
  public static final Set<String> FAILURE_STATUSES = new Set<String>{
    'Failed',
    'Compensated',
    'CompensationFailed'
  };

  // Maximum events that one pass reads (one page query each). Other events wait
  // for the next pass.
  private static final Integer MAX_REQUESTS_PER_PASS = 25;

  // Requests that one retry job runs (one savepoint and pass each). Apex allows
  // 5 savepoints per transaction; keep one slot free, as BulkCancelWorkflow does.
  private static final Integer RETRY_REQUESTS_PER_JOB = 4;

  // Maximum nodes that one pass cancels. It bounds the rows, the DML and the
  // scheduled-job abort filter of one transaction.
  @TestVisible
  private static Integer maxNodesPerPass = 200;

  // Captures the published cascade events (test context only).
  @TestVisible
  private static List<Workflow_Event__e> publishedEvents = new List<Workflow_Event__e>();

  // When true (test context only), makes a pass fail after its cancel work.
  @TestVisible
  private static Boolean throwTestException = false;

  // When true (test context only), makes the next-level publish fail.
  @TestVisible
  private static Boolean failContinuationPublish = false;

  /**
   * @description Publishes a cascade event for each failed parent. It runs no
   * query. Fire-and-forget: it catches all catchable exceptions and guards its
   * budgets, so it does not roll back the parent's failure write.
   * @param parentIds instances that entered a failure state
   */
  public static void requestCascade(Set<Id> parentIds) {
    if (
      parentIds == null ||
      parentIds.isEmpty() ||
      !WorkflowEngine.cascadeCancelChildrenOnFailure
    ) {
      return;
    }
    try {
      List<Workflow_Event__e> events = new List<Workflow_Event__e>();
      for (Id parentId : parentIds) {
        events.add(buildParentEvent(parentId));
      }
      publish(events);
    } catch (Exception ex) {
      // Fire-and-forget: a cascade request must never fail the parent.
      System.debug(
        LoggingLevel.WARN,
        'Cascade cancel request failed: ' + ex.getMessage()
      );
    }
  }

  /**
   * @description Requests a cascade for each parent that is already in a
   * failure state. A child was linked to it after its cascade pass (issue
   * #241). It runs one query, and none when `parentIds` is empty or the SOQL
   * budget is spent. The paged pass then cancels the child.
   * @param parentIds parents of the new children
   */
  public static void requestCascadeForLateChildren(Set<Id> parentIds) {
    if (
      parentIds == null ||
      parentIds.isEmpty() ||
      !WorkflowEngine.cascadeCancelChildrenOnFailure
    ) {
      return;
    }
    if (Limits.getQueries() >= Limits.getLimitQueries()) {
      System.debug(
        LoggingLevel.ERROR,
        'Late child cascade check skipped: SOQL budget spent'
      );
      return;
    }
    try {
      requestCascade(stillFailedParents(parentIds));
    } catch (Exception ex) {
      // Fire-and-forget: a late-child check must never fail the child start.
      System.debug(
        LoggingLevel.WARN,
        'Late child cascade check failed: ' + ex.getMessage()
      );
    }
  }

  /**
   * @description Builds the cascade event for one failed parent (attempt 1).
   * @param parentId the failed parent
   * @return the event (not published)
   */
  public static Workflow_Event__e buildParentEvent(Id parentId) {
    return new Workflow_Event__e(
      Workflow_Instance_Id__c = parentId,
      Event_Type__c = EVENT_TYPE
    );
  }

  /**
   * @description Handles one batch of cascade events in a savepoint. On error it
   * rolls back the pass and schedules a delayed retry for each request that has
   * attempts left. It catches all catchable exceptions, so the other events of
   * the trigger batch are not lost.
   * @param events the `CASCADE_CANCEL` events of one trigger batch
   */
  public static void handleEvents(List<Workflow_Event__e> events) {
    if (
      events == null ||
      events.isEmpty() ||
      !WorkflowEngine.cascadeCancelChildrenOnFailure
    ) {
      return;
    }
    List<CascadeRequest> requests = parseEvents(events);
    Savepoint sp = Database.setSavepoint();
    try {
      runPass(requests);
    } catch (Exception ex) {
      Database.rollback(sp);
      System.debug(
        LoggingLevel.ERROR,
        'Cascade cancel pass failed: ' + ex.getMessage()
      );
      scheduleRetries(requests, new List<CascadeRequest>());
    }
  }

  /**
   * @description Runs one cascade pass for each parent that is still in a
   * failure state. It cancels the first page of children now; the
   * events it publishes reap the rest. Synchronous entry for tests and operators.
   * @param parentIds the failed parents
   */
  public static void reapFailedParents(Set<Id> parentIds) {
    if (
      parentIds == null ||
      parentIds.isEmpty() ||
      !WorkflowEngine.cascadeCancelChildrenOnFailure
    ) {
      return;
    }
    List<CascadeRequest> requests = new List<CascadeRequest>();
    for (Id parentId : parentIds) {
      requests.add(new CascadeRequest(parentId));
    }
    runPass(requests);
  }

  /**
   * @description One cascade pass. For each request whose parent is still
   * failed, reads one page of the active children of its frontier. Cancels all
   * pages together (root first, at most {@link maxNodesPerPass} nodes), then
   * publishes the next-level and next-page events.
   * @param requests the parsed cascade requests
   */
  private static void runPass(List<CascadeRequest> requests) {
    Set<Id> parentIds = new Set<Id>();
    for (CascadeRequest req : requests) {
      parentIds.add(req.parentId);
    }
    Set<Id> stillFailed = stillFailedParents(parentIds);

    Integer budget = maxNodesPerPass;
    Integer pagesRead = 0;
    Set<String> seenKeys = new Set<String>();
    Set<Id> toCancel = new Set<Id>();
    List<Workflow_Event__e> next = new List<Workflow_Event__e>();
    for (CascadeRequest req : requests) {
      // Drop a stale request (parent redriven) and a duplicate in this batch.
      if (!stillFailed.contains(req.parentId) || !seenKeys.add(req.key())) {
        continue;
      }
      if (budget <= 0 || pagesRead >= MAX_REQUESTS_PER_PASS) {
        next.add(req.toEvent());
        continue;
      }
      pagesRead++;
      List<Workflow_Instance__c> page = WorkflowCancellation.queryActiveChildrenPage(
        req.frontier,
        req.afterId,
        budget + 1
      );
      List<Id> pageIds = new List<Id>();
      for (Integer i = 0; i < page.size() && i < budget; i++) {
        pageIds.add(page[i].Id);
      }
      if (pageIds.isEmpty()) {
        continue;
      }
      budget -= pageIds.size();
      toCancel.addAll(pageIds);
      // Next level: the children of this page, after the page is cancelled.
      next.add(new CascadeRequest(req.parentId, pageIds, null).toEvent());
      if (page.size() > pageIds.size()) {
        // Next page of the same level.
        next.add(
          new CascadeRequest(
              req.parentId,
              req.frontier,
              pageIds[pageIds.size() - 1]
            )
            .toEvent()
        );
      }
    }
    if (!toCancel.isEmpty()) {
      WorkflowCancellation.cascadeCancelNodes(new List<Id>(toCancel));
    }
    if (Test.isRunningTest() && throwTestException) {
      throw new WorkflowEngine.WorkflowException('Simulated cascade failure');
    }
    // The rest of the tree is reachable only through these events: a publish
    // failure must fail the pass, so the rollback and retry path runs.
    publishOrThrow(next);
  }

  private static Set<Id> stillFailedParents(Set<Id> parentIds) {
    Set<Id> stillFailed = new Set<Id>();
    if (parentIds.isEmpty()) {
      return stillFailed;
    }
    for (Workflow_Instance__c parent : [
      SELECT Id
      FROM Workflow_Instance__c
      WHERE Id IN :parentIds AND Status__c IN :FAILURE_STATUSES
      WITH SYSTEM_MODE
    ]) {
      stillFailed.add(parent.Id);
    }
    return stillFailed;
  }

  /**
   * @description One cascade work item: reap the active children of `frontier`
   * (after the `afterId` cursor) for the failed `parentId`.
   */
  private class CascadeRequest {
    Id parentId;
    List<Id> frontier;
    Id afterId;
    Integer attempt = 1;

    CascadeRequest(Id parentId) {
      this(parentId, new List<Id>{ parentId }, null);
    }

    CascadeRequest(Id parentId, List<Id> frontier, Id afterId) {
      this.parentId = parentId;
      this.frontier = frontier;
      this.afterId = afterId;
    }

    String key() {
      return parentId + '|' + JSON.serialize(frontier) + '|' + afterId;
    }

    Workflow_Event__e toEvent() {
      Map<String, Object> payload = new Map<String, Object>{
        'attempt' => attempt,
        'frontier' => frontier
      };
      if (afterId != null) {
        payload.put('after', afterId);
      }
      return new Workflow_Event__e(
        Workflow_Instance_Id__c = parentId,
        Event_Type__c = EVENT_TYPE,
        Payload__c = JSON.serialize(payload)
      );
    }
  }

  // Parses the events. An event with a bad Id or payload is dropped.
  private static List<CascadeRequest> parseEvents(
    List<Workflow_Event__e> events
  ) {
    List<CascadeRequest> requests = new List<CascadeRequest>();
    for (Workflow_Event__e event : events) {
      try {
        requests.add(parseEvent(event));
      } catch (Exception ex) {
        System.debug(
          LoggingLevel.WARN,
          'Malformed cascade event dropped: ' + ex.getMessage()
        );
      }
    }
    return requests;
  }

  private static CascadeRequest parseEvent(Workflow_Event__e event) {
    CascadeRequest req = new CascadeRequest(
      Id.valueOf(event.Workflow_Instance_Id__c)
    );
    if (String.isBlank(event.Payload__c)) {
      return req;
    }
    Map<String, Object> payload = (Map<String, Object>) JSON.deserializeUntyped(
      event.Payload__c
    );
    if (payload.get('attempt') != null) {
      req.attempt = Integer.valueOf(payload.get('attempt'));
    }
    List<Object> frontier = (List<Object>) payload.get('frontier');
    if (frontier != null && !frontier.isEmpty()) {
      req.frontier = new List<Id>();
      for (Object nodeId : frontier) {
        req.frontier.add(Id.valueOf((String) nodeId));
      }
    }
    if (payload.get('after') != null) {
      req.afterId = Id.valueOf((String) payload.get('after'));
    }
    return req;
  }

  // Schedules one delayed RetryJob for the failed requests that have attempts
  // left (next attempt) and the unrun requests (same attempt). When no Queueable
  // is left, it republishes them as events.
  private static void scheduleRetries(
    List<CascadeRequest> failed,
    List<CascadeRequest> unrun
  ) {
    List<CascadeRequest> retries = new List<CascadeRequest>(unrun);
    for (CascadeRequest req : failed) {
      if (req.attempt >= MAX_ATTEMPTS) {
        System.debug(
          LoggingLevel.ERROR,
          'Cascade cancel dropped after ' +
            MAX_ATTEMPTS +
            ' attempts: ' +
            req.parentId
        );
        continue;
      }
      req.attempt++;
      retries.add(req);
    }
    if (retries.isEmpty()) {
      return;
    }
    // A test cannot chain Queueables.
    Boolean canEnqueue =
      Limits.getQueueableJobs() < Limits.getLimitQueueableJobs() &&
      !(Test.isRunningTest() && System.isQueueable());
    if (!canEnqueue) {
      List<Workflow_Event__e> events = new List<Workflow_Event__e>();
      for (CascadeRequest req : retries) {
        events.add(req.toEvent());
      }
      publish(events);
      return;
    }
    System.enqueueJob(new RetryJob(retries), retryDelayMinutes(retries));
  }

  // Backoff: 1, 2, 4, 8 minutes for attempts 2 to 5 (Queueable maximum 10).
  private static Integer retryDelayMinutes(List<CascadeRequest> retries) {
    Integer attempt = 1;
    for (CascadeRequest req : retries) {
      attempt = Math.max(attempt, req.attempt);
    }
    return Math.min(10, Math.pow(2, Math.max(0, attempt - 2)).intValue());
  }

  /**
   * @description Delayed retry of failed cascade requests. It runs each request
   * alone in its own savepoint, so one bad node stops only its own request.
   */
  public class RetryJob implements Queueable {
    private final List<CascadeRequest> requests;

    private RetryJob(List<CascadeRequest> requests) {
      this.requests = requests;
    }

    /**
     * @description Runs up to RETRY_REQUESTS_PER_JOB requests, each in its own
     * savepoint. Schedules the failed and the unrun requests again.
     * @param context the Queueable context
     */
    public void execute(QueueableContext context) {
      if (!WorkflowEngine.cascadeCancelChildrenOnFailure) {
        return;
      }
      List<CascadeRequest> failed = new List<CascadeRequest>();
      List<CascadeRequest> unrun = new List<CascadeRequest>();
      for (Integer i = 0; i < requests.size(); i++) {
        CascadeRequest req = requests[i];
        if (i >= RETRY_REQUESTS_PER_JOB) {
          unrun.add(req);
          continue;
        }
        Savepoint sp = Database.setSavepoint();
        try {
          runPass(new List<CascadeRequest>{ req });
          Database.releaseSavepoint(sp);
        } catch (Exception ex) {
          Database.rollback(sp);
          System.debug(
            LoggingLevel.ERROR,
            'Cascade cancel retry failed: ' + ex.getMessage()
          );
          failed.add(req);
        }
      }
      scheduleRetries(failed, unrun);
    }
  }

  // Publishes the events. It throws when the DML budget is spent or the bus
  // rejects an event.
  private static void publishOrThrow(List<Workflow_Event__e> events) {
    if (events.isEmpty()) {
      return;
    }
    if (
      !hasDmlBudget(events.size()) ||
      (Test.isRunningTest() && failContinuationPublish)
    ) {
      throw new WorkflowEngine.WorkflowException(
        'Cascade cancel events not published'
      );
    }
    List<Database.SaveResult> results = EventBus.publish(events);
    if (Test.isRunningTest()) {
      publishedEvents.addAll(events);
    }
    WorkflowOrchestratorEnqueue.throwOnPublishErrors(
      results,
      'Cascade cancel event publish failed: '
    );
  }

  private static Boolean hasDmlBudget(Integer eventCount) {
    return Limits.getDmlStatements() < Limits.getLimitDmlStatements() &&
      Limits.getDmlRows() + eventCount <= Limits.getLimitDmlRows();
  }

  // Publishes best-effort. It skips the publish when the DML budget is spent,
  // because an over-budget publish throws an uncatchable LimitException.
  private static void publish(List<Workflow_Event__e> events) {
    if (events.isEmpty()) {
      return;
    }
    if (!hasDmlBudget(events.size())) {
      System.debug(
        LoggingLevel.ERROR,
        'Cascade cancel events skipped: DML budget spent'
      );
      return;
    }
    for (Database.SaveResult sr : EventBus.publish(events)) {
      if (!sr.isSuccess()) {
        System.debug(
          LoggingLevel.ERROR,
          'Cascade cancel event publish failed: ' + sr.getErrors()
        );
      }
    }
    if (Test.isRunningTest()) {
      publishedEvents.addAll(events);
    }
  }
}
