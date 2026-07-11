/**
 * Publishes the outbound `Workflow_Lifecycle__e` platform event when a workflow
 * instance reaches a terminal state.
 *
 * Design contract (issue #14):
 * - Fires for the emitting terminal states only: Completed, Failed, Compensated,
 *   Cancelled. `ContinuedAsNew` is deliberately excluded so a continue-as-new
 *   chain emits exactly one event — on the final successor's terminal transition,
 *   never on a predecessor's hand-off.
 * - Carries outcome metadata only (instance Id, correlation key, workflow name,
 *   terminal status, isSuccess, failure detail) — never the full payload, which
 *   stays in `Workflow_Instance__c`/ContentVersion for subscribers to rehydrate.
 * - Fire-and-forget: a failed publish is logged but never thrown, so it can never
 *   roll back the terminal-state write or break the RUN_STEP Queueable chain. The
 *   event itself uses PublishAfterCommit, so a rolled-back transition produces no
 *   event at all.
 * - Operator-toggleable via Revenant_Config__mdt.Publish_Lifecycle_Events__c
 *   (default on), surfaced as WorkflowEngine.publishLifecycleEvents.
 * - Delivery is at-least-once; the event carries (instance Id + status) so an
 *   idempotent subscriber can ignore redeliveries.
 */
