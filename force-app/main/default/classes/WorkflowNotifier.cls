/**
 * @description Sends the Custom Notification of a waiting step (issue #123).
 *
 * 1. {@link request} runs last in the SUSPEND and WAIT_FOR_APPROVAL handlers.
 *    It inserts one anchor `Workflow_Log__c` row (unique `Fire_Key__c`
 *    `Notify:<stepExecId>`) and publishes one `NOTIFY` `Workflow_Event__e`.
 *    The event is `PublishAfterCommit`: a rolled-back SUSPEND sends nothing.
 *    A second insert for the same step row fails: a re-suspend sends nothing.
 * 2. `WorkflowEventTriggerHandler` gives max {@link maxEventsPerPass} NOTIFY
 *    events to {@link handleEvents} in a new transaction. It publishes the
 *    other events again. `handleEvents` resolves the type and the record
 *    owners, sends, and sets the anchor row to `Sent`, `Failed` or `Skipped`.
 *
 * Fire-and-forget: no method throws. A notification error never stops the
 * SUSPEND or the trigger batch. See docs/approver-notifications.md.
 */
public inherited sharing class WorkflowNotifier {
  /** @description Workflow_Event__e.Event_Type__c of a notify request. */
  public static final String EVENT_TYPE = 'NOTIFY';
  /** @description Workflow_Log__c.Log_Type__c of the anchor row. */
  public static final String LOG_TYPE = 'Notification';
  /** @description Outcome__c: the SUSPEND published the request. */
  public static final String OUTCOME_REQUESTED = 'Requested';
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
  // NOTIFY events that one trigger pass sends. It bounds heap, CPU and DML.
  @TestVisible
  private static Integer eventsPerPass = 200;

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

  /**
   * @description Returns the Fire_Key__c of the anchor row of a step row.
   * @param stepExecId Workflow_Step_Execution__c Id.
   * @return The key.
   */
  public static String fireKey(Id stepExecId) {
    return FIRE_KEY_PREFIX + String.valueOf(stepExecId);
  }

  /**
   * @description Returns the maximum NOTIFY events for one trigger pass.
   * @return The maximum.
   */
  public static Integer maxEventsPerPass() {
    return eventsPerPass;
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

  // Publishes the NOTIFY event. On an error, sets the anchor row to Failed.
  private static void publish(
    Workflow_Log__c anchor,
    Map<String, Object> payload,
    Id instanceId
  ) {
    Workflow_Event__e evt = new Workflow_Event__e(
      Event_Type__c = EVENT_TYPE,
      Workflow_Instance_Id__c = String.valueOf(instanceId),
      Payload__c = JSON.serialize(payload),
      Idempotency_Key__c = anchor.Fire_Key__c
    );
    try {
      if (Test.isRunningTest() && throwPublishException) {
        throw new WorkflowEngine.WorkflowException(
          'Simulated EventBus.publish failure'
        );
      }
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

  // ─── Trigger side ─────────────────────────────────────────────────────────

  /**
   * @description Sends the notifications of NOTIFY events and sets each
   * anchor row to Sent, Failed or Skipped. A request whose row is already
   * Sent is not sent again. Never throws.
   * @param events NOTIFY events from WorkflowEventTriggerHandler.
   */
  public static void handleEvents(List<Workflow_Event__e> events) {
    if (events == null || events.isEmpty()) {
      return;
    }
    try {
      List<Map<String, Object>> requests = removeSent(parseRequests(events));
      if (requests.isEmpty()) {
        return;
      }
      List<Workflow_Log__c> rows = WorkflowEngine.sendNotifications
        ? sendAll(requests)
        : skipAll(requests);
      saveRows(rows);
    } catch (Exception e) {
      WorkflowLog.error(LOG_TYPE, 'Notify batch failed: ' + e.getMessage());
    }
  }

  // Parses each event payload. A bad payload is skipped.
  private static List<Map<String, Object>> parseRequests(
    List<Workflow_Event__e> events
  ) {
    List<Map<String, Object>> requests = new List<Map<String, Object>>();
    for (Workflow_Event__e evt : events) {
      try {
        Map<String, Object> req = (Map<String, Object>) JSON.deserializeUntyped(
          evt.Payload__c
        );
        if (String.isNotBlank((String) req.get('key'))) {
          requests.add(req);
        }
      } catch (Exception e) {
        continue; // Not a request from the engine: skip.
      }
    }
    return requests;
  }

  // Removes the requests whose anchor row is already Sent (a replayed event).
  private static List<Map<String, Object>> removeSent(
    List<Map<String, Object>> requests
  ) {
    if (requests.isEmpty() || Limits.getQueries() >= Limits.getLimitQueries()) {
      return requests;
    }
    Set<String> keys = new Set<String>();
    for (Map<String, Object> req : requests) {
      keys.add((String) req.get('key'));
    }
    Set<String> sent = new Set<String>();
    for (Workflow_Log__c row : [
      SELECT Fire_Key__c
      FROM Workflow_Log__c
      WHERE Fire_Key__c IN :keys AND Outcome__c = :OUTCOME_SENT
      WITH SYSTEM_MODE
    ]) {
      sent.add(row.Fire_Key__c.toLowerCase());
    }
    List<Map<String, Object>> open = new List<Map<String, Object>>();
    for (Map<String, Object> req : requests) {
      if (!sent.contains(((String) req.get('key')).toLowerCase())) {
        open.add(req);
      }
    }
    return open;
  }

  private static List<Workflow_Log__c> skipAll(
    List<Map<String, Object>> requests
  ) {
    List<Workflow_Log__c> rows = new List<Workflow_Log__c>();
    for (Map<String, Object> req : requests) {
      rows.add(
        resultRow(
          req,
          OUTCOME_SKIPPED,
          LEVEL_WARN,
          'Send_Notifications__c is off'
        )
      );
    }
    return rows;
  }

  private static List<Workflow_Log__c> sendAll(
    List<Map<String, Object>> requests
  ) {
    Set<String> typeNames = new Set<String>();
    Set<Id> ownerRecordIds = new Set<Id>();
    for (Map<String, Object> req : requests) {
      typeNames.add((String) req.get('type'));
      ownerRecordIds.addAll(ids(req.get('owners')));
    }
    resolveTypeIds(typeNames);
    Map<Id, Id> owners = resolveOwners(ownerRecordIds);

    List<Workflow_Log__c> rows = new List<Workflow_Log__c>();
    for (Map<String, Object> req : requests) {
      rows.add(sendOne(req, owners));
    }
    return rows;
  }

  private static Workflow_Log__c sendOne(
    Map<String, Object> req,
    Map<Id, Id> owners
  ) {
    try {
      String typeName = (String) req.get('type');
      Id typeId = typeIds.get(typeName);
      if (typeId == null) {
        return failed(req, 'CustomNotificationType not found: ' + typeName);
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
          req,
          'No recipient resolved (ignored ' + ignored + ' non-user Ids)'
        );
      }
      deliver(typeId, req, recipients);
      return resultRow(
        req,
        OUTCOME_SENT,
        LEVEL_INFO,
        'Sent to ' +
          recipients.size() +
          ' recipients (ignored ' +
          ignored +
          ' non-user Ids)'
      );
    } catch (Exception e) {
      return failed(req, 'Send failed: ' + e.getMessage());
    }
  }

  // Sends in chunks of SEND_CHUNK_SIZE (the limit of one send call).
  private static void deliver(
    Id typeId,
    Map<String, Object> req,
    Set<String> recipients
  ) {
    Id targetId = Id.valueOf((String) req.get('target'));
    if (Test.isRunningTest()) {
      for (Set<String> chunk : chunks(recipients)) {
        capture(typeId, req, targetId, chunk);
      }
      return;
    }
    Messaging.CustomNotification notification = new Messaging.CustomNotification();
    notification.setNotificationTypeId(typeId);
    notification.setTitle((String) req.get('title'));
    notification.setBody((String) req.get('body'));
    notification.setTargetId(targetId);
    for (Set<String> chunk : chunks(recipients)) {
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
      Schema.DescribeSObjectResult typeDescribe = sobjectType.getDescribe();
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

  // Upserts the result rows on Fire_Key__c and logs the rows that fail.
  private static void saveRows(List<Workflow_Log__c> rows) {
    if (
      Limits.getDmlStatements() + 2 > Limits.getLimitDmlStatements() ||
      Limits.getDmlRows() + rows.size() + 1 > Limits.getLimitDmlRows()
    ) {
      return; // The rows stay Requested.
    }
    List<String> errors = new List<String>();
    List<Database.UpsertResult> results = Database.upsert(
      rows,
      Workflow_Log__c.Fire_Key__c,
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
        'Result row upsert failed: ' + String.join(errors, '; ')
      );
    }
  }

  private static Workflow_Log__c failed(
    Map<String, Object> req,
    String reason
  ) {
    return resultRow(req, OUTCOME_FAILED, LEVEL_ERROR, reason);
  }

  // The upsert on Fire_Key__c updates the anchor row. When the anchor row is
  // not there, it inserts a new row. The row does not set the instance lookup:
  // the instance can be deleted before the send.
  private static Workflow_Log__c resultRow(
    Map<String, Object> req,
    String outcome,
    String level,
    String result
  ) {
    return new Workflow_Log__c(
      Fire_Key__c = (String) req.get('key'),
      Log_Type__c = LOG_TYPE,
      Outcome__c = outcome,
      Level__c = level,
      Message__c = withResult(req, result)
    );
  }

  // Returns the request JSON with a result key.
  private static String withResult(Map<String, Object> req, String result) {
    Map<String, Object> message = new Map<String, Object>(req);
    message.put('result', result);
    return truncate(JSON.serialize(message));
  }

  private static String truncate(String text) {
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
