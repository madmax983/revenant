/**
 * Unit tests for the public outbound-emit API surface (issue #64):
 *   - StepResult.complete(nextStepName, output, List<SObject> events)
 *   - StepContext.emit(SObject) / StepContext.getPendingEmits()
 *
 * These cover the author-facing contract in isolation (no engine drive): the
 * overload carries events on the result, emit() buffers in arrival order, and
 * the buffer never returns null so the engine can iterate it unconditionally.
 */
@isTest
private class StepEmitApiTest {
  @isTest
  static void completeOverloadCarriesOutboundEvents() {
    List<SObject> events = new List<SObject>{
      new Workflow_Lifecycle__e(Status__c = 'Completed'),
      new Workflow_Lifecycle__e(Status__c = 'Completed')
    };

    StepResult r = StepResult.complete('NextStep', 'out', events);

    System.assertEquals(StepResult.ActionType.COMPLETE, r.action);
    System.assertEquals('NextStep', r.nextStepName);
    System.assertEquals('"out"', r.outputJson, 'output is JSON-serialized');
    System.assertNotEquals(null, r.outboundEvents);
    System.assertEquals(
      2,
      r.outboundEvents.size(),
      'Both events must ride the COMPLETE result'
    );
  }

  @isTest
  static void completeOverloadAcceptsNullEvents() {
    StepResult r = StepResult.complete('NextStep', 'out', null);
    System.assertEquals(StepResult.ActionType.COMPLETE, r.action);
    System.assertEquals(
      null,
      r.outboundEvents,
      'Null events list is preserved as null (engine treats it as no emits)'
    );
  }

  @isTest
  static void emitBuffersEventsInOrder() {
    StepContext ctx = new StepContext(null, 'W', 'S', null, null, null, null);

    System.assertNotEquals(
      null,
      ctx.getPendingEmits(),
      'getPendingEmits must never return null'
    );
    System.assertEquals(0, ctx.getPendingEmits().size());

    Workflow_Lifecycle__e e1 = new Workflow_Lifecycle__e(
      Status__c = 'Completed'
    );
    Workflow_Lifecycle__e e2 = new Workflow_Lifecycle__e(Status__c = 'Failed');
    ctx.emit(e1);
    ctx.emit(e2);
    ctx.emit(null); // null is ignored, never buffered

    List<SObject> buffered = ctx.getPendingEmits();
    System.assertEquals(2, buffered.size(), 'null emit must be ignored');
    System.assertEquals(e1, buffered[0], 'arrival order preserved');
    System.assertEquals(e2, buffered[1], 'arrival order preserved');
  }
}
