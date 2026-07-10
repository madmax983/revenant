/**
 * Unit tests for WorkflowOutboundEventPublisher (issue #64).
 *
 * The publisher is the single choke point through which a step's buffered
 * outbound domain events are handed to EventBus.publish, coupled to the step's
 * COMPLETE/SPLIT transition commit. These tests prove the mechanism in
 * isolation: it publishes what it is given, is a no-op for empty/null input,
 * guards the DML budget, and never lets a publish failure escape (so it can
 * never roll back the durable Completed record that anchors effectively-once).
 *
 * Platform events are not SOQL-queryable, so assertions read the @TestVisible
 * publishedEvents capture, mirroring WorkflowLifecyclePublisherTest. A
 * Workflow_Lifecycle__e instance stands in for an author-owned __e here — the
 * publisher treats every SObject event generically.
 */
@IsTest
private class WorkflowOutboundEventPublisherTest {
  private static List<SObject> sampleEvents(Integer count) {
    List<SObject> events = new List<SObject>();
    for (Integer i = 0; i < count; i++) {
      events.add(
        new Workflow_Lifecycle__e(
          Workflow_Instance_Id__c = 'a00000000000000AAA',
          Status__c = 'Completed'
        )
      );
    }
    return events;
  }

  @IsTest
  static void publishesEveryProvidedEvent() {
    WorkflowOutboundEventPublisher.publishedEvents.clear();

    Test.startTest();
    WorkflowOutboundEventPublisher.publish(sampleEvents(3));
    Test.stopTest();

    System.assertEquals(
      3,
      WorkflowOutboundEventPublisher.publishedEvents.size(),
      'Every provided event must be published exactly once'
    );
  }

  @IsTest
  static void nullAndEmptyAreNoOps() {
    WorkflowOutboundEventPublisher.publishedEvents.clear();

    Test.startTest();
    WorkflowOutboundEventPublisher.publish(null);
    WorkflowOutboundEventPublisher.publish(new List<SObject>());
    Test.stopTest();

    System.assertEquals(
      0,
      WorkflowOutboundEventPublisher.publishedEvents.size(),
      'Null/empty input must publish nothing'
    );
  }

  @IsTest
  static void publishFailureIsSwallowed() {
    WorkflowOutboundEventPublisher.publishedEvents.clear();
    WorkflowOutboundEventPublisher.throwTestException = true;

    Test.startTest();
    try {
      WorkflowOutboundEventPublisher.publish(sampleEvents(1));
    } catch (Exception e) {
      System.assert(
        false,
        'A publish failure must be swallowed so it never rolls back the ' +
          'Completed record, but it threw: ' +
          e.getMessage()
      );
    } finally {
      WorkflowOutboundEventPublisher.throwTestException = false;
    }
    Test.stopTest();
  }

  @IsTest
  static void dmlBudgetGuardSkipsPublish() {
    WorkflowOutboundEventPublisher.publishedEvents.clear();
    WorkflowOutboundEventPublisher.forceDmlBudgetExhausted = true;

    Test.startTest();
    try {
      WorkflowOutboundEventPublisher.publish(sampleEvents(2));
    } finally {
      WorkflowOutboundEventPublisher.forceDmlBudgetExhausted = false;
    }
    Test.stopTest();

    System.assertEquals(
      0,
      WorkflowOutboundEventPublisher.publishedEvents.size(),
      'When the DML budget is exhausted the publish must be skipped, never ' +
      'spend the transaction last statement and risk rolling back the commit'
    );
  }
}
