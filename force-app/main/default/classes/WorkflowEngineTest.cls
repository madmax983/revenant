@IsTest
public class WorkflowEngineTest {
  // Shared workflow/step fixtures referenced by string across the test suite.
  /**
   * @description Two-step happy-path workflow fixture used to exercise normal
   * step-to-step completion.
   */
  public class HappyWorkflow implements WorkflowDefinition {
    /**
     * @description Returns the ordered fixture step names.
     * @return The two happy-path step names.
     */
    public List<String> getSteps() {
      return new List<String>{
        'WorkflowEngineTest.HappyStep1',
        'WorkflowEngineTest.HappyStep2'
      };
    }
    /**
     * @description Returns the step the fixture begins with.
     * @return The first happy-path step name.
     */
    public String getInitialStep() {
      return 'WorkflowEngineTest.HappyStep1';
    }
    /**
     * @description Advances from the first happy step to the second, then ends.
     * @param currentStepName The name of the step that just completed.
     * @param stepResult The result of the completed step.
     * @return The next step name, or null once the second step completes.
     */
    public String getNextStep(String currentStepName, StepResult stepResult) {
      if (currentStepName == 'WorkflowEngineTest.HappyStep1') {
        return 'WorkflowEngineTest.HappyStep2';
      }
      return null;
    }
  }

  /**
   * @description First happy-path step; emits a fixed output for the next step.
   */
  public class HappyStep1 implements WorkflowStep {
    /**
     * @description Completes immediately with a fixed output payload.
     * @param ctx The durable step context for this execution.
     * @return A COMPLETE result carrying the first step's output.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.complete('WorkflowEngineTest.HappyStep2', 'Output1');
    }
  }

  /**
   * @description Second happy-path step; appends to the previous step's output.
   */
  public class HappyStep2 implements WorkflowStep {
    /**
     * @description Reads the previous step's output and completes with an augmented value.
     * @param ctx The durable step context supplying the previous step output.
     * @return A COMPLETE result carrying the combined output.
     */
    public StepResult execute(StepContext ctx) {
      String input = (String) JSON.deserialize(
        ctx.previousStepOutput,
        String.class
      );
      return StepResult.complete(null, input + '_Output2');
    }
  }

  /**
   * @description Workflow fixture whose first step suspends and later resumes,
   * exercising the suspend/resume path.
   */
  public class SuspendingWorkflow implements WorkflowDefinition {
    /**
     * @description Returns the ordered fixture step names.
     * @return The suspending and after-suspend step names.
     */
    public List<String> getSteps() {
      return new List<String>{
        'WorkflowEngineTest.SuspendingStep',
        'WorkflowEngineTest.AfterSuspendStep'
      };
    }
    /**
     * @description Returns the step the fixture begins with.
     * @return The suspending step name.
     */
    public String getInitialStep() {
      return 'WorkflowEngineTest.SuspendingStep';
    }
    /**
     * @description Advances from the suspending step to the after-suspend step, then ends.
     * @param currentStepName The name of the step that just completed.
     * @param stepResult The result of the completed step.
     * @return The next step name, or null once the after-suspend step completes.
     */
    public String getNextStep(String currentStepName, StepResult stepResult) {
      if (currentStepName == 'WorkflowEngineTest.SuspendingStep') {
        return 'WorkflowEngineTest.AfterSuspendStep';
      }
      return null;
    }
  }

  /**
   * @description Step fixture that suspends on first run and completes on resume.
   */
  public class SuspendingStep implements WorkflowStep {
    /**
     * @description Suspends when no resume state is present, otherwise completes
     * carrying that state forward.
     * @param ctx The durable step context; a non-null step state marks the resume run.
     * @return SUSPEND on first run, or COMPLETE once resumed with state.
     */
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

  /**
   * @description Step fixture that runs after a suspend/resume and echoes the payload.
   */
  public class AfterSuspendStep implements WorkflowStep {
    /**
     * @description Completes with the resume payload prefixed to confirm resumption.
     * @param ctx The durable step context supplying the previous step output.
     * @return A COMPLETE result carrying the resumed payload.
     */
    public StepResult execute(StepContext ctx) {
      String payload = (String) JSON.deserialize(
        ctx.previousStepOutput,
        String.class
      );
      return StepResult.complete(null, 'Resumed_' + payload);
    }
  }

