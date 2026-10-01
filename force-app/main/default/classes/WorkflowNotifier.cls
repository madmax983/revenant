/**
 * @description Sends the Custom Notification of a waiting step (issue #123).
 *
 * 1. {@link request} runs last in the SUSPEND and WAIT_FOR_APPROVAL handlers.
 *    It inserts one anchor `Workflow_Log__c` row (unique `Fire_Key__c`
 *    `Notify:<stepExecId>`). The row holds the request. Then it publishes one
 *    `NOTIFY` `Workflow_Event__e` with the key in `Idempotency_Key__c`. The
 *    event is `PublishAfterCommit`: a rolled-back SUSPEND sends nothing. A
 *    second insert for the same step row fails: a re-suspend sends nothing.
 * 2. `WorkflowNotifyTrigger` calls {@link handleEvents} in its own
 *    transaction, apart from the engine trigger. It reads the request from
 *    each `Requested` anchor row, not from the event. It sends only while the
 *    step waits, with max {@link maxSendCallsPerPass} send calls, and
 *    publishes the rest again. It sets each row to `Sent`, `Failed` or
 *    `Skipped`.
 *
 * A row that no event reaches stays `Requested`: WorkflowNotifierSweep
 * publishes its request again.
 *
 * Fire-and-forget: a notification error never stops the SUSPEND or the
 * engine. See docs/approver-notifications.md.
 */
