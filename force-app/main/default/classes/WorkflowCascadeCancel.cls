/**
 * @description Cascade cancel of in-flight children when a parent fails
 * (issue #94).
 *
 * Flow:
 * 1. `WorkflowInstanceTrigger` (after update) calls {@link requestCascade} for
 *    each instance that enters `Failed`, `Compensated` or `CompensationFailed`.
 * 2. {@link requestCascade} publishes one `CASCADE_CANCEL` `Workflow_Event__e`
 *    for each such parent that has an active child. The event is
 *    `PublishAfterCommit`: a rolled-back failure sends no event.
 * 3. `WorkflowEventTriggerHandler` calls {@link handleEvents} in a new
 *    transaction with its own governor limits.
 * 4. {@link reap} walks the tree with the `WorkflowCancellation` traversal and
 *    cancels the descendants with saga compensation through the same node cancel
 *    that `WorkflowEngine.cancel()` uses.
 *
 * Rules:
 * - The cascade never changes the parent. An error never fails the parent.
 * - A parent that is no longer in a failure state (for example, redriven) keeps
 *   its children.
 * - Terminal, `Cancelling` and `CompensationFailed` descendants stay untouched,
 *   so a redelivered event is a no-op.
 * - One pass cancels at most {@link maxNodesPerPass} nodes, root first. A
 *   continuation event carries the remaining node Ids.
 * - A failed pass rolls back and republishes its events, at most
 *   {@link MAX_ATTEMPTS} attempts in total.
 * - `Revenant_Config__mdt.Cascade_Cancel_Children_On_Failure__c` (default on),
 *   surfaced as `WorkflowEngine.cascadeCancelChildrenOnFailure`, disables all of
 *   this.
 */
