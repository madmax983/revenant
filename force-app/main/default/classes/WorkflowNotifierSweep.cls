/**
 * @description Publishes lost approver-notification requests again (issue
 * #274). The watchdog heartbeat calls {@link run}. A `Notification` anchor row
 * that is `Requested` for longer than {@link STALE_MINUTES} got no event
 * (for example, a publish error after the commit). The sweep publishes one
 * `NOTIFY` event for the key of each such row. After {@link MAX_ATTEMPTS}
 * attempts, the row is `Failed`.
 *
 * It never sends. `WorkflowNotifier.handleEvents` reads only `Requested`
 * rows and claims each row before the send, so a row is never sent twice.
 * See docs/approver-notifications.md.
 */
public inherited sharing class WorkflowNotifierSweep {
  /** @description Minutes a row waits after its request or last attempt. */
  public static final Integer STALE_MINUTES = 15;
  /** @description Publish attempts before the row is Failed. */
  public static final Integer MAX_ATTEMPTS = 3;
  /** @description Rows in one sweep: one trigger pass (10 send calls). */
  public static final Integer MAX_ROWS = 10;

  private static final String ATTEMPTS_KEY = 'attempts';
  // DML statements of one sweep: the row update and the publish.
  private static final Integer DML_STATEMENTS = 2;
  // Headroom for the liveness stamp that runs after the sweep: its own
  // reserve and its one statement.
  private static final Integer DML_RESERVE = WatchdogLiveness.DML_RESERVE + 1;

  // Test captures and hooks.
  @TestVisible
  private static List<Workflow_Event__e> publishedEvents = new List<Workflow_Event__e>();
  @TestVisible
  private static Boolean throwPublishException = false;
  @TestVisible
  private static Boolean forceDmlBudgetExhausted = false;

  /**
   * @description Publishes the request of each stale `Requested` row again,
   * oldest first, max {@link MAX_ROWS} rows. Counts the attempt in
   * `Message__c` and moves `Fire_Time__c` to now, so the next attempt waits
   * the full threshold. Fails a row at the attempt limit or with an unreadable
   * request.
   * @param now The time of the sweep.
   * @return The number of events that the sweep published.
   */
  public static Integer run(Datetime now) {
    if (!hasBudget()) {
      return 0;
    }
    Datetime cutoff = now.addMinutes(-STALE_MINUTES);
    List<Workflow_Log__c> stale = [
      SELECT Id, Fire_Key__c, Message__c, Workflow_Instance__c
      FROM Workflow_Log__c
      WHERE
        Log_Type__c = :WorkflowNotifier.LOG_TYPE
        AND Outcome__c = :WorkflowNotifier.OUTCOME_REQUESTED
        AND Fire_Time__c < :cutoff
      WITH SYSTEM_MODE
      ORDER BY Fire_Time__c
      LIMIT :MAX_ROWS
      FOR UPDATE
    ];
    List<Workflow_Log__c> retry = new List<Workflow_Log__c>();
    List<Workflow_Log__c> changed = new List<Workflow_Log__c>();
    for (Workflow_Log__c row : stale) {
      Map<String, Object> req = WorkflowNotifier.readRequest(row);
      if (req == null) {
        fail(row, new Map<String, Object>(), 'The request is not readable');
        changed.add(row);
        continue;
      }
      Integer attempts = req.get(ATTEMPTS_KEY) instanceof Integer
        ? (Integer) req.get(ATTEMPTS_KEY)
        : 0;
      if (attempts >= MAX_ATTEMPTS) {
        fail(row, req, MAX_ATTEMPTS + ' publish attempts gave no delivery');
      } else {
        req.put(ATTEMPTS_KEY, attempts + 1);
        row.Message__c = WorkflowNotifier.truncate(JSON.serialize(req));
        row.Fire_Time__c = now;
        retry.add(row);
      }
      changed.add(row);
    }
    return publishRetries(changed, retry);
  }

  // Saves the rows, then publishes the rows that the save counted. The save
  // goes first: a row whose count is lost must not be published, else it is
  // published with no limit.
  private static Integer publishRetries(
    List<Workflow_Log__c> changed,
    List<Workflow_Log__c> retry
  ) {
    if (changed.isEmpty()) {
      return 0;
    }
    List<Database.SaveResult> results = Database.update(
      changed,
      false,
      AccessLevel.SYSTEM_MODE
    );
    Set<Id> saved = new Set<Id>();
    for (Integer i = 0; i < results.size(); i++) {
      if (results[i].isSuccess()) {
        saved.add(changed[i].Id);
      }
    }
    List<Workflow_Event__e> events = new List<Workflow_Event__e>();
    for (Workflow_Log__c row : retry) {
      if (saved.contains(row.Id)) {
        events.add(
          WorkflowNotifier.notifyEvent(
            row.Fire_Key__c,
            String.valueOf(row.Workflow_Instance__c)
          )
        );
      }
    }
    return publish(events);
  }

  // Publishes the events. A failed publish is not an error: the row stays
  // Requested, and a later sweep tries again.
  private static Integer publish(List<Workflow_Event__e> events) {
    if (events.isEmpty()) {
      return 0;
    }
    Integer published = 0;
    try {
      if (Test.isRunningTest() && throwPublishException) {
        throw new WorkflowEngine.WorkflowException(
          'Simulated EventBus.publish failure'
        );
      }
      for (Database.SaveResult sr : EventBus.publish(events)) {
        if (sr.isSuccess()) {
          published++;
        }
      }
      if (Test.isRunningTest()) {
        publishedEvents.addAll(events);
      }
    } catch (Exception e) {
      System.debug(
        LoggingLevel.WARN,
        'WorkflowNotifierSweep: publish failed: ' + e.getMessage()
      );
    }
    return published;
  }

  private static void fail(
    Workflow_Log__c row,
    Map<String, Object> req,
    String reason
  ) {
    row.Outcome__c = WorkflowNotifier.OUTCOME_FAILED;
    row.Level__c = 'Error';
    row.Message__c = req.isEmpty()
      ? WorkflowNotifier.truncate(reason + '\n' + row.Message__c)
      : WorkflowNotifier.withResult(req, reason);
  }

  // True when the sweep can run its query and its DML, and the heartbeat
  // keeps its reserve for the DML after the sweep.
  private static Boolean hasBudget() {
    return !forceDmlBudgetExhausted &&
      Limits.getQueries() < Limits.getLimitQueries() &&
      Limits.getDmlStatements() + DML_STATEMENTS + DML_RESERVE <=
      Limits.getLimitDmlStatements() &&
      Limits.getDmlRows() + (2 * MAX_ROWS) + DML_RESERVE <=
      Limits.getLimitDmlRows();
  }
}
