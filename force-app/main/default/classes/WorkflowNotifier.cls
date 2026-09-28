/**
 * @description Sends the Custom Notification of a waiting step (issue #123).
 * See docs/approver-notifications.md.
 */
public inherited sharing class WorkflowNotifier {
  /** @description Workflow_Event__e.Event_Type__c of a notify request. */
  public static final String EVENT_TYPE = 'NOTIFY';
  /** @description Workflow_Log__c.Log_Type__c of the anchor row. */
  public static final String LOG_TYPE = 'Notification';
  /** @description Outcome__c: the SUSPEND published the request. */
  public static final String OUTCOME_REQUESTED = 'Requested';
  /** @description Outcome__c: the trigger sent the notification. */
  public static final String OUTCOME_SENT = 'Sent';
  /** @description Outcome__c: the request or the send failed. */
  public static final String OUTCOME_FAILED = 'Failed';
  /** @description Outcome__c: the toggle was off at send time. */
  public static final String OUTCOME_SKIPPED = 'Skipped';

  /** @description One captured send (test context only). */
  public class SentNotification {
    public Id typeId;
    public String title;
    public String body;
    public Id targetId;
    public Set<String> recipients;
  }

  // Test captures and hooks.
  @TestVisible
  private static List<Workflow_Event__e> publishedEvents = new List<Workflow_Event__e>();
  @TestVisible
  private static List<SentNotification> sentNotifications = new List<SentNotification>();
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
    return null;
  }

  /**
   * @description Publishes the notify request of a SUSPEND or
   * WAIT_FOR_APPROVAL outcome. Never throws.
   * @param outcome Step outcome after the SUSPEND DML.
   */
  public static void request(WorkflowEngine.StepOutcomeContext outcome) {
    return;
  }

  /**
   * @description Sends the notifications of NOTIFY events. Never throws.
   * @param events NOTIFY events from WorkflowEventTriggerHandler.
   */
  public static void handleEvents(List<Workflow_Event__e> events) {
    return;
  }
}
