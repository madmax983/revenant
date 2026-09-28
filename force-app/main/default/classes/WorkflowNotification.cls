/**
 * @description Custom Notification request for a step that waits for a human
 * (issue #123). Add it to a SUSPEND or WAIT_FOR_APPROVAL result with
 * StepResult.withNotification(). The engine sends it once for each logical
 * suspend, after the SUSPEND commits. See docs/approver-notifications.md.
 */
public inherited sharing class WorkflowNotification {
  /** @description Default CustomNotificationType developer name. */
  public static final String DEFAULT_TYPE = 'Revenant_Workflow_Notification';
  /** @description Max title length. */
  public static final Integer MAX_TITLE_LENGTH = 250;
  /** @description Max body length. */
  public static final Integer MAX_BODY_LENGTH = 750;
  /** @description Max static recipients. Also the size of one send. */
  public static final Integer MAX_RECIPIENTS = 500;

  /** @description Notification title. */
  public String title { get; private set; }
  /** @description Notification body. */
  public String body { get; private set; }
  /** @description CustomNotificationType developer name. */
  public String typeName { get; private set; }
  /** @description Deep-link record. Null: the workflow instance. */
  public Id targetId { get; private set; }
  /** @description Static recipients (user, group or queue Ids). */
  public Set<Id> recipientIds { get; private set; }
  /** @description Workflow input keys that hold recipient Ids. */
  public Set<String> inputFields { get; private set; }
  /** @description Records whose owner gets the notification. */
  public Set<Id> ownerRecordIds { get; private set; }

  private WorkflowNotification(String title, String body) {
    this.title = title;
    this.body = body;
    this.typeName = DEFAULT_TYPE;
    this.recipientIds = new Set<Id>();
    this.inputFields = new Set<String>();
    this.ownerRecordIds = new Set<Id>();
  }

  /**
   * @description Makes a notification.
   * @param title Title. Not blank. Max MAX_TITLE_LENGTH characters.
   * @param body Body. Not blank. Max MAX_BODY_LENGTH characters.
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
    Set<Id> merged = new Set<Id>(this.recipientIds);
    merged.addAll(ids);
    if (merged.size() > MAX_RECIPIENTS) {
      throw new IllegalArgumentException(
        'WorkflowNotification: max ' +
          MAX_RECIPIENTS +
          ' static recipients. Use toInputField for a larger audience.'
      );
    }
    this.recipientIds = merged;
    return this;
  }

  /**
   * @description Adds the recipients in a top-level workflow input key. The
   * value is one Id or a list of Ids. The engine reads it at the SUSPEND and
   * ignores a value that is not an Id.
   * @param key Input key. Not blank.
   * @return This notification.
   */
  public WorkflowNotification toInputField(String key) {
    if (String.isBlank(key)) {
      throw new IllegalArgumentException(
        'WorkflowNotification.toInputField: key must not be blank'
      );
    }
    this.inputFields.add(key);
    return this;
  }

  /**
   * @description Adds the owner (user or queue) of a record. The engine reads
   * the owner when it sends.
   * @param recordId Record Id. Not null. The object must have OwnerId.
   * @return This notification.
   */
  public WorkflowNotification toRecordOwner(Id recordId) {
    requireRecordId(recordId, 'toRecordOwner');
    this.ownerRecordIds.add(recordId);
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
  public WorkflowNotification withType(String developerName) {
    if (String.isBlank(developerName)) {
      throw new IllegalArgumentException(
        'WorkflowNotification.withType: developerName must not be blank'
      );
    }
    this.typeName = developerName;
    return this;
  }

  /**
   * @description Returns true when the notification has a recipient source.
   * @return True when a static, input or owner recipient is set.
   */
  public Boolean hasRecipientSource() {
    return !recipientIds.isEmpty() ||
      !inputFields.isEmpty() ||
      !ownerRecordIds.isEmpty();
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
          ' must not be blank and must have max ' +
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
