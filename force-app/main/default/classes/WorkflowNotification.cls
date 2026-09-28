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
  /** @description Max static recipients. */
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

  private WorkflowNotification() {
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
    return new WorkflowNotification();
  }

  /**
   * @description Adds one recipient.
   * @param recipientId User, group or queue Id. Not null.
   * @return This notification.
   */
  public WorkflowNotification toRecipient(Id recipientId) {
    return this;
  }

  /**
   * @description Adds recipients.
   * @param ids User, group or queue Ids. Not null. No null element.
   * @return This notification.
   */
  public WorkflowNotification toRecipients(Set<Id> ids) {
    return this;
  }

  /**
   * @description Adds the recipients in a top-level workflow input key. The
   * value is one Id or a list of Ids. The engine reads it at the SUSPEND.
   * @param key Input key. Not blank.
   * @return This notification.
   */
  public WorkflowNotification toInputField(String key) {
    return this;
  }

  /**
   * @description Adds the owner (user or queue) of a record. The engine reads
   * the owner when it sends.
   * @param recordId Record Id. Not null. The object must have OwnerId.
   * @return This notification.
   */
  public WorkflowNotification toRecordOwner(Id recordId) {
    return this;
  }

  /**
   * @description Sets the deep-link record.
   * @param recordId Record Id. Not null.
   * @return This notification.
   */
  public WorkflowNotification withTarget(Id recordId) {
    return this;
  }

  /**
   * @description Sets the CustomNotificationType.
   * @param developerName Type developer name. Not blank.
   * @return This notification.
   */
  public WorkflowNotification withType(String developerName) {
    return this;
  }

  /**
   * @description Returns true when the notification has a recipient source.
   * @return True when a static, input or owner recipient is set.
   */
  public Boolean hasRecipientSource() {
    return false;
  }
}
