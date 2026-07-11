@IsTest
public class WorkflowEngineTest {
  // Shared workflow/step fixtures referenced by string across the test suite.
  public class HappyWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{
        'WorkflowEngineTest.HappyStep1',
        'WorkflowEngineTest.HappyStep2'
      };
    }
    public String getInitialStep() {
      return 'WorkflowEngineTest.HappyStep1';
    }
    public String getNextStep(String currentStepName, StepResult stepResult) {
      if (currentStepName == 'WorkflowEngineTest.HappyStep1') {
        return 'WorkflowEngineTest.HappyStep2';
      }
      return null;
    }
  }

  public class HappyStep1 implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      return StepResult.complete('WorkflowEngineTest.HappyStep2', 'Output1');
    }
  }

  public class HappyStep2 implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      String input = (String) JSON.deserialize(
        ctx.previousStepOutput,
        String.class
      );
      return StepResult.complete(null, input + '_Output2');
    }
  }

  public class SuspendingWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{
        'WorkflowEngineTest.SuspendingStep',
        'WorkflowEngineTest.AfterSuspendStep'
      };
    }
    public String getInitialStep() {
      return 'WorkflowEngineTest.SuspendingStep';
    }
    public String getNextStep(String currentStepName, StepResult stepResult) {
      if (currentStepName == 'WorkflowEngineTest.SuspendingStep') {
        return 'WorkflowEngineTest.AfterSuspendStep';
      }
      return null;
    }
  }

  public class SuspendingStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      if (ctx.stepStateJson != null) {
        return StepResult.complete(
          'WorkflowEngineTest.AfterSuspendStep',
          ctx.stepStateJson
        );
      }
      return StepResult.suspend();
    }
  }

  public class AfterSuspendStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      String payload = (String) JSON.deserialize(
        ctx.previousStepOutput,
        String.class
      );
      return StepResult.complete(null, 'Resumed_' + payload);
    }
  }

  public class TimeoutStep implements WorkflowStep, TimeoutConfigurable {
    public Integer getTimeoutSeconds() {
      return 60;
    }
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, 'TimeoutComplete');
    }
  }

  public class CompensatableHappyStep implements CompensatableStep {
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, 'Success');
    }
    public StepResult compensate(StepContext ctx) {
      return StepResult.complete(null, 'Compensated');
    }
  }

  public class NonCompensatableStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, 'Success');
    }
  }

  public class TimedSuspendWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{
        'WorkflowEngineTest.TimedSuspendStep',
        'WorkflowEngineTest.TimeoutFallbackStep',
        'WorkflowEngineTest.AfterTimedSignalStep'
      };
    }
    public String getInitialStep() {
      return 'WorkflowEngineTest.TimedSuspendStep';
    }
    public String getNextStep(String currentStepName, StepResult stepResult) {
      if (currentStepName == 'WorkflowEngineTest.TimedSuspendStep') {
        return 'WorkflowEngineTest.AfterTimedSignalStep';
      }
      return null;
    }
  }

  public class TimedSuspendStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      List<Workflow_Signal__c> signals = [
        SELECT Id, Signal_Name__c, Payload__c
        FROM Workflow_Signal__c
        WHERE
          Workflow_Instance__c = :ctx.workflowInstanceId
          AND Signal_Name__c = 'Resume'
          AND Status__c = 'Received'
        LIMIT 1
      ];
      if (!signals.isEmpty()) {
        Workflow_Signal__c sig = signals[0];
        sig.Status__c = 'Consumed';
        update sig;
        return StepResult.complete(
          'WorkflowEngineTest.AfterTimedSignalStep',
          'signaled'
        );
      }
      return StepResult.suspend(60, 'WorkflowEngineTest.TimeoutFallbackStep');
    }
  }

  public class TimeoutFallbackStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      WorkflowEngineMocksATest.capturedIsTimeoutResume = ctx.isTimeoutResume();
      return StepResult.complete(null, 'timedout');
    }
  }

  public class AfterTimedSignalStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, 'signaled');
    }
  }
}