public inherited sharing class WorkflowCascadeCancel {
  public static final String EVENT_TYPE = 'CASCADE_CANCEL';
  public static final Integer MAX_ATTEMPTS = 3;

  // Parent states that start a cascade.
  public static final Set<String> FAILURE_STATUSES = new Set<String>{
    'Failed',
    'Compensated',
    'CompensationFailed'
  };

  // Child states the cancel traversal walks through (WorkflowCancellation).
  private static final Set<String> TRAVERSED_CHILD_STATUSES = new Set<String>{
    'Pending',
    'Running',
    'Suspended',
    'Cancelling',
    'CompensationFailed',
    'Paused'
  };

  // Node Ids in one continuation event (about 45 KB of the 128 KB payload).
  private static final Integer CONTINUATION_CHUNK = 2000;

  // Maximum nodes that one pass cancels. It bounds the DML rows and the
  // scheduled-job abort filter of one transaction.
  @TestVisible
  private static Integer maxNodesPerPass = 200;

  // Captures the published cascade events (test context only).
  @TestVisible
  private static List<Workflow_Event__e> publishedEvents = new List<Workflow_Event__e>();

  // When true (test context only), makes a pass fail after its cancel work.
  @TestVisible
  private static Boolean throwTestException = false;

  /**
   * @description Publishes a cascade event for each parent that has an active
   * child. Fire-and-forget: it never throws, so it can never roll back the
   * parent's terminal failure write.
   * @param parentIds instances that entered a terminal failure state
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
      for (Id parentId : parentsWithActiveChildren(parentIds)) {
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
   * rolls back the pass and republishes each event that has attempts left. It
   * never throws, so the other events of the trigger batch are not lost.
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
      Set<Id> parentIds = new Set<Id>();
      List<Id> targetIds = new List<Id>();
      for (CascadeRequest req : requests) {
        if (req.targetIds.isEmpty()) {
          parentIds.add(req.rootId);
        } else {
          targetIds.addAll(req.targetIds);
        }
      }
      reap(parentIds, targetIds);
      if (Test.isRunningTest() && throwTestException) {
        throw new WorkflowEngine.WorkflowException('Simulated cascade failure');
      }
    } catch (Exception ex) {
      Database.rollback(sp);
      System.debug(
        LoggingLevel.ERROR,
        'Cascade cancel pass failed: ' + ex.getMessage()
      );
      publishRetries(requests);
    }
  }

  /**
   * @description Reaps the in-flight descendants of each parent that is still in
   * a terminal failure state. Synchronous entry for tests and operators.
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
    reap(parentIds, new List<Id>());
  }

  /**
   * @description One cascade pass. Roots are the parents still in a failure
   * state (not cancelled) plus the continuation targets (cancelled). Cancels the
   * first {@link maxNodesPerPass} nodes in root-first order and sends the rest
   * to a continuation event.
   * @param parentIds failed parents to re-check
   * @param targetIds continuation nodes to cancel
   */
  private static void reap(Set<Id> parentIds, List<Id> targetIds) {
    Set<Id> stillFailed = stillFailedParents(parentIds);
    List<Id> roots = new List<Id>(stillFailed);
    roots.addAll(targetIds);
    if (roots.isEmpty()) {
      return;
    }

    List<Id> pass = new List<Id>();
    List<Id> remaining = new List<Id>();
    for (Id nodeId : WorkflowCancellation.collectActiveTree(roots)) {
      if (stillFailed.contains(nodeId)) {
        continue;
      }
      if (pass.size() < maxNodesPerPass) {
        pass.add(nodeId);
      } else {
        remaining.add(nodeId);
      }
    }
    if (!pass.isEmpty()) {
      WorkflowCancellation.cascadeCancelNodes(pass);
    }
    publish(buildContinuationEvents(roots[0], remaining, 1));
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

  // Filters the parents to those with an active child. When SOQL headroom is
  // low it skips the filter; the handler then finds no child and does nothing.
  private static Set<Id> parentsWithActiveChildren(Set<Id> parentIds) {
    if (Limits.getLimitQueries() - Limits.getQueries() < 2) {
      return parentIds;
    }
    Set<Id> withChildren = new Set<Id>();
    for (AggregateResult row : [
      SELECT Parent_Instance__c parentId
      FROM Workflow_Instance__c
      WHERE
        Parent_Instance__c IN :parentIds
        AND Status__c IN :TRAVERSED_CHILD_STATUSES
      WITH SYSTEM_MODE
      GROUP BY Parent_Instance__c
    ]) {
      withChildren.add((Id) row.get('parentId'));
    }
    return withChildren;
  }

  /**
   * @description One parsed cascade event.
   */
  private class CascadeRequest {
    Id rootId;
    Integer attempt = 1;
    List<Id> targetIds = new List<Id>();
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
    CascadeRequest req = new CascadeRequest();
    req.rootId = Id.valueOf(event.Workflow_Instance_Id__c);
    if (String.isBlank(event.Payload__c)) {
      return req;
    }
    Map<String, Object> payload = (Map<String, Object>) JSON.deserializeUntyped(
      event.Payload__c
    );
    if (payload.get('attempt') != null) {
      req.attempt = Integer.valueOf(payload.get('attempt'));
    }
    List<Object> targets = (List<Object>) payload.get('targets');
    if (targets != null) {
      for (Object target : targets) {
        req.targetIds.add(Id.valueOf((String) target));
      }
    }
    return req;
  }

  private static void publishRetries(List<CascadeRequest> requests) {
    List<Workflow_Event__e> retries = new List<Workflow_Event__e>();
    for (CascadeRequest req : requests) {
      if (req.attempt >= MAX_ATTEMPTS) {
        System.debug(
          LoggingLevel.ERROR,
          'Cascade cancel dropped after ' +
            MAX_ATTEMPTS +
            ' attempts: ' +
            req.rootId
        );
        continue;
      }
      retries.add(buildEvent(req.rootId, req.targetIds, req.attempt + 1));
    }
    publish(retries);
  }

  private static List<Workflow_Event__e> buildContinuationEvents(
    Id rootId,
    List<Id> remaining,
    Integer attempt
  ) {
    List<Workflow_Event__e> events = new List<Workflow_Event__e>();
    List<Id> chunk = new List<Id>();
    for (Id nodeId : remaining) {
      chunk.add(nodeId);
      if (chunk.size() == CONTINUATION_CHUNK) {
        events.add(buildEvent(rootId, chunk, attempt));
        chunk = new List<Id>();
      }
    }
    if (!chunk.isEmpty()) {
      events.add(buildEvent(rootId, chunk, attempt));
    }
    return events;
  }

  private static Workflow_Event__e buildEvent(
    Id rootId,
    List<Id> targetIds,
    Integer attempt
  ) {
    Map<String, Object> payload = new Map<String, Object>{
      'attempt' => attempt
    };
    if (!targetIds.isEmpty()) {
      payload.put('targets', targetIds);
    }
    return new Workflow_Event__e(
      Workflow_Instance_Id__c = rootId,
      Event_Type__c = EVENT_TYPE,
      Payload__c = JSON.serialize(payload)
    );
  }

  // Publishes best-effort. It skips the publish when the DML budget is spent,
  // because an over-budget publish throws an uncatchable LimitException.
  private static void publish(List<Workflow_Event__e> events) {
    if (events.isEmpty()) {
      return;
    }
    if (
      Limits.getDmlStatements() >= Limits.getLimitDmlStatements() ||
      Limits.getDmlRows() + events.size() > Limits.getLimitDmlRows()
    ) {
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
