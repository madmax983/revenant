/**
 * Publishes a step's buffered outbound domain Platform Events, coupled to the
 * step's COMPLETE/SPLIT transition commit (issue #64).
 *
 * This is the producer-side half of effectively-once emit. The engine calls it
 * from handleStepResult in the SAME transaction that writes the append-only
 * Completed `Workflow_Step_Execution__c` record (the dedup anchor), so:
 *  - a rollback / retry / yield / suspend before that commit publishes nothing;
 *  - a step already durably Completed never re-executes, so it never re-emits.
 *
 * Design contract (mirrors WorkflowLifecyclePublisher, issue #14):
 *  - Authors own the __e type; the engine imposes no envelope and adds no
 *    required fields. The emitted __e MUST use publishBehavior=PublishAfterCommit
 *    so a rolled-back/retried/yielded transition produces no event at all — that
 *    metadata is what makes the publish commit-coupled. A `Publish Immediately`
 *    event would deliver at the publish call regardless of commit, so a later
 *    rollback (and the re-driven step's re-emit) could double-fire it, voiding
 *    the effectively-once guarantee. The engine cannot enforce this at runtime:
 *    Apex's Schema.describe does not expose an SObject's publish behavior (it is
 *    only knowable via the Metadata/Tooling API, which cannot be called mid-
 *    transaction with pending DML), so PublishAfterCommit is a documented
 *    contract here exactly as it is for the engine's own Workflow_Lifecycle__e /
 *    Workflow_Event__e. With PublishAfterCommit the publish ordering within the
 *    transaction is moot (nothing is delivered unless the transaction commits);
 *    the SPLIT publish is additionally placed after the fan-out DML so it cannot
 *    starve that DML's governor budget.
 *  - Fire-and-forget: a failed publish is logged and swallowed, never thrown, so
 *    it can never roll back the terminal/Completed write or break the RUN_STEP
 *    Queueable chain. (A genuinely undeliverable event is the platform's
 *    at-least-once delivery concern, not the producer's.)
 *  - Never spends the transaction's last DML statement/rows: EventBus.publish
 *    consumes a DML statement AND one DML row per event, and over budget it
 *    throws an uncatchable LimitException that would roll back the commit —
 *    defeating the guarantee. The budget guard drops the best-effort publish
 *    instead.
 *  - Delivery to subscribers stays at-least-once; the guarantee is
 *    effectively-once *publication* at the producer.
 */
public inherited sharing class WorkflowOutboundEventPublisher {
  // Captures the events handed to EventBus.publish for test assertions, since
  // platform events cannot be queried via SOQL. Populated in test context only.
  @TestVisible
  private static List<SObject> publishedEvents = new List<SObject>();

  // When true (test context only), forces the publish path to simulate an
  // EventBus failure so the fire-and-forget isolation can be proven.
  @TestVisible
  private static Boolean throwTestException = false;

  // When true (test context only), simulates an exhausted DML budget so the
  // limit-guard skip path can be proven without burning real limits.
  @TestVisible
  private static Boolean forceDmlBudgetExhausted = false;

  // Headroom the guard keeps free, on top of the publish's own cost, for the
  // engine's REQUIRED transition DML that runs AFTER this publish in the same
  // transaction (the COMPLETE/SPLIT/compensation paths still update the
  // instance, insert the next-step / parallel-branch execution rows, and
  // publish the orchestrator hand-off events). Unlike the terminal
  // Workflow_Lifecycle__e publish — which is the last DML in its transaction and
  // so needs no reserve — letting an emit consume the penultimate statement/rows
  // here would make that later durable DML trip the governor and roll back the
  // very Completed/SPLIT commit this publish is meant to ride. Being
  // fire-and-forget, dropping the emit near the limit is the correct
  // conservative choice. Sized for the handful of writes plus a small parallel
  // fan-out; extreme fan-out at the very edge of the limit may still drop emits
  // rather than risk the commit.
  @TestVisible
  private static Integer dmlStatementReserve = 10;
  @TestVisible
  private static Integer dmlRowReserve = 20;

  /**
   * @description Publishes the given outbound events. Safe to call with null/empty
   * (no-op). Any failure is logged and swallowed so it cannot disrupt the workflow
   * transaction.
   * @param events The buffered outbound Platform Events to publish, or null/empty.
   */
  public static void publish(List<SObject> events) {
    if (events == null || events.isEmpty()) {
      return;
    }

    try {
      if (wouldExceedDmlBudget(events.size())) {
        return;
      }
      dispatch(events);
    } catch (Exception ignored) {
      // Fire-and-forget: log and swallow. A publish failure must never roll back
      // the Completed write, fail the instance, or break the RUN_STEP chain.
    }
  }

  /**
   * @description True when publishing eventCount events would spend the
   * transaction's last DML statement or DML rows. EventBus.publish consumes a DML
   * statement AND one DML row per event; over budget it throws an uncatchable
   * System.LimitException that would roll back the Completed write, so the
   * best-effort publish is dropped instead.
   * @param eventCount The number of events that would be published.
   * @return True if publishing would breach the reserved DML statement/row budget.
   */
  private static Boolean wouldExceedDmlBudget(Integer eventCount) {
    return forceDmlBudgetExhausted ||
      Limits.getDmlStatements() + 1 + dmlStatementReserve >
      Limits.getLimitDmlStatements() ||
      Limits.getDmlRows() + eventCount + dmlRowReserve >
      Limits.getLimitDmlRows();
  }

  /**
   * @description Publishes the events to the event bus, capturing them for test
   * assertions in test context and honoring the injected failure hook.
   * @param events The outbound Platform Events to hand to EventBus.publish.
   */
  private static void dispatch(List<SObject> events) {
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
}
