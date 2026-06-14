public inherited sharing class WatchdogWorkflow implements WorkflowDefinition {
  public List<String> getSteps() {
    return new List<String>{
      'WatchdogWorkflow.WatchdogHeartbeatStep',
      'WatchdogWorkflow.WatchdogSleepStep',
      'WatchdogWorkflow.WatchdogContinueStep'
    };
  }

  public String getInitialStep() {
    return 'WatchdogWorkflow.WatchdogHeartbeatStep';
  }

  public String getNextStep(String currentStepName, StepResult result) {
    if (currentStepName == 'WatchdogWorkflow.WatchdogHeartbeatStep') {
      return 'WatchdogWorkflow.WatchdogSleepStep';
    }
    if (currentStepName == 'WatchdogWorkflow.WatchdogSleepStep') {
      return 'WatchdogWorkflow.WatchdogContinueStep';
    }
    return null;
  }

  /**
   * Heartbeat step: processes the engine watchdog heartbeat to sweep timeouts/sleeps.
   */
  public class WatchdogHeartbeatStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      WorkflowEngine.processWatchdogHeartbeat();
      return StepResult.complete(null, 'Heartbeat completed');
    }
  }

  /**
   * Sleep step: sleeps for the configured watchdog delay interval.
   */
  public class WatchdogSleepStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      if (ctx.stepStateJson != null) {
        return StepResult.complete(null, 'Sleep completed');
      }
      Integer delaySeconds = WorkflowEngine.watchdogDelayMinutes * 60;
      return StepResult.sleep(delaySeconds, 'slept');
    }
  }

  /**
   * ContinueStep: continues as new to spawn a clean successor run and clear history.
   */
  public class WatchdogContinueStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      return StepResult.continueAsNew(null, null);
    }
  }
}
