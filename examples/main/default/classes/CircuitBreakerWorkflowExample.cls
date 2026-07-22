/**
 * Reference example for the durable circuit breaker (issue #128).
 *
 * Demonstrates a fleet of workflow instances that all call one shared, unhealthy
 * dependency, fast-failing (parking) once the breaker trips Open instead of
 * stampeding the dead dependency, then auto-recovering once the dependency heals:
 *
 *   1. A step opts in by implementing `CircuitBreakerGuarded` and naming the
 *      dependency it calls (`dependencyKey()`). The breaker for that key is shared
 *      across every workflow whose guarded steps name it.
 *   2. While the dependency is down, each attempt returns `StepResult.fail(...)`,
 *      which the engine counts against the breaker's rolling window. Once the
 *      failure threshold is reached the breaker opens.
 *   3. With the breaker Open, later instances are parked at the admission hook
 *      BEFORE `execute()` runs — the dependency is never called, so a down system
 *      is not hammered. The park is a durable suspend that re-checks the breaker
 *      when it wakes.
 *   4. After the open duration elapses the breaker moves to Half-Open (on demand in
 *      `tryAdmit`, or via the watchdog `sweepHalfOpen` for a quiet dependency). A
 *      single trial probe is admitted; if the dependency has healed it succeeds and
 *      the breaker closes, letting the rest of the fleet proceed.
 *
 * Contrast with the other throttles: `RateLimiter` caps call *rate*,
 * `Concurrency_Config__mdt` caps *in-flight instances* per workflow, and
 * `RetryPolicy` backs off a *single* step. The breaker reacts to dependency
 * *health* across the whole fleet. See the ThrottledCalloutWorkflowExample for the
 * rate-limit pattern.
 */
public inherited sharing class CircuitBreakerWorkflowExample {
  /** @description The shared dependency key this example's guarded step protects. */
  public static final String DEPENDENCY_KEY = 'ExternalPaymentsApi';

  /** @description Flips the simulated dependency between healthy and down. */
  public static Boolean dependencyHealthy = false;

  /** @description Counts how many times the dependency was actually invoked. */
  public static Integer callAttempts = 0;

  /**
   * @description Simulated shared dependency. Throws while unhealthy so the guarded
   * step reports a failure; a call only happens when the breaker admits the step.
   */
  public static void invokeDependency() {
    callAttempts++;
    if (!dependencyHealthy) {
      throw new DependencyDownException(DEPENDENCY_KEY + ' is unavailable');
    }
  }

  /**
   * @description Resets the simulated dependency to its down, never-called state so
   * a test starts clean.
   */
  public static void reset() {
    dependencyHealthy = false;
    callAttempts = 0;
  }

  /** @description Raised by the simulated dependency while it is unhealthy. */
  public class DependencyDownException extends Exception {
  }

  /**
   * @description Single-step workflow whose only step is breaker-guarded against the
   * shared dependency.
   */
  public class CircuitBreakerWorkflow implements WorkflowDefinition {
    /**
     * @description Lists the single guarded step.
     * @return The one-element list naming CallDependencyStep.
     */
    public List<String> getSteps() {
      return new List<String>{
        'CircuitBreakerWorkflowExample.CallDependencyStep'
      };
    }
    /**
     * @description Names the guarded step as the entry point.
     * @return The initial step name.
     */
    public String getInitialStep() {
      return 'CircuitBreakerWorkflowExample.CallDependencyStep';
    }
    /**
     * @description Terminates after the single step.
     * @param currentStepName The name of the step that just completed.
     * @param result The result of the completed step.
     * @return Always null, marking the workflow complete.
     */
    public String getNextStep(String currentStepName, StepResult result) {
      return null;
    }
  }

  /**
   * @description Breaker-guarded step that calls the shared dependency. On a
   * dependency outage it returns a terminal failure (counted against the breaker);
   * on success it completes (closing a half-open probe).
   */
  public class CallDependencyStep implements WorkflowStep, CircuitBreakerGuarded {
    /**
     * @description Declares the dependency whose breaker guards this step.
     * @return The shared dependency key.
     */
    public String dependencyKey() {
      return CircuitBreakerWorkflowExample.DEPENDENCY_KEY;
    }
    /**
     * @description Invokes the shared dependency, failing when it is down and
     * completing when it is healthy.
     * @param ctx The durable step context for this execution.
     * @return A terminal failure when the dependency is down, else completion.
     */
    public StepResult execute(StepContext ctx) {
      try {
        CircuitBreakerWorkflowExample.invokeDependency();
        return StepResult.complete(
          null,
          new Map<String, Object>{ 'status' => 'Success' }
        );
      } catch (CircuitBreakerWorkflowExample.DependencyDownException e) {
        return StepResult.fail(e.getMessage());
      }
    }
  }
}
