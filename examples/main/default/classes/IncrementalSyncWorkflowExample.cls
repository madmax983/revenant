/**
 * Example: incremental polling workflow using ctx.previousRunAt.
 *
 * Each run queries only the Account records modified since the previous
 * run completed. On the first run, previousRunAt is null, so a
 * configurable cold-start lookback window is used instead.
 *
 * Production shape (use sleep + continue-as-new to throttle):
 *
 *   SyncChangedAccountsStep  -->  SleepStep  -->  ContinueStep
 *
 * Shape: SyncChangedAccountsStep --> SleepStep --> ContinueStep
 * The sleep step is skipped automatically when running inside a test.
 * The workflow loops forever; extend SyncChangedAccountsStep to call
 * StepResult.complete() when a termination condition is met.
 */
public inherited sharing class IncrementalSyncWorkflowExample {
  /** How far back the first-ever run looks when there is no prior run. */
  @TestVisible
  private static Integer coldStartLookbackHours = 24;

  /** Seconds to sleep between polling runs. Ignored in test context. */
  @TestVisible
  private static Integer sleepIntervalSeconds = 300;

  /**
   * @description The polling workflow definition: sync changed records, sleep, then
   * continue-as-new, forming an endless incremental-sync loop.
   */
  public class SyncPollerWorkflow implements WorkflowDefinition {
    /**
     * @description Declares the three steps of the polling loop.
     * @return The list of step names in the sync-poller workflow.
     */
    public List<String> getSteps() {
      return new List<String>{
        'IncrementalSyncWorkflowExample.SyncChangedAccountsStep',
        'IncrementalSyncWorkflowExample.SleepStep',
        'IncrementalSyncWorkflowExample.ContinueStep'
      };
    }

    /**
     * @description Returns the first step of the loop, the sync step.
     * @return The name of the initial step.
     */
    public String getInitialStep() {
      return 'IncrementalSyncWorkflowExample.SyncChangedAccountsStep';
    }

    /**
     * @description Routes the loop: sync then sleep then continue-as-new.
     * @param currentStepName The name of the step that just completed.
     * @param result The result of the completed step.
     * @return The next step name, or null after the continue step.
     */
    public String getNextStep(String currentStepName, StepResult result) {
      if (
        currentStepName ==
        'IncrementalSyncWorkflowExample.SyncChangedAccountsStep'
      ) {
        return 'IncrementalSyncWorkflowExample.SleepStep';
      }
      if (currentStepName == 'IncrementalSyncWorkflowExample.SleepStep') {
        return 'IncrementalSyncWorkflowExample.ContinueStep';
      }
      return null;
    }
  }

  /**
   * @description Queries and processes Account records modified since the previous
   * run, using ctx.previousRunAt as the high-water mark (with a cold-start fallback).
   */
  public inherited sharing class SyncChangedAccountsStep implements WorkflowStep {
    /**
     * @description Drains the full window of Accounts changed since the last run and
     * returns the processed count and window start.
     * @param ctx The durable step context exposing previousRunAt as the sync cursor.
     * @return A complete result carrying the processed count and window start.
     */
    public StepResult execute(StepContext ctx) {
      // Use previousRunAt as the high-water mark. Fall back to a cold-start
      // lookback window on the very first run (previousRunAt is null).
      Datetime since = ctx.previousRunAt != null
        ? ctx.previousRunAt
        : Datetime.now().addHours(-coldStartLookbackHours);

      // Drain the ENTIRE window each run. With previousRunAt as the cursor,
      // run N queries >= start(N-1) and run N+1 queries >= start(N), so every
      // record modified before this run started was already covered by this
      // run's query -- nothing is skipped (boundary records may be seen by two
      // runs, so keep processing idempotent). Capping this with a LIMIT would
      // break that guarantee: the wall-clock cursor would advance past the
      // unprocessed tail and starve it. If you must bound batch size, stop
      // using previousRunAt and carry a data-derived high-water mark
      // (max LastModifiedDate actually processed) forward via ContinueAsNew.
      List<Account> changed = [
        SELECT Id, Name, LastModifiedDate
        FROM Account
        WHERE LastModifiedDate >= :since
        WITH USER_MODE
        ORDER BY LastModifiedDate ASC
      ];

      Integer processed = 0;
      for (Account acc : changed) {
        // Replace with real processing logic.
        processed++;
      }

      return StepResult.complete(
        null,
        new Map<String, Object>{
          'processedCount' => processed,
          'since' => since.formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'')
        }
      );
    }
  }

  /**
   * @description Throttling step that durably sleeps between polling runs, skipped
   * automatically under test so the harness can drive to completion.
   */
  public class SleepStep implements WorkflowStep {
    /**
     * @description Sleeps for the configured interval, or completes immediately when
     * running in a test or resuming after the sleep has elapsed.
     * @param ctx The durable step context exposing prior step state.
     * @return A sleep result, or a complete result under test / on resume.
     */
    public StepResult execute(StepContext ctx) {
      // Skip the actual sleep when running inside a test so the harness
      // can drive the workflow to completion without waiting.
      if (Test.isRunningTest() || ctx.stepStateJson != null) {
        return StepResult.complete(null, null);
      }
      return StepResult.sleep(sleepIntervalSeconds).withStepState('sleeping');
    }
  }

  /**
   * @description Restarts the polling loop as a fresh instance via continue-as-new,
   * keeping the durable history bounded.
   */
  public class ContinueStep implements WorkflowStep {
    /**
     * @description Emits a continue-as-new result to begin the next polling cycle.
     * @param ctx The durable step context.
     * @return A continue-as-new result restarting the workflow.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.continueAsNew(null);
    }
  }
}
