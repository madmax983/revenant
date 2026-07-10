/**
 * Unit tests for WorkflowLifecyclePublisher — the fire-and-forget outbound
 * Workflow_Lifecycle__e publisher. Platform events cannot be queried via SOQL,
 * so assertions read the @TestVisible WorkflowLifecyclePublisher.publishedEvents
 * capture of what was handed to EventBus.publish.
 */
@IsTest
private class WorkflowLifecyclePublisherTest {
  private static Workflow_Instance__c makeInstance(
    String status,
    String errorMessage
  ) {
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
      Correlation_Key__c = 'LifecycleKey_' + status,
      Status__c = 'Running'
    );
    insert inst;
    // Transition to the target status post-insert so the terminal-tracking
    // trigger behaves like a real engine transition.
    inst.Status__c = status;
    inst.Error_Message__c = errorMessage;
    update inst;
    return [
      SELECT
        Id,
        Status__c,
        Workflow_Name__c,
        Correlation_Key__c,
        Error_Message__c,
        Terminal_At__c
      FROM Workflow_Instance__c
      WHERE Id = :inst.Id
    ];
  }

  @IsTest
  static void publishesEventForCompleted() {
    Workflow_Instance__c inst = makeInstance('Completed', null);

    Test.startTest();
    WorkflowLifecyclePublisher.publish(inst);
    Test.stopTest();

    System.assertEquals(
      1,
      WorkflowLifecyclePublisher.publishedEvents.size(),
      'Completed transition should publish exactly one lifecycle event'
    );
    Workflow_Lifecycle__e evt = WorkflowLifecyclePublisher.publishedEvents[0];
    System.assertEquals(inst.Id, evt.Workflow_Instance_Id__c);
    System.assertEquals('Completed', evt.Status__c);
    System.assertEquals(
      true,
      evt.Is_Success__c,
      'Completed is the only success'
    );
    System.assertEquals(
      'WorkflowEngineTest.HappyWorkflow',
      evt.Workflow_Name__c
    );
    System.assertEquals(inst.Correlation_Key__c, evt.Correlation_Key__c);
    System.assertEquals(
      null,
      evt.Failure_Detail__c,
      'Completed carries no failure detail'
    );
  }

  @IsTest
  static void publishesFailedWithFailureDetail() {
    Workflow_Instance__c inst = makeInstance('Failed', 'Boom at step X');

    Test.startTest();
    WorkflowLifecyclePublisher.publish(inst);
    Test.stopTest();

    System.assertEquals(1, WorkflowLifecyclePublisher.publishedEvents.size());
    Workflow_Lifecycle__e evt = WorkflowLifecyclePublisher.publishedEvents[0];
    System.assertEquals('Failed', evt.Status__c);
    System.assertEquals(false, evt.Is_Success__c);
    System.assertEquals('Boom at step X', evt.Failure_Detail__c);
  }

  @IsTest
  static void rootKeyFallsBackToCorrelationKeyWhenAbsent() {
    // makeInstance does not query Root_Correlation_Key__c, so it is absent from the
    // populated-field map — mirroring an in-flight instance created before the
    // field existed. The event must still carry a usable root key.
    Workflow_Instance__c inst = makeInstance('Completed', null);

    Test.startTest();
    WorkflowLifecyclePublisher.publish(inst);
    Test.stopTest();

    System.assertEquals(1, WorkflowLifecyclePublisher.publishedEvents.size());
    Workflow_Lifecycle__e evt = WorkflowLifecyclePublisher.publishedEvents[0];
    System.assertEquals(
      inst.Correlation_Key__c,
      evt.Root_Correlation_Key__c,
      'Root key falls back to the correlation key when not populated'
    );
    System.assertNotEquals(
      null,
      evt.Terminal_At__c,
      'The event always carries a terminal transition timestamp'
    );
  }

  @IsTest
  static void publishesCompensatedAndCancelled() {
    Test.startTest();
    WorkflowLifecyclePublisher.publish(
      makeInstance('Compensated', 'rolled back')
    );
    WorkflowLifecyclePublisher.publish(
      makeInstance('Cancelled', 'cancelled by user')
    );
    Test.stopTest();

    System.assertEquals(
      2,
      WorkflowLifecyclePublisher.publishedEvents.size(),
      'Compensated and Cancelled are both emitting terminal states'
    );
    for (
      Workflow_Lifecycle__e evt : WorkflowLifecyclePublisher.publishedEvents
    ) {
      System.assertEquals(false, evt.Is_Success__c);
      System.assertNotEquals(null, evt.Failure_Detail__c);
    }
  }

  @IsTest
  static void skipsContinuedAsNew() {
    Workflow_Instance__c inst = makeInstance('ContinuedAsNew', null);

    Test.startTest();
    WorkflowLifecyclePublisher.publish(inst);
    Test.stopTest();

    System.assertEquals(
      0,
      WorkflowLifecyclePublisher.publishedEvents.size(),
      'ContinuedAsNew is a hand-off, not a terminal outcome — no event'
    );
  }

  @IsTest
  static void skipsNonTerminalStatuses() {
    Workflow_Instance__c suspended = makeInstance('Suspended', null);
    Workflow_Instance__c running = makeInstance('Running', null);

    Test.startTest();
    WorkflowLifecyclePublisher.publish(suspended);
    WorkflowLifecyclePublisher.publish(running);
    Test.stopTest();

    System.assertEquals(
      0,
      WorkflowLifecyclePublisher.publishedEvents.size(),
      'Non-terminal statuses never publish a lifecycle event'
    );
  }

  @IsTest
  static void respectsConfigToggle() {
    WorkflowEngine.publishLifecycleEvents = false;
    Workflow_Instance__c inst = makeInstance('Completed', null);

    Test.startTest();
    WorkflowLifecyclePublisher.publish(inst);
    Test.stopTest();

    System.assertEquals(
      0,
      WorkflowLifecyclePublisher.publishedEvents.size(),
      'Disabling the toggle suppresses lifecycle events'
    );
  }

  @IsTest
  static void dedupesWithinTransaction() {
    Workflow_Instance__c inst = makeInstance('Completed', null);

    Test.startTest();
    WorkflowLifecyclePublisher.publish(inst);
    WorkflowLifecyclePublisher.publish(inst);
    WorkflowLifecyclePublisher.publish(inst);
    Test.stopTest();

    System.assertEquals(
      1,
      WorkflowLifecyclePublisher.publishedEvents.size(),
      'Repeated publish calls for the same instance emit only one event per transaction'
    );
  }

  @IsTest
  static void failureIsolationDoesNotThrow() {
    WorkflowLifecyclePublisher.throwTestException = true;
    Workflow_Instance__c inst = makeInstance('Completed', null);

    Test.startTest();
    // Must NOT throw — a publish failure is logged and swallowed so it can never
    // roll back the terminal-state write or break the RUN_STEP chain.
    WorkflowLifecyclePublisher.publish(inst);
    Test.stopTest();

    System.assertEquals(
      0,
      WorkflowLifecyclePublisher.publishedEvents.size(),
      'A simulated EventBus failure publishes nothing but never propagates'
    );
    // The terminal-state write is untouched by the publish failure.
    Workflow_Instance__c reloaded = [
      SELECT Status__c
      FROM Workflow_Instance__c
      WHERE Id = :inst.Id
    ];
    System.assertEquals('Completed', reloaded.Status__c);
  }

  @IsTest
  static void truncatesOverlongFailureDetail() {
    String longMsg = 'E'.repeat(400);
    Workflow_Instance__c inst = makeInstance('Failed', null);
    // Bypass the 255-char field cap on Error_Message__c by injecting in memory.
    inst.Error_Message__c = longMsg;

    Test.startTest();
    WorkflowLifecyclePublisher.publish(inst);
    Test.stopTest();

    System.assertEquals(1, WorkflowLifecyclePublisher.publishedEvents.size());
    System.assertEquals(
      255,
      WorkflowLifecyclePublisher.publishedEvents[0].Failure_Detail__c.length(),
      'Failure detail is truncated to the event field length'
    );
  }

  @IsTest
  static void bulkPublishOnlyEmitsTerminalNonContinue() {
    List<Workflow_Instance__c> mixed = new List<Workflow_Instance__c>{
      makeInstance('Completed', null),
      makeInstance('ContinuedAsNew', null),
      makeInstance('Failed', 'err'),
      makeInstance('Suspended', null)
    };

    Test.startTest();
    WorkflowLifecyclePublisher.publish(mixed);
    Test.stopTest();

    System.assertEquals(
      2,
      WorkflowLifecyclePublisher.publishedEvents.size(),
      'Only Completed and Failed in the batch emit; ContinuedAsNew and Suspended are skipped'
    );
  }

  @IsTest
  static void nullAndEmptyInputsAreSafe() {
    Test.startTest();
    WorkflowLifecyclePublisher.publish((Workflow_Instance__c) null);
    WorkflowLifecyclePublisher.publish((List<Workflow_Instance__c>) null);
    WorkflowLifecyclePublisher.publish(new List<Workflow_Instance__c>());
    Test.stopTest();

    System.assertEquals(0, WorkflowLifecyclePublisher.publishedEvents.size());
  }

  @IsTest
  static void skipsPublishWhenDmlBudgetExhausted() {
    // EventBus.publish consumes a DML statement; over budget it throws an
    // uncatchable LimitException that would roll back the terminal write. The
    // guard must drop the event instead — never attempt the publish.
    WorkflowLifecyclePublisher.forceDmlBudgetExhausted = true;
    Workflow_Instance__c inst = makeInstance('Completed', null);

    Test.startTest();
    WorkflowLifecyclePublisher.publish(inst);
    Test.stopTest();

    System.assertEquals(
      0,
      WorkflowLifecyclePublisher.publishedEvents.size(),
      'When the DML budget is exhausted the event is dropped, not published'
    );
    // The terminal-state write is untouched (no rollback).
    System.assertEquals(
      'Completed',
      [SELECT Status__c FROM Workflow_Instance__c WHERE Id = :inst.Id].Status__c
    );
  }

  @IsTest
  static void underQueriedInstanceFieldDegradesGracefully() {
    // A caller that passes a terminal instance missing an optional field (here
    // Correlation_Key__c) must never throw or roll back the transaction. Reading
    // fields via getPopulatedFieldsAsMap yields null for the unqueried field, so
    // the event still publishes (with a null key) rather than failing.
    Workflow_Instance__c full = makeInstance('Completed', null);
    Workflow_Instance__c partial = [
      SELECT Id, Status__c, Workflow_Name__c
      FROM Workflow_Instance__c
      WHERE Id = :full.Id
    ];

    Test.startTest();
    WorkflowLifecyclePublisher.publish(partial); // Correlation_Key__c not queried
    Test.stopTest();

    System.assertEquals(
      1,
      WorkflowLifecyclePublisher.publishedEvents.size(),
      'An under-queried instance still publishes; it never throws'
    );
    Workflow_Lifecycle__e evt = WorkflowLifecyclePublisher.publishedEvents[0];
    System.assertEquals(
      null,
      evt.Correlation_Key__c,
      'The unqueried optional field degrades to null instead of throwing'
    );
    System.assertEquals(
      'WorkflowEngineTest.HappyWorkflow',
      evt.Workflow_Name__c
    );
    System.assertEquals(
      'Completed',
      [SELECT Status__c FROM Workflow_Instance__c WHERE Id = :full.Id]
      .Status__c,
      'The terminal-state write is preserved'
    );
  }
}
