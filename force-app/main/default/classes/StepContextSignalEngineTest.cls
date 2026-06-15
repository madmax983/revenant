/**
 * Engine-level coverage for issue #11: the engine surfaces pending signals into
 * StepContext and ties consumption to the step's successful (COMPLETE)
 * transition.
 */
@isTest
public class StepContextSignalEngineTest {
  // --- Re-observation safety (AC4a) ---------------------------------------

  public class ReObserveWorkflow implements WorkflowDefinition {
    public String getInitialStep() {
      return 'StepContextSignalEngineTest.ReObserveStep';
    }
    public String getNextStep(String currentStepName, StepResult stepResult) {
      return null;
    }
  }

  public class ReObserveStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      StepContext.Signal s = ctx.getSignal('Tick');
      if (!s.isPresent()) {
        return StepResult.suspend();
      }
      if (String.isBlank(ctx.stepStateJson)) {
        // Observed the signal but yield (NOT complete): engine must not consume
        // it yet, so the next attempt re-observes the same pending signal.
        return StepResult.yield('{"seen":true}');
      }
      return StepResult.complete(null, 'done:' + s.payload);
    }
  }

  @isTest
  static void testObservedSignalSurvivesYieldUntilComplete() {
    Id instanceId = WorkflowEngine.start(
      'StepContextSignalEngineTest.ReObserveWorkflow',
      'ReObserveKey',
      null
    );

    // Suspends waiting for the signal.
    new WorkflowOrchestrator(instanceId).execute(null);

    WorkflowEngine.signal('ReObserveKey', 'Tick', '{"v":1}');

    // First observed run yields without completing.
    new WorkflowOrchestrator(instanceId).execute(null);
    System.assertEquals(
      1,
      [
        SELECT COUNT()
        FROM Workflow_Signal__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Status__c = 'Received'
      ],
      'A signal observed by a step that yields (not completes) must remain pending'
    );

    // Second run sees state set, completes, and the engine consumes the signal.
    new WorkflowOrchestrator(instanceId).execute(null);

    Workflow_Instance__c inst = [
      SELECT Status__c, Output__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals('Completed', inst.Status__c);
    System.assertEquals('"done:{\\"v\\":1}"', inst.Output__c);
    System.assertEquals(
      0,
      [
        SELECT COUNT()
        FROM Workflow_Signal__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Status__c = 'Received'
      ],
      'Signal must be consumed once the observing step completes'
    );
  }

  // --- Cancel control signals are never surfaced (AC5) --------------------

  public class PlainWaitWorkflow implements WorkflowDefinition {
    public String getInitialStep() {
      return 'StepContextSignalEngineTest.PlainWaitStep';
    }
    public String getNextStep(String currentStepName, StepResult stepResult) {
      return null;
    }
  }

  public class PlainWaitStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      // Asserts the control signal is never visible as a readable payload.
      System.assertEquals(
        0,
        ctx.getSignals('Cancel').size(),
        'Cancel must never be surfaced as a readable signal'
      );
      if (ctx.getSignal('Go').isPresent()) {
        return StepResult.complete(null, 'went');
      }
      return StepResult.suspend();
    }
  }

  @isTest
  static void testCancelSignalIsNotSurfacedAsReadablePayload() {
    Id instanceId = WorkflowEngine.start(
      'StepContextSignalEngineTest.PlainWaitWorkflow',
      'CancelKey',
      null
    );
    new WorkflowOrchestrator(instanceId).execute(null);

    Test.startTest();
    WorkflowEngine.signal('CancelKey', 'Cancel', null);
    Test.stopTest();

    // Cancellation is handled inline by the engine and never persists a
    // Workflow_Signal__c record, so it can never reach StepContext.
    System.assertEquals(
      0,
      [
        SELECT COUNT()
        FROM Workflow_Signal__c
        WHERE Workflow_Instance__c = :instanceId
      ],
      'Cancel control signals must not create readable signal records'
    );

    Workflow_Instance__c inst = [
      SELECT Status__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertNotEquals(
      'Running',
      inst.Status__c,
      'Cancel must still drive cancellation semantics'
    );
  }
}
