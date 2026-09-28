/**
 * @description Custom Notification request for a step that waits for a human
 * (issue #123). Add it to a SUSPEND or WAIT_FOR_APPROVAL result with
 * StepResult.withNotification(). The engine sends it once for each logical
 * suspend, after the SUSPEND commits. See docs/approver-notifications.md.
 */
public inherited sharing class WorkflowNotification {
  /** @description Default CustomNotificationType developer name. */
  public static final String DEFAULT_TYPE = 'Revenant_Workflow_Notification';
  /** @description Maximum title length. */
  public static final Integer MAX_TITLE_LENGTH = 250;
  /** @description Maximum body length. */
  public static final Integer MAX_BODY_LENGTH = 750;
  /** @description Maximum static recipients. For more, use a group. */
  public static final Integer MAX_STATIC_RECIPIENTS = 500;
  /** @description Maximum object types for toRecordOwner (one SOQL each). */
  public static final Integer MAX_OWNER_OBJECT_TYPES = 10;

  private final Set<Id> recipients = new Set<Id>();
  private final Set<String> keys = new Set<String>();
  private final Set<Id> ownerRecords = new Set<Id>();

  /** @description Notification title. */
  public String title { get; private set; }
  /** @description Notification body. */
  public String body { get; private set; }
  /** @description CustomNotificationType developer name. */
  public String notificationType { get; private set; }
  /** @description Deep-link record. Null: the workflow instance. */
  public Id targetId { get; private set; }

  /** @description Copy of the static recipients (user, group or queue Ids). */
  public Set<Id> recipientIds {
    get {
      return new Set<Id>(recipients);
    }
  }
  /** @description Copy of the workflow input keys that hold recipient Ids. */
  public Set<String> inputKeys {
    get {
      return new Set<String>(keys);
    }
  }
  /** @description Copy of the records whose owner gets the notification. */
  public Set<Id> ownerRecordIds {
    get {
      return new Set<Id>(ownerRecords);
    }
  }

  private WorkflowNotification(String title, String body) {
    this.title = title;
    this.body = body;
    this.notificationType = DEFAULT_TYPE;
  }

  /**
   * @description Makes a notification.
   * @param title Title. Not blank. Maximum MAX_TITLE_LENGTH characters.
   * @param body Body. Not blank. Maximum MAX_BODY_LENGTH characters.
   * @return The notification.
   */
  public static WorkflowNotification create(String title, String body) {
    requireText(title, MAX_TITLE_LENGTH, 'title');
    requireText(body, MAX_BODY_LENGTH, 'body');
    return new WorkflowNotification(title, body);
  }

  /**
   * @description Adds one recipient.
   * @param recipientId User, group or queue Id. Not null.
   * @return This notification.
   */
  public WorkflowNotification toRecipient(Id recipientId) {
    if (recipientId == null) {
      throw new IllegalArgumentException(
        'WorkflowNotification.toRecipient: recipientId must not be null'
      );
    }
    return toRecipients(new Set<Id>{ recipientId });
  }

  /**
   * @description Adds recipients.
   * @param ids User, group or queue Ids. Not null. No null element.
   * @return This notification.
   */
  public WorkflowNotification toRecipients(Set<Id> ids) {
    if (ids == null || ids.contains(null)) {
      throw new IllegalArgumentException(
        'WorkflowNotification.toRecipients: ids must not be null or contain null'
      );
    }
    Set<Id> merged = new Set<Id>(recipients);
    merged.addAll(ids);
    if (merged.size() > MAX_STATIC_RECIPIENTS) {
      throw new IllegalArgumentException(
        'WorkflowNotification: maximum ' +
          MAX_STATIC_RECIPIENTS +
          ' static recipients. For more, use a public group.'
      );
    }
    recipients.addAll(ids);
    return this;
  }

  /**
   * @description Adds the recipients in a top-level workflow input key. The
   * value is one Id or a list of Ids. The engine reads it at the SUSPEND. It
   * ignores a value that is not a user or group Id.
   * @param key Input key. Not blank.
   * @return This notification.
   */
  public WorkflowNotification toInputKey(String key) {
    if (String.isBlank(key)) {
      throw new IllegalArgumentException(
        'WorkflowNotification.toInputKey: key must not be blank'
      );
    }
    keys.add(key);
    return this;
  }

  /**
   * @description Adds the owner (user or queue) of a record. The engine reads
   * the owner when it sends. When the object has no OwnerId, or the record is
   * not found, the engine ignores it. Maximum MAX_OWNER_OBJECT_TYPES object
   * types for each notification.
   * @param recordId Record Id. Not null.
   * @return This notification.
   */
  public WorkflowNotification toRecordOwner(Id recordId) {
    requireRecordId(recordId, 'toRecordOwner');
    Set<Schema.SObjectType> types = new Set<Schema.SObjectType>{
      recordId.getSObjectType()
    };
    for (Id existing : ownerRecords) {
      types.add(existing.getSObjectType());
    }
    if (types.size() > MAX_OWNER_OBJECT_TYPES) {
      throw new IllegalArgumentException(
        'WorkflowNotification.toRecordOwner: maximum ' +
          MAX_OWNER_OBJECT_TYPES +
          ' object types'
      );
    }
    ownerRecords.add(recordId);
    return this;
  }

  /**
   * @description Sets the deep-link record.
   * @param recordId Record Id. Not null.
   * @return This notification.
   */
  public WorkflowNotification withTarget(Id recordId) {
    requireRecordId(recordId, 'withTarget');
    this.targetId = recordId;
    return this;
  }

  /**
   * @description Sets the CustomNotificationType.
   * @param developerName Type developer name. Not blank.
   * @return This notification.
   */
  public WorkflowNotification withNotificationType(String developerName) {
    if (String.isBlank(developerName)) {
      throw new IllegalArgumentException(
        'WorkflowNotification.withNotificationType: developerName must not be blank'
      );
    }
    this.notificationType = developerName;
    return this;
  }

  /**
   * @description Returns true when the notification has a recipient source.
   * @return True when a static, input-key or owner recipient is set.
   */
  public Boolean hasRecipientSource() {
    return !recipients.isEmpty() || !keys.isEmpty() || !ownerRecords.isEmpty();
  }

  private static void requireText(
    String value,
    Integer maxLength,
    String name
  ) {
    if (String.isBlank(value) || value.length() > maxLength) {
      throw new IllegalArgumentException(
        'WorkflowNotification.create: ' +
          name +
          ' must not be blank and must have maximum ' +
          maxLength +
          ' characters'
      );
    }
  }

  private static void requireRecordId(Id recordId, String method) {
    if (recordId == null) {
      throw new IllegalArgumentException(
        'WorkflowNotification.' + method + ': recordId must not be null'
      );
    }
  }
}
