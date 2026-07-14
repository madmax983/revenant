/**
 * Unit tests for the public outbound-emit API surface (issue #64):
 *   - StepContext.emit(SObject) / StepContext.getPendingEmits()
 *
 * These cover the author-facing contract in isolation (no engine drive): emit()
 * buffers events in arrival order, the buffer never returns null so the engine
 * can iterate it unconditionally, and a COMPLETE result built alongside the
 * buffered events exposes its transition data through directive(). The former
 * StepResult.complete(next, output, List<SObject> events) overload was removed
 * in the analyzer decomposition; buffering through ctx.events().emit(...) is the single
 * supported path, and the engine merges the buffer with any result events.
 */
@IsTest
private class StepEmitApiTest {
  @IsTest
  static void emitBuffersEventsAlongsideCompleteResult() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      StepContext ctx = new StepContext.Builder()
        .instanceId(null)
        .workflowName('W')
        .stepName('S')
        .inputJson(null)
        .previousStepOutput(null)
        .stepStateJson(null)
        .workflowInputJson(null)
        .build();

      ctx.events().emit(new Workflow_Lifecycle__e(Status__c = 'Completed'));
      ctx.events().emit(new Workflow_Lifecycle__e(Status__c = 'Completed'));

      StepResult r = StepResult.complete('NextStep', 'out');

      System.assertEquals(StepResult.ActionType.COMPLETE, r.directive().action);
      System.assertEquals('NextStep', r.directive().nextStepName);
      System.assertEquals(
        '"out"',
        r.directive().outputJson,
        'output is JSON-serialized'
      );
      System.assertEquals(
        2,
        ctx.events().getPendingEmits().size(),
        'Both events must ride the buffered emits the engine publishes'
      );
    }
  }

  @IsTest
  static void completeCarriesNoOutboundEventsByDefault() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      StepResult r = StepResult.complete('NextStep', 'out');
      System.assertEquals(StepResult.ActionType.COMPLETE, r.directive().action);
      System.assertEquals(
        null,
        r.directive().outboundEvents,
        'A plain complete() carries no result events (engine treats it as no emits)'
      );
    }
  }

  @IsTest
  static void emitBuffersEventsInOrder() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      StepContext ctx = new StepContext.Builder()
        .instanceId(null)
        .workflowName('W')
        .stepName('S')
        .inputJson(null)
        .previousStepOutput(null)
        .stepStateJson(null)
        .workflowInputJson(null)
        .build();

      System.assertNotEquals(
        null,
        ctx.events().getPendingEmits(),
        'getPendingEmits must never return null'
      );
      System.assertEquals(0, ctx.events().getPendingEmits().size());

      Workflow_Lifecycle__e e1 = new Workflow_Lifecycle__e(
        Status__c = 'Completed'
      );
      Workflow_Lifecycle__e e2 = new Workflow_Lifecycle__e(
        Status__c = 'Failed'
      );
      ctx.events().emit(e1);
      ctx.events().emit(e2);
      ctx.events().emit(null); // null is ignored, never buffered

      List<SObject> buffered = ctx.events().getPendingEmits();
      System.assertEquals(2, buffered.size(), 'null emit must be ignored');
      System.assertEquals(e1, buffered[0], 'arrival order preserved');
      System.assertEquals(e2, buffered[1], 'arrival order preserved');
    }
  }
}
