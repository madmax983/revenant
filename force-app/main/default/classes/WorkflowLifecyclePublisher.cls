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

  // Guards against emitting more than one event for the same instance within a
  // single transaction — belt-and-suspenders on top of the engine's write-once
  // terminal-state guard. (Delivery is still at-least-once across transactions.)
  @TestVisible
  private static Set<Id> publishedInstanceIds = new Set<Id>();

  // Captures the events handed to EventBus.publish for test assertions, since
  // platform events cannot be queried via SOQL. Populated in test context only.
  @TestVisible
  private static List<Workflow_Lifecycle__e> publishedEvents = new List<Workflow_Lifecycle__e>();

  // When true (test context only), forces the publish path to simulate an
  // EventBus failure so failure-isolation can be proven.
  @TestVisible
  private static Boolean throwTestException = false;

  // When true (test context only), simulates an exhausted DML-statement budget so
  // the limit-guard skip path can be proven without burning 150 real statements.
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

      // Never spend the transaction's last DML statement here. EventBus.publish
      // consumes a DML statement, and attempting it over budget throws an
      // uncatchable System.LimitException that would roll back the terminal-state
      // write — defeating the fire-and-forget contract precisely for the
      // high-limit workflows that need it most. Drop the best-effort event instead.
      if (
        forceDmlBudgetExhausted ||
        Limits.getDmlStatements() >= Limits.getLimitDmlStatements()
      ) {
        System.debug(
          LoggingLevel.WARN,
          'Skipping Workflow_Lifecycle__e publish: DML statement budget exhausted.'
        );
        return;
      }

      if (Test.isRunningTest() && throwTestException) {
        throw new WorkflowEngine.WorkflowException(
          'Simulated EventBus.publish failure'
        );
      }

      List<Database.SaveResult> results = EventBus.publish(events);
      for (Database.SaveResult sr : results) {
        if (!sr.isSuccess()) {
          for (Database.Error err : sr.getErrors()) {
            System.debug(
              LoggingLevel.WARN,
              'Workflow_Lifecycle__e publish error: ' +
                err.getStatusCode() +
                ': ' +
                err.getMessage()
            );
          }
        }
      }
      if (Test.isRunningTest()) {
        publishedEvents.addAll(events);
      }
    } catch (Exception ex) {
      // Fire-and-forget: log and swallow. A publish failure must never roll back
      // the terminal-state write, fail the instance, or break the RUN_STEP chain.
      System.debug(
        LoggingLevel.WARN,
        'Workflow_Lifecycle__e publish failed (suppressed): ' + ex.getMessage()
      );
    }
  }

  private static List<Workflow_Lifecycle__e> buildEvents(
    List<Workflow_Instance__c> instances
  ) {
    List<Workflow_Lifecycle__e> events = new List<Workflow_Lifecycle__e>();
    for (Workflow_Instance__c instance : instances) {
      if (instance == null || instance.Id == null) {
        continue;
      }
      String status = instance.Status__c;
      if (!EMITTING_TERMINAL_STATUSES.contains(status)) {
        continue;
      }
      if (publishedInstanceIds.contains(instance.Id)) {
        continue;
      }
      publishedInstanceIds.add(instance.Id);

      Boolean isSuccess = (status == 'Completed');
      events.add(
        new Workflow_Lifecycle__e(
          Workflow_Instance_Id__c = instance.Id,
          Correlation_Key__c = instance.Correlation_Key__c,
          Workflow_Name__c = instance.Workflow_Name__c,
          Status__c = status,
          Is_Success__c = isSuccess,
          Failure_Detail__c = isSuccess
            ? null
            : truncate(instance.Error_Message__c, FAILURE_DETAIL_MAX_LENGTH)
        )
      );
    }
    return events;
  }

  private static String truncate(String value, Integer maxLength) {
    if (value == null) {
      return null;
    }
    return value.length() > maxLength ? value.substring(0, maxLength) : value;
  }
}