public inherited sharing class WorkflowNotifier {
  /** @description Workflow_Event__e.Event_Type__c of a notify request. */
  public static final String EVENT_TYPE = 'NOTIFY';
  /** @description Workflow_Log__c.Log_Type__c of the anchor row. */
  public static final String LOG_TYPE = 'Notification';
  /** @description Outcome__c: the SUSPEND published the request. */
  public static final String OUTCOME_REQUESTED = 'Requested';
  /** @description Outcome__c: the trigger claimed the row to send it. */
  public static final String OUTCOME_SENDING = 'Sending';
  /** @description Outcome__c: the platform accepted the send. */
  public static final String OUTCOME_SENT = 'Sent';
  /** @description Outcome__c: the request or the send failed. */
  public static final String OUTCOME_FAILED = 'Failed';
  /** @description Outcome__c: the toggle was off at send time. */
  public static final String OUTCOME_SKIPPED = 'Skipped';

  private static final String FIRE_KEY_PREFIX = 'Notify:';
  private static final String LEVEL_INFO = 'Info';
  private static final String LEVEL_WARN = 'Warn';
  private static final String LEVEL_ERROR = 'Error';
  private static final Integer MAX_MESSAGE_LENGTH = 131000;
  // Largest workflow input that toInputKey parses. A larger parse can hit the
  // heap limit, and that error stops the SUSPEND.
  @TestVisible
  private static Integer maxInputParseLength = 1000000;
  // Recipients of one Messaging.CustomNotification.send() call.
  private static final Integer SEND_CHUNK_SIZE = 500;
  // DML statements and rows of one request: insert, publish, update or log.
  private static final Integer REQUEST_DML = 3;
  // Recipient types that send() accepts. A queue is a Group.
  private static final Set<Schema.SObjectType> RECIPIENT_TYPES = new Set<Schema.SObjectType>{
    User.SObjectType,
    Group.SObjectType
  };

  // Headroom for DML that runs after the request in the SUSPEND transaction.
  // Same values as WorkflowOutboundEventPublisher.
  @TestVisible
  private static Integer dmlStatementReserve = 10;
  @TestVisible
  private static Integer dmlRowReserve = 20;
  // Times the platform delivers a batch again before the pass stops.
  private static final Integer MAX_RETRIES = 5;
  // NOTIFY keys that one trigger pass reads. Equal to the send-call cap: a
  // pass cannot send more requests. It bounds heap: max 10 messages of
  // 131,000 characters.
  @TestVisible
  private static Integer eventsPerPass = 10;
  // True after the first claim of a pass: then a retry can send again.
  private static Boolean sendStarted = false;
  // send() calls in one pass. Apex allows max 10 notification calls in one
  // transaction, and that LimitException cannot be caught.
  @TestVisible
  private static Integer sendCallsPerPass = 10;

  /** @description One captured send call (test context only). */
  public class SentNotification {
    /** @description CustomNotificationType Id. */
    public Id typeId;
    /** @description Title. */
    public String title;
    /** @description Body. */
    public String body;
    /** @description Deep-link record. */
    public Id targetId;
    /** @description Recipients of this send call. */
    public Set<String> recipients;
  }

  // Test captures and hooks. Test context records each send call and does not
  // call Messaging.CustomNotification.send().
  @TestVisible
  private static List<Workflow_Event__e> publishedEvents = new List<Workflow_Event__e>();
  @TestVisible
  private static List<SentNotification> sentNotifications = new List<SentNotification>();
  // Type Ids by developer name. Tests can seed it.
  @TestVisible
  private static Map<String, Id> typeIds = new Map<String, Id>();
  @TestVisible
  private static Boolean throwPublishException = false;
  @TestVisible
  private static Boolean throwSendException = false;
  @TestVisible
  private static Boolean forceDmlBudgetExhausted = false;
  @TestVisible
  private static Boolean forceResultDmlExhausted = false;
  @TestVisible
  private static Boolean forceQueryBudgetExhausted = false;
  @TestVisible
  private static Boolean forceClaimFailure = false;

  /**
   * @description Returns the Fire_Key__c of the anchor row of a step row.
   * @param stepExecId Workflow_Step_Execution__c Id.
   * @return The key.
   */
  public static String fireKey(Id stepExecId) {
    return FIRE_KEY_PREFIX + String.valueOf(stepExecId);
  }

  /**
   * @description Returns the maximum send() calls for one trigger pass.
   * @return The maximum.
   */
  public static Integer maxSendCallsPerPass() {
    return sendCallsPerPass;
  }

  // ─── SUSPEND side ─────────────────────────────────────────────────────────

  /**
   * @description Publishes the notify request of a SUSPEND or
   * WAIT_FOR_APPROVAL outcome. Call it after the SUSPEND DML. Never throws.
   * @param outcome Step outcome. The step row must have an Id.
   */
  public static void request(WorkflowEngine.StepOutcomeContext outcome) {
    WorkflowNotification notification = outcome
      ?.result
      ?.directive()
      ?.notification;
    if (
      notification == null ||
      !WorkflowEngine.sendNotifications ||
      outcome.stepExec?.Id == null
    ) {
      return;
    }
    try {
      if (wokenAtSuspend(outcome.instance.Id)) {
        // A buffered signal woke the instance in this transaction. The step
        // runs again. When it suspends again, that suspend notifies.
        return;
      }
      if (wouldExceedDmlBudget()) {
        // No DML is left for a log row.
        System.debug(
          LoggingLevel.WARN,
          'WorkflowNotifier: DML budget low, no request for ' +
          outcome.stepExec.Id
        );
        return;
      }
      String key = fireKey(outcome.stepExec.Id);
      Map<String, Object> payload = buildPayload(key, outcome, notification);
      Workflow_Log__c anchor = new Workflow_Log__c(
        Log_Type__c = LOG_TYPE,
        Level__c = LEVEL_INFO,
        Outcome__c = OUTCOME_REQUESTED,
        Fire_Key__c = key,
        Fire_Time__c = Datetime.now(),
        Message__c = truncate(JSON.serialize(payload)),
        Workflow_Instance__c = outcome.instance.Id,
        Workflow_Name__c = outcome.instance.Workflow_Name__c,
        Correlation_Key__c = outcome.instance.Correlation_Key__c
      );
      Database.SaveResult sr = Database.insert(
        anchor,
        false,
        AccessLevel.SYSTEM_MODE
      );
      if (sr.isSuccess()) {
        publish(anchor, payload, outcome.instance.Id);
      } else if (!isDuplicate(sr.getErrors())) {
        // A duplicate key means that this suspend already has a request.
        WorkflowLog.error(
          new WorkflowLog.ErrorEntry(
              LOG_TYPE,
              'Anchor insert failed: ' + errorText(sr.getErrors())
            )
            .withInstanceId(outcome.instance.Id)
        );
      }
    } catch (Exception ignored) {
      // Fire-and-forget: a notification error never stops the SUSPEND.
    }
  }

  // True when the instance is no longer Suspended after the SUSPEND DML:
  // signal redelivery woke it. One SOQL.
  private static Boolean wokenAtSuspend(Id instanceId) {
    if (Limits.getQueries() >= Limits.getLimitQueries()) {
      return true; // Cannot check: do not risk a stale notification.
    }
    List<Workflow_Instance__c> rows = [
      SELECT Status__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
      WITH SYSTEM_MODE
      LIMIT 1
    ];
    return !rows.isEmpty() && rows[0].Status__c != 'Suspended';
  }

  // True when the request could spend DML that the SUSPEND transaction needs.
  // Over the limit, DML throws an uncatchable LimitException.
  private static Boolean wouldExceedDmlBudget() {
    return forceDmlBudgetExhausted ||
      Limits.getDmlStatements() + REQUEST_DML + dmlStatementReserve >
      Limits.getLimitDmlStatements() ||
      Limits.getDmlRows() + REQUEST_DML + dmlRowReserve >
      Limits.getLimitDmlRows();
  }

  private static Boolean isDuplicate(List<Database.Error> errors) {
    for (Database.Error err : errors) {
      if (err.getStatusCode() == StatusCode.DUPLICATE_VALUE) {
        return true;
      }
    }
    return false;
  }

  private static Map<String, Object> buildPayload(
    String key,
    WorkflowEngine.StepOutcomeContext outcome,
    WorkflowNotification notification
  ) {
    Set<String> recipients = new Set<String>();
    for (Id recipientId : notification.recipientIds) {
      recipients.add(String.valueOf(recipientId));
    }
    recipients.addAll(
      inputRecipients(
        notification.inputKeys,
        outcome.context?.workflowInputJson
      )
    );
    return new Map<String, Object>{
      'key' => key,
      'type' => notification.notificationType,
      'title' => notification.title,
      'body' => notification.body,
      'target' => notification.targetId != null
        ? notification.targetId
        : outcome.instance.Id,
      'recipients' => new List<String>(recipients),
      'owners' => new List<Id>(notification.ownerRecordIds)
    };
  }

  // Reads the recipient Ids in the input keys. The input is decoded and in
  // memory: no SOQL. A value that is not an Id is ignored.
  private static Set<String> inputRecipients(
    Set<String> inputKeys,
    String inputJson
  ) {
    Set<String> ids = new Set<String>();
    if (
      inputKeys.isEmpty() ||
      String.isBlank(inputJson) ||
      inputJson.length() > maxInputParseLength
    ) {
      return ids;
    }
    Object parsed;
    try {
      parsed = JSON.deserializeUntyped(inputJson);
    } catch (Exception e) {
      return ids;
    }
    if (!(parsed instanceof Map<String, Object>)) {
      return ids;
    }
    Map<String, Object> input = (Map<String, Object>) parsed;
    for (String inputKey : inputKeys) {
      Object value = input.get(inputKey);
      List<Object> values = value instanceof List<Object>
        ? (List<Object>) value
        : new List<Object>{ value };
      for (Object candidate : values) {
        addId(candidate, ids);
      }
    }
    return ids;
  }

  private static void addId(Object candidate, Set<String> ids) {
    if (!(candidate instanceof String)) {
      return;
    }
    try {
      ids.add(String.valueOf(Id.valueOf((String) candidate)));
    } catch (Exception e) {
      return; // Not an Id: ignore.
    }
  }

  // Publishes the NOTIFY event. The event holds only the key: the trigger
  // reads the request from the anchor row. On an error, sets the row to Failed.
  private static void publish(
    Workflow_Log__c anchor,
    Map<String, Object> payload,
    Id instanceId
  ) {
    try {
      if (Test.isRunningTest() && throwPublishException) {
        throw new WorkflowEngine.WorkflowException(
          'Simulated EventBus.publish failure'
        );
      }
      Workflow_Event__e evt = notifyEvent(
        anchor.Fire_Key__c,
        String.valueOf(instanceId)
      );
      Database.SaveResult sr = EventBus.publish(evt);
      if (!sr.isSuccess()) {
        throw new WorkflowEngine.WorkflowException(errorText(sr.getErrors()));
      }
      if (Test.isRunningTest()) {
        publishedEvents.add(evt);
      }
    } catch (Exception e) {
      anchor.Outcome__c = OUTCOME_FAILED;
      anchor.Level__c = LEVEL_ERROR;
      anchor.Message__c = withResult(
        payload,
        'Publish failed: ' + e.getMessage()
      );
      Database.update(anchor, false, AccessLevel.SYSTEM_MODE);
    }
  }

  /**
   * @description Builds the NOTIFY event of a key. It holds only the key.
   * @param key Fire_Key__c of the anchor row.
   * @param instanceId Instance Id text, or null.
   * @return The event.
   */
  public static Workflow_Event__e notifyEvent(String key, String instanceId) {
    return new Workflow_Event__e(
      Event_Type__c = EVENT_TYPE,
      Workflow_Instance_Id__c = instanceId,
      Idempotency_Key__c = key
    );
  }

  // ─── Trigger side ─────────────────────────────────────────────────────────

  // One open request: its anchor row and the request that the row holds.
  private class OpenRequest {
    public Workflow_Log__c anchor;
    public Map<String, Object> req;
    // Set when the request is ready to send.
    public Id typeId;
    public List<Set<String>> chunks;
    public String summary;
    public OpenRequest(Workflow_Log__c anchor, Map<String, Object> req) {
      this.anchor = anchor;
      this.req = req;
    }
  }

  /**
   * @description Sends the notifications of the NOTIFY events in a batch.
   * `WorkflowNotifyTrigger` calls it in its own transaction. It ignores other
   * event types. It reads each request from its `Requested` anchor row, so an
   * event with no such row (a replay, a copy or a forged event) sends nothing.
   * It sets each row to Sent, Failed or Skipped. It throws only
   * EventBus.RetryableException, and only before it sends.
   * @param events Workflow_Event__e records of one trigger batch.
   */
  public static void handleEvents(List<Workflow_Event__e> events) {
    Map<String, String> instanceByKey = notifyKeys(events);
    if (instanceByKey.isEmpty()) {
      return;
    }
    List<String> keys = new List<String>(instanceByKey.keySet());
    sendStarted = false;
    try {
      if (!hasQueryBudget(3) || !hasResultDml(keys.size())) {
        retryOrGiveUp('No budget before the send');
        return;
      }
      List<String> passKeys = new List<String>();
      List<String> laterKeys = new List<String>();
      for (String key : keys) {
        if (passKeys.size() < eventsPerPass) {
          passKeys.add(key);
        } else {
          laterKeys.add(key);
        }
      }
      // Publish the overflow before any send. On an error, nothing is sent
      // yet: ask the platform to deliver the batch again.
      if (!publishKeys(laterKeys, instanceByKey).isEmpty()) {
        retryOrGiveUp('Overflow publish failed');
        return;
      }
      List<Workflow_Log__c> anchors = openAnchors(passKeys);
      List<Workflow_Log__c> deferred = new List<Workflow_Log__c>();
      if (!WorkflowEngine.sendNotifications) {
        skipAll(anchors, 'Send_Notifications__c is off');
      } else if (!anchors.isEmpty()) {
        deferred = sendAll(skipEndedWaits(anchors));
      }
      List<String> deferredKeys = new List<String>();
      for (Workflow_Log__c anchor : deferred) {
        deferredKeys.add(anchor.Fire_Key__c);
      }
      // A request that cannot be published again fails now. Else its row
      // stays Requested with no event.
      Set<String> lost = publishKeys(deferredKeys, instanceByKey);
      List<Workflow_Log__c> waiting = new List<Workflow_Log__c>();
      for (Workflow_Log__c anchor : deferred) {
        if (lost.contains(anchor.Fire_Key__c)) {
          setResult(
            anchor,
            null,
            OUTCOME_FAILED,
            LEVEL_ERROR,
            'Publish for a later pass failed'
          );
        } else {
          waiting.add(anchor);
        }
      }
      saveRows(anchors, waiting);
    } catch (EventBus.RetryableException e) {
      throw e;
    } catch (Exception e) {
      if (!sendStarted) {
        // Nothing is sent yet (for example, a row lock timed out): ask the
        // platform to deliver the batch again.
        retryOrGiveUp('Error before the send: ' + e.getMessage());
      }
      WorkflowLog.error(LOG_TYPE, 'Notify batch failed: ' + e.getMessage());
    }
  }

  // Returns the NOTIFY keys of the batch, in order, one time each, with the
  // instance Id of the event.
  private static Map<String, String> notifyKeys(
    List<Workflow_Event__e> events
  ) {
    Map<String, String> instanceByKey = new Map<String, String>();
    if (events == null) {
      return instanceByKey;
    }
    for (Workflow_Event__e evt : events) {
      String key = evt.Idempotency_Key__c;
      if (
        evt.Event_Type__c == EVENT_TYPE &&
        String.isNotBlank(key) &&
        key.startsWith(FIRE_KEY_PREFIX) &&
        !instanceByKey.containsKey(key)
      ) {
        instanceByKey.put(key, evt.Workflow_Instance_Id__c);
      }
    }
    return instanceByKey;
  }

  // Nothing is sent yet: ask the platform to deliver the batch again. After
  // MAX_RETRIES, stop: the rows stay Requested. WorkflowNotifierSweep
  // publishes them again.
  private static void retryOrGiveUp(String reason) {
    Integer retries;
    try {
      retries = EventBus.TriggerContext.currentContext().retries;
    } catch (Exception e) {
      retries = null;
    }
    if (retries != null && retries < MAX_RETRIES) {
      throw new EventBus.RetryableException(reason);
    }
    System.debug(LoggingLevel.WARN, 'WorkflowNotifier: ' + reason);
  }

  // Reads and locks the Requested anchor rows of the keys. One SOQL. The lock
  // makes two passes with the same key wait for each other.
  private static List<Workflow_Log__c> openAnchors(List<String> keys) {
    if (keys.isEmpty()) {
      return new List<Workflow_Log__c>();
    }
    return [
      SELECT Id, Fire_Key__c, Message__c, Workflow_Instance__c
      FROM Workflow_Log__c
      WHERE
        Fire_Key__c IN :keys
        AND Log_Type__c = :LOG_TYPE
        AND Outcome__c = :OUTCOME_REQUESTED
      WITH SYSTEM_MODE
      FOR UPDATE
    ];
  }

  private static void skipAll(List<Workflow_Log__c> anchors, String reason) {
    for (Workflow_Log__c anchor : anchors) {
      setResult(anchor, null, OUTCOME_SKIPPED, LEVEL_WARN, reason);
    }
  }

  // Skips the requests whose wait ended: the step row is not Pending, or the
  // instance is not active. A parallel instance can be Running while one
  // branch waits, so Running with a Pending row is still a wait. One SOQL.
  private static List<Workflow_Log__c> skipEndedWaits(
    List<Workflow_Log__c> anchors
  ) {
    Set<Id> stepIds = new Set<Id>();
    for (Workflow_Log__c anchor : anchors) {
      Id stepId = stepExecIdOf(anchor.Fire_Key__c);
      if (stepId != null) {
        stepIds.add(stepId);
      }
    }
    Set<Id> waiting = new Set<Id>();
    for (Workflow_Step_Execution__c row : [
      SELECT Id, Workflow_Instance__r.Status__c
      FROM Workflow_Step_Execution__c
      WHERE Id IN :stepIds AND Status__c = 'Pending'
      WITH SYSTEM_MODE
    ]) {
      if (
        WorkflowEngine.ACTIVE_STATUSES.contains(
          row.Workflow_Instance__r.Status__c
        )
      ) {
        waiting.add(row.Id);
      }
    }
    List<Workflow_Log__c> open = new List<Workflow_Log__c>();
    for (Workflow_Log__c anchor : anchors) {
      if (waiting.contains(stepExecIdOf(anchor.Fire_Key__c))) {
        open.add(anchor);
      } else {
        setResult(
          anchor,
          null,
          OUTCOME_SKIPPED,
          LEVEL_INFO,
          'The wait ended before the send'
        );
      }
    }
    return open;
  }

  private static Id stepExecIdOf(String key) {
    try {
      return Id.valueOf(key.substringAfter(FIRE_KEY_PREFIX));
    } catch (Exception e) {
      return null;
    }
  }

  // True when the pass has the given number of SOQL queries left.
  private static Boolean hasQueryBudget(Integer queries) {
    return !forceQueryBudgetExhausted &&
      Limits.getQueries() + queries <= Limits.getLimitQueries();
  }

  // Sends the requests in a send-call budget. Returns the rows to send in a
  // later pass. Sets the result on each other row. When the pass cannot run
  // the type and owner queries, all requests wait for a later pass.
  private static List<Workflow_Log__c> sendAll(List<Workflow_Log__c> anchors) {
    List<OpenRequest> requests = new List<OpenRequest>();
    Set<String> typeNames = new Set<String>();
    for (Workflow_Log__c anchor : anchors) {
      Map<String, Object> req = readRequest(anchor);
      if (req == null) {
        setResult(
          anchor,
          null,
          OUTCOME_FAILED,
          LEVEL_ERROR,
          'The request in Message__c is not readable'
        );
        continue;
      }
      requests.add(new OpenRequest(anchor, req));
      if (req.get('type') instanceof String) {
        typeNames.add((String) req.get('type'));
      }
    }
    // Admit requests while their owner queries fit the budget: one SOQL for
    // the types, plus one for each owner object type. The rest wait for a
    // later pass. The first request always fits: max 10 owner types.
    Set<Schema.SObjectType> ownerTypes = new Set<Schema.SObjectType>();
    List<OpenRequest> admitted = new List<OpenRequest>();
    List<Workflow_Log__c> waiting = new List<Workflow_Log__c>();
    Set<Id> ownerRecordIds = new Set<Id>();
    for (OpenRequest open : requests) {
      Set<Id> owners = ids(open.req.get('owners'));
      Set<Schema.SObjectType> merged = new Set<Schema.SObjectType>(ownerTypes);
      for (Id recordId : owners) {
        merged.add(recordId.getSObjectType());
      }
      if (hasQueryBudget(1 + merged.size())) {
        ownerTypes = merged;
        ownerRecordIds.addAll(owners);
        admitted.add(open);
      } else {
        waiting.add(open.anchor);
      }
    }
    requests = admitted;
    resolveTypeIds(typeNames);
    Map<Id, Id> owners = resolveOwners(ownerRecordIds);

    List<Workflow_Log__c> deferred = new List<Workflow_Log__c>(waiting);
    List<OpenRequest> ready = new List<OpenRequest>();
    Integer callsLeft = sendCallsPerPass;
    for (OpenRequest open : requests) {
      Integer used = planOne(open, owners, callsLeft);
      if (used < 0) {
        deferred.add(open.anchor);
      } else if (used > 0) {
        ready.add(open);
        callsLeft -= used;
      }
    }
    deferred.addAll(claimAndSend(ready));
    return deferred;
  }

  // Claims each ready row (Outcome__c = Sending) before the send. Sends only
  // the rows whose claim succeeded: a row that is not Requested is never read
  // again, so a failed result update cannot cause a second send. Returns the
  // rows whose claim failed: they wait for a later pass.
  private static List<Workflow_Log__c> claimAndSend(List<OpenRequest> ready) {
    List<Workflow_Log__c> unclaimed = new List<Workflow_Log__c>();
    if (ready.isEmpty()) {
      return unclaimed;
    }
    if (Test.isRunningTest() && forceClaimFailure) {
      for (OpenRequest open : ready) {
        unclaimed.add(open.anchor);
      }
      return unclaimed;
    }
    sendStarted = true;
    List<Workflow_Log__c> claims = new List<Workflow_Log__c>();
    for (OpenRequest open : ready) {
      claims.add(
        new Workflow_Log__c(Id = open.anchor.Id, Outcome__c = OUTCOME_SENDING)
      );
    }
    List<Database.SaveResult> results = Database.update(
      claims,
      false,
      AccessLevel.SYSTEM_MODE
    );
    for (Integer i = 0; i < ready.size(); i++) {
      OpenRequest open = ready[i];
      if (!results[i].isSuccess()) {
        unclaimed.add(open.anchor);
        continue;
      }
      try {
        deliver(open.typeId, open.req, open.chunks);
        setResult(
          open.anchor,
          open.req,
          OUTCOME_SENT,
          LEVEL_INFO,
          open.summary
        );
      } catch (Exception e) {
        failed(open, 'Send failed: ' + e.getMessage());
      }
    }
    return unclaimed;
  }

  /**
   * @description Reads the request of an anchor row.
   * @param anchor Row with Fire_Key__c and Message__c.
   * @return The request, or null when it is not readable or has another key.
   */
  public static Map<String, Object> readRequest(Workflow_Log__c anchor) {
    try {
      Map<String, Object> req = (Map<String, Object>) JSON.deserializeUntyped(
        anchor.Message__c
      );
      return anchor.Fire_Key__c.equalsIgnoreCase((String) req.get('key'))
        ? req
        : null;
    } catch (Exception e) {
      return null;
    }
  }

  // Plans one request. Returns the send calls it needs (the request is then
  // ready), 0 when it failed, or -1 when the calls left are not sufficient
  // (send it in a later pass).
  private static Integer planOne(
    OpenRequest open,
    Map<Id, Id> owners,
    Integer callsLeft
  ) {
    Map<String, Object> req = open.req;
    try {
      String typeName = (String) req.get('type');
      Id typeId = typeIds.get(typeName);
      if (typeId == null) {
        return failed(open, 'CustomNotificationType not found: ' + typeName);
      }
      Set<Id> candidates = ids(req.get('recipients'));
      for (Id recordId : ids(req.get('owners'))) {
        if (owners.containsKey(recordId)) {
          candidates.add(owners.get(recordId));
        }
      }
      Set<String> recipients = new Set<String>();
      for (Id candidate : candidates) {
        if (RECIPIENT_TYPES.contains(candidate.getSObjectType())) {
          recipients.add(String.valueOf(candidate));
        }
      }
      Integer ignored = candidates.size() - recipients.size();
      if (recipients.isEmpty()) {
        return failed(
          open,
          'No recipient resolved (ignored ' + ignored + ' non-user Ids)'
        );
      }
      List<Set<String>> chunks = chunks(recipients);
      if (chunks.size() > sendCallsPerPass) {
        return failed(
          open,
          'Too many recipients: max ' +
            (sendCallsPerPass * SEND_CHUNK_SIZE) +
            '. Use a public group.'
        );
      }
      if (chunks.size() > callsLeft) {
        return -1;
      }
      open.typeId = typeId;
      open.chunks = chunks;
      open.summary =
        'Sent to ' +
        recipients.size() +
        ' recipients (ignored ' +
        ignored +
        ' non-user Ids)';
      return chunks.size();
    } catch (Exception e) {
      return failed(open, 'Send failed: ' + e.getMessage());
    }
  }

  // Sends one call for each chunk of SEND_CHUNK_SIZE recipients.
  private static void deliver(
    Id typeId,
    Map<String, Object> req,
    List<Set<String>> chunks
  ) {
    Id targetId = Id.valueOf((String) req.get('target'));
    if (Test.isRunningTest()) {
      for (Set<String> chunk : chunks) {
        capture(typeId, req, targetId, chunk);
      }
      return;
    }
    Messaging.CustomNotification notification = new Messaging.CustomNotification();
    notification.setNotificationTypeId(typeId);
    notification.setTitle((String) req.get('title'));
    notification.setBody((String) req.get('body'));
    notification.setTargetId(targetId);
    for (Set<String> chunk : chunks) {
      notification.send(chunk);
    }
  }

  private static void capture(
    Id typeId,
    Map<String, Object> req,
    Id targetId,
    Set<String> chunk
  ) {
    if (throwSendException) {
      throw new WorkflowEngine.WorkflowException(
        'Simulated CustomNotification.send failure'
      );
    }
    SentNotification sent = new SentNotification();
    sent.typeId = typeId;
    sent.title = (String) req.get('title');
    sent.body = (String) req.get('body');
    sent.targetId = targetId;
    sent.recipients = chunk;
    sentNotifications.add(sent);
  }

  private static List<Set<String>> chunks(Set<String> recipients) {
    List<Set<String>> result = new List<Set<String>>();
    Set<String> current = new Set<String>();
    for (String recipient : recipients) {
      if (current.size() == SEND_CHUNK_SIZE) {
        result.add(current);
        current = new Set<String>();
      }
      current.add(recipient);
    }
    if (!current.isEmpty()) {
      result.add(current);
    }
    return result;
  }

  // Reads the Ids of the types that are not in the cache. One SOQL. A query
  // error leaves the types unresolved: each request then fails alone.
  private static void resolveTypeIds(Set<String> typeNames) {
    Set<String> missing = new Set<String>();
    for (String typeName : typeNames) {
      if (String.isNotBlank(typeName) && !typeIds.containsKey(typeName)) {
        missing.add(typeName);
      }
    }
    if (missing.isEmpty() || Limits.getQueries() >= Limits.getLimitQueries()) {
      return;
    }
    try {
      for (CustomNotificationType t : [
        SELECT Id, DeveloperName
        FROM CustomNotificationType
        WHERE DeveloperName IN :missing
        WITH SYSTEM_MODE
      ]) {
        typeIds.put(t.DeveloperName, t.Id);
      }
    } catch (Exception e) {
      return;
    }
  }

  // Reads the owner of each record. One SOQL for each object type. A type
  // with no OwnerId, or a query error, gives no owner.
  private static Map<Id, Id> resolveOwners(Set<Id> recordIds) {
    Map<Schema.SObjectType, Set<Id>> idsByType = new Map<Schema.SObjectType, Set<Id>>();
    for (Id recordId : recordIds) {
      Schema.SObjectType sobjectType = recordId.getSObjectType();
      if (!idsByType.containsKey(sobjectType)) {
        idsByType.put(sobjectType, new Set<Id>());
      }
      idsByType.get(sobjectType).add(recordId);
    }
    Map<Id, Id> owners = new Map<Id, Id>();
    for (Schema.SObjectType sobjectType : idsByType.keySet()) {
      if (Limits.getQueries() >= Limits.getLimitQueries()) {
        break;
      }
      owners.putAll(ownersOfType(sobjectType, idsByType.get(sobjectType)));
    }
    return owners;
  }

  private static Map<Id, Id> ownersOfType(
    Schema.SObjectType sobjectType,
    Set<Id> ids
  ) {
    Map<Id, Id> owners = new Map<Id, Id>();
    try {
      Schema.DescribeSObjectResult typeDescribe = sobjectType.getDescribe(); // NOPMD EagerlyLoadedDescribeSObjectResult: fields.getMap() needs the eager describe
      if (!typeDescribe.fields.getMap().containsKey('ownerid')) {
        return owners;
      }
      for (
        SObject rec : Database.queryWithBinds(
          'SELECT Id, OwnerId FROM ' +
            typeDescribe.getName() +
            ' WHERE Id IN :ids',
          new Map<String, Object>{ 'ids' => ids },
          AccessLevel.SYSTEM_MODE
        )
      ) {
        owners.put(rec.Id, (Id) rec.get('OwnerId'));
      }
    } catch (Exception e) {
      return owners;
    }
    return owners;
  }

  // ─── Result rows ──────────────────────────────────────────────────────────

  // Updates the rows that have a result and logs the rows that fail. A
  // deferred row stays Requested. handleEvents checked the DML budget.
  private static void saveRows(
    List<Workflow_Log__c> anchors,
    List<Workflow_Log__c> deferred
  ) {
    Set<Id> deferredIds = new Map<Id, Workflow_Log__c>(deferred).keySet();
    List<Workflow_Log__c> rows = new List<Workflow_Log__c>();
    for (Workflow_Log__c anchor : anchors) {
      if (!deferredIds.contains(anchor.Id)) {
        rows.add(anchor);
      }
    }
    if (rows.isEmpty()) {
      return;
    }
    List<String> errors = new List<String>();
    List<Database.SaveResult> results = Database.update(
      rows,
      false,
      AccessLevel.SYSTEM_MODE
    );
    for (Integer i = 0; i < results.size(); i++) {
      if (!results[i].isSuccess()) {
        errors.add(
          rows[i].Fire_Key__c + ': ' + errorText(results[i].getErrors())
        );
      }
    }
    if (!errors.isEmpty()) {
      WorkflowLog.error(
        LOG_TYPE,
        'Result row update failed: ' + String.join(errors, '; ')
      );
    }
  }

  // True when the pass can save its rows: the claim update, the result
  // update, two publishes for a later pass and one error row.
  private static Boolean hasResultDml(Integer rowCount) {
    return !forceResultDmlExhausted &&
      Limits.getDmlStatements() + 5 <= Limits.getLimitDmlStatements() &&
      Limits.getDmlRows() + (3 * rowCount) + 1 <= Limits.getLimitDmlRows();
  }

  // Publishes the keys again for a later pass. Returns the keys whose
  // publish failed.
  private static Set<String> publishKeys(
    List<String> keys,
    Map<String, String> instanceByKey
  ) {
    Set<String> lost = new Set<String>();
    if (keys.isEmpty()) {
      return lost;
    }
    List<Workflow_Event__e> events = new List<Workflow_Event__e>();
    for (String key : keys) {
      events.add(notifyEvent(key, instanceByKey.get(key)));
    }
    try {
      if (Test.isRunningTest() && throwPublishException) {
        throw new WorkflowEngine.WorkflowException(
          'Simulated EventBus.publish failure'
        );
      }
      List<Database.SaveResult> results = EventBus.publish(events);
      for (Integer i = 0; i < results.size(); i++) {
        if (!results[i].isSuccess()) {
          lost.add(keys[i]);
        }
      }
    } catch (Exception e) {
      lost.addAll(keys);
    }
    return lost;
  }

  private static Integer failed(OpenRequest open, String reason) {
    setResult(open.anchor, open.req, OUTCOME_FAILED, LEVEL_ERROR, reason);
    return 0;
  }

  // Sets the result on the anchor row. The message keeps the request.
  private static void setResult(
    Workflow_Log__c anchor,
    Map<String, Object> req,
    String outcome,
    String level,
    String result
  ) {
    anchor.Outcome__c = outcome;
    anchor.Level__c = level;
    if (req == null) {
      req = readRequest(anchor);
    }
    anchor.Message__c = req != null
      ? withResult(req, result)
      : truncate(result + '\n' + anchor.Message__c);
  }

  /**
   * @description Returns the request JSON with a result key.
   * @param req The request.
   * @param result The result text.
   * @return The JSON, cut at the length of Message__c.
   */
  public static String withResult(Map<String, Object> req, String result) {
    Map<String, Object> message = new Map<String, Object>(req);
    message.put('result', result);
    return truncate(JSON.serialize(message));
  }

  /**
   * @description Cuts a text at the length of Message__c.
   * @param text The text.
   * @return The text, or its first part.
   */
  public static String truncate(String text) {
    return text != null &&
      text.length() > MAX_MESSAGE_LENGTH
      ? text.substring(0, MAX_MESSAGE_LENGTH)
      : text;
  }

  // Returns the valid Ids in a JSON list. Other values are ignored.
  private static Set<Id> ids(Object value) {
    Set<String> found = new Set<String>();
    if (value instanceof List<Object>) {
      for (Object item : (List<Object>) value) {
        addId(item, found);
      }
    }
    Set<Id> result = new Set<Id>();
    for (String idText : found) {
      result.add(Id.valueOf(idText));
    }
    return result;
  }

  private static String errorText(List<Database.Error> errors) {
    List<String> parts = new List<String>();
    for (Database.Error err : errors) {
      parts.add(err.getStatusCode() + ': ' + err.getMessage());
    }
    return String.join(parts, ', ');
  }
}