public inherited sharing class WorkflowLifecyclePublisher {
  // Terminal statuses that warrant a lifecycle event. ContinuedAsNew is a logical
  // hand-off, not a terminal outcome, so it is intentionally absent.
  private static final Set<String> EMITTING_TERMINAL_STATUSES = new Set<String>{
    'Completed',
    'Failed',
    'Compensated',
    'Cancelled'
  };

  private static final Integer FAILURE_DETAIL_MAX_LENGTH = 255;

  // Guards against emitting more than one event for the same transition within a
  // single transaction. Keyed on (instanceId + '|' + status + '|' + terminalAt)
  // so a Failed→retry→Failed sequence in the same transaction correctly emits
  // both events (different Terminal_At__c discriminator) rather than silently
  // dropping the second. (At-least-once delivery still applies across transactions.)
  @TestVisible
  private static Set<String> publishedTransitionKeys = new Set<String>();

  // Captures the events handed to EventBus.publish for test assertions, since
  // platform events cannot be queried via SOQL. Populated in test context only.
  @TestVisible
  private static List<Workflow_Lifecycle__e> publishedEvents = new List<Workflow_Lifecycle__e>();

  // When true (test context only), forces the publish path to simulate an
  // EventBus failure so failure-isolation can be proven.
  @TestVisible
  private static Boolean throwTestException = false;

  // When true (test context only), simulates an exhausted DML budget (statements
  // AND rows) so the limit-guard skip path can be proven without burning real limits.
  @TestVisible
  private static Boolean forceDmlBudgetExhausted = false;

  /**
   * Publishes a lifecycle event for a single instance, if it is in an emitting
   * terminal state. Safe to call after any instance write; non-terminal and
   * ContinuedAsNew statuses are silently ignored.
   */
  public static void publish(Workflow_Instance__c instance) {
    if (instance == null) {
      return;
    }
    publish(new List<Workflow_Instance__c>{ instance });
  }

  /**
   * Bulk variant for transitions that finalize many instances at once (e.g. the
   * watchdog heartbeat). Only emitting terminal states publish.
   *
   * The entire body is wrapped in a single catch-all: building an event reads
   * instance fields (e.g. Correlation_Key__c), and a caller passing an
   * under-queried SObject would otherwise throw an SObjectException that rolls
   * back the terminal-state write. Fire-and-forget must never disrupt the
   * workflow transaction, so any failure here is logged and swallowed.
   */
  public static void publish(List<Workflow_Instance__c> instances) {
    if (!WorkflowEngine.publishLifecycleEvents) {
      return;
    }
    if (instances == null || instances.isEmpty()) {
      return;
    }

    try {
      List<Workflow_Lifecycle__e> events = buildEvents(instances);
      if (events.isEmpty()) {
        return;
      }
      if (wouldExceedDmlBudget(events.size())) {
        return;
      }
      dispatch(events);
    } catch (Exception ignored) {
      // Fire-and-forget: log and swallow. A publish failure must never roll back
      // the terminal-state write, fail the instance, or break the RUN_STEP chain.
    }
  }

  /**
   * True when publishing eventCount events would spend the transaction's last
   * DML statement or DML rows. EventBus.publish consumes a DML statement AND one
   * DML row per event; over budget it throws an uncatchable System.LimitException
   * that would roll back the terminal-state write — defeating the fire-and-forget
   * contract precisely for high-limit workflows — so the best-effort events are
   * dropped instead.
   */
  private static Boolean wouldExceedDmlBudget(Integer eventCount) {
    return forceDmlBudgetExhausted ||
      Limits.getDmlStatements() >= Limits.getLimitDmlStatements() ||
      Limits.getDmlRows() + eventCount > Limits.getLimitDmlRows();
  }

  /**
   * Publishes the events to the event bus, capturing them for test assertions in
   * test context and honoring the injected failure hook.
   */
  private static void dispatch(List<Workflow_Lifecycle__e> events) {
    if (Test.isRunningTest() && throwTestException) {
      throw new WorkflowEngine.WorkflowException(
        'Simulated EventBus.publish failure'
      );
    }

    EventBus.publish(events);
    if (Test.isRunningTest()) {
      publishedEvents.addAll(events);
    }
  }

  private static List<Workflow_Lifecycle__e> buildEvents(
    List<Workflow_Instance__c> instances
  ) {
    List<Workflow_Lifecycle__e> events = new List<Workflow_Lifecycle__e>();
    for (Workflow_Instance__c instance : instances) {
      Workflow_Lifecycle__e event = buildEvent(instance);
      if (event != null) {
        events.add(event);
      }
    }
    return events;
  }

  /**
   * Builds the lifecycle event for a single instance, or returns null when the
   * instance is not in an emitting terminal state or its transition was already
   * published in this transaction.
   */
  private static Workflow_Lifecycle__e buildEvent(
    Workflow_Instance__c instance
  ) {
    if (instance == null || instance.Id == null) {
      return null;
    }
    // Read every optional field through getPopulatedFieldsAsMap so a caller that
    // passed an under-queried SObject yields a null field rather than an
    // SObjectException — the publish can never throw and roll back the terminal
    // write because of a missing field.
    Map<String, Object> f = instance.getPopulatedFieldsAsMap();
    String status = (String) f.get('Status__c');
    if (!EMITTING_TERMINAL_STATUSES.contains(status)) {
      return null;
    }

    // Prefer the instance's Terminal_At__c (stamped by the trigger at the actual
    // transition, so the event reconciles exactly with the record) and fall back
    // to now() only if the field wasn't populated on the in-memory record.
    Object terminalAtObj = f.get('Terminal_At__c');
    Datetime terminalAt = (terminalAtObj != null)
      ? (Datetime) terminalAtObj
      : System.now();

    // Dedupe on (instanceId + status + terminalAt) so a Failed→retry→Failed
    // sequence in the same transaction still emits two events — different
    // Terminal_At__c stamps mean different transitions — while a plain duplicate
    // publish call for the exact same transition is collapsed to one.
    String transitionKey =
      instance.Id +
      '|' +
      status +
      '|' +
      String.valueOf(terminalAt);
    if (publishedTransitionKeys.contains(transitionKey)) {
      return null;
    }
    publishedTransitionKeys.add(transitionKey);

    Boolean isSuccess = (status == 'Completed');

    // Carry the chain root key, falling back to the instance's own correlation
    // key for in-flight instances created before Root_Correlation_Key__c existed
    // (the field is only defaulted on insert, so legacy rows have it blank).
    String correlationKey = (String) f.get('Correlation_Key__c');
    String rootKey = (String) f.get('Root_Correlation_Key__c');
    if (String.isBlank(rootKey)) {
      rootKey = correlationKey;
    }

    return new Workflow_Lifecycle__e(
      Workflow_Instance_Id__c = instance.Id,
      Correlation_Key__c = correlationKey,
      Root_Correlation_Key__c = rootKey,
      Workflow_Name__c = (String) f.get('Workflow_Name__c'),
      Status__c = status,
      Is_Success__c = isSuccess,
      Terminal_At__c = terminalAt,
      Failure_Detail__c = isSuccess
        ? null
        : truncate(
            (String) f.get('Error_Message__c'),
            FAILURE_DETAIL_MAX_LENGTH
          )
    );
  }

  private static String truncate(String value, Integer maxLength) {
    if (value == null) {
      return null;
    }
    return value.length() > maxLength ? value.substring(0, maxLength) : value;
  }
}
