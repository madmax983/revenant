/**
 * @description Self-perpetuating engine watchdog workflow: it heartbeats the
 * timeout/sleep sweeper, sleeps for the configured interval, then continues-as-new
 * to run forever without accumulating history.
 */
public inherited sharing class WatchdogWorkflow implements WorkflowDefinition {
  /**
   * @description Returns the ordered step names composing the watchdog DAG.
   * @return The heartbeat, sleep, and continue step names.
   */
  public List<String> getSteps() {
    return new List<String>{
      'WatchdogWorkflow.WatchdogHeartbeatStep',
      'WatchdogWorkflow.WatchdogSleepStep',
      'WatchdogWorkflow.WatchdogContinueStep'
    };
  }

  /**
   * @description Returns the step the watchdog run begins with.
   * @return The heartbeat step name.
   */
  public String getInitialStep() {
    return 'WatchdogWorkflow.WatchdogHeartbeatStep';
  }

  /**
   * @description Advances the linear heartbeat then sleep then continue chain.
   * @param currentStepName The name of the step that just completed.
   * @param result The result of the completed step.
   * @return The next step name, or null once the continue step ends the run.
   */
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
    /**
     * @description Drives one watchdog heartbeat, sweeping due timeouts and sleeps.
     * @param ctx The durable step context for this execution.
     * @return A COMPLETE result once the heartbeat sweep finishes.
     */
    public StepResult execute(StepContext ctx) {
      WorkflowEngine.processWatchdogHeartbeat();
      return StepResult.complete(null, 'Heartbeat completed');
    }
  }

  /**
   * Sleep step: sleeps for the configured watchdog delay interval.
   */
  public class WatchdogSleepStep implements WorkflowStep {
    /**
     * @description Sleeps for the configured watchdog delay on first run, then
     * completes when re-executed after the sleep wakes it.
     * @param ctx The durable step context; a non-null step state marks the post-sleep resume.
     * @return A SLEEP result on first run, or COMPLETE once the sleep has elapsed.
     */
    public StepResult execute(StepContext ctx) {
      if (ctx.stepStateJson != null) {
        return StepResult.complete(null, 'Sleep completed');
      }
      Integer delaySeconds = WorkflowEngine.watchdogDelayMinutes * 60;
      return StepResult.sleep(delaySeconds).withStepState('slept');
    }
  }

  /**
   * ContinueStep: continues as new to spawn a clean successor run and clear history.
   */
  public class WatchdogContinueStep implements WorkflowStep {
    /**
     * @description Continues-as-new to spawn a fresh successor run and discard the
     * accumulated history, keeping the watchdog alive indefinitely.
     * @param ctx The durable step context for this execution.
     * @return A continue-as-new result that starts the next watchdog cycle.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.continueAsNew(null, null);
    }
  }
}