  /**
   * @description Timeout-configurable step fixture used to exercise step timeouts.
   */
  public class TimeoutStep implements WorkflowStep, TimeoutConfigurable {
    /**
     * @description Declares a fixed step timeout for the fixture.
     * @return The timeout in seconds.
     */
    public Integer getTimeoutSeconds() {
      return 60;
    }
    /**
     * @description Completes immediately with a fixed output.
     * @param ctx The durable step context for this execution.
     * @return A COMPLETE result.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, 'TimeoutComplete');
    }
  }

  /**
   * @description Compensatable step fixture whose execute and compensate both succeed.
   */
  public class CompensatableHappyStep implements CompensatableStep {
    /**
     * @description Completes the forward action successfully.
     * @param ctx The durable step context for this execution.
     * @return A COMPLETE result marking success.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, 'Success');
    }
    /**
     * @description Completes the compensating action successfully.
     * @param ctx The durable step context for this execution.
     * @return A COMPLETE result marking compensation.
     */
    public StepResult compensate(StepContext ctx) {
      return StepResult.complete(null, 'Compensated');
    }
  }

  /**
   * @description Plain (non-compensatable) step fixture that always succeeds.
   */
  public class NonCompensatableStep implements WorkflowStep {
    /**
     * @description Completes the forward action successfully.
     * @param ctx The durable step context for this execution.
     * @return A COMPLETE result marking success.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, 'Success');
    }
  }

  /**
   * @description Workflow fixture whose first step suspends with a timeout fallback,
   * exercising timed suspend / signal-versus-timeout resume.
   */
  public class TimedSuspendWorkflow implements WorkflowDefinition {
    /**
     * @description Returns the ordered fixture step names.
     * @return The timed-suspend, timeout-fallback, and after-signal step names.
     */
    public List<String> getSteps() {
      return new List<String>{
        'WorkflowEngineTest.TimedSuspendStep',
        'WorkflowEngineTest.TimeoutFallbackStep',
        'WorkflowEngineTest.AfterTimedSignalStep'
      };
    }
    /**
     * @description Returns the step the fixture begins with.
     * @return The timed-suspend step name.
     */
    public String getInitialStep() {
      return 'WorkflowEngineTest.TimedSuspendStep';
    }
    /**
     * @description Advances from the timed-suspend step to the after-signal step on
     * the signal path; the timeout fallback path is routed by the step result.
     * @param currentStepName The name of the step that just completed.
     * @param stepResult The result of the completed step.
     * @return The next step name, or null to end the workflow.
     */
    public String getNextStep(String currentStepName, StepResult stepResult) {
      if (currentStepName == 'WorkflowEngineTest.TimedSuspendStep') {
        return 'WorkflowEngineTest.AfterTimedSignalStep';
      }
      return null;
    }
  }

  /**
   * @description Step fixture that suspends with a timeout fallback and resumes when
   * a Resume signal is consumed.
   */
  public class TimedSuspendStep implements WorkflowStep {
    /**
     * @description Completes via the signal branch if a Resume signal is present,
     * otherwise suspends with a timeout that routes to the fallback step.
     * @param ctx The durable step context for this execution.
     * @return COMPLETE when signaled, or a timed SUSPEND naming the timeout fallback step.
     */
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

  /**
   * @description Fallback step fixture reached when the timed suspend times out;
   * captures whether the resume was a timeout resume.
   */
  public class TimeoutFallbackStep implements WorkflowStep {
    /**
     * @description Records the timeout-resume flag observed on this resume and completes.
     * @param ctx The durable step context exposing the timeout-resume signal.
     * @return A COMPLETE result marking the timed-out branch.
     */
    public StepResult execute(StepContext ctx) {
      WorkflowEngineMocksATest.capturedIsTimeoutResume = ctx.retry()
        .isTimeoutResume();
      return StepResult.complete(null, 'timedout');
    }
  }

  /**
   * @description Terminal step fixture reached on the signal branch of the timed suspend.
   */
  public class AfterTimedSignalStep implements WorkflowStep {
    /**
     * @description Completes marking the signaled branch.
     * @param ctx The durable step context for this execution.
     * @return A COMPLETE result marking the signaled branch.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, 'signaled');
    }
  }
}
