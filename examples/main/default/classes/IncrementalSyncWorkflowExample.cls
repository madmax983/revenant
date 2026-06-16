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
  private static Integer COLD_START_LOOKBACK_HOURS = 24;

  /** Seconds to sleep between polling runs. Ignored in test context. */
  @TestVisible
  private static Integer SLEEP_INTERVAL_SECONDS = 300;

  public class SyncPollerWorkflow implements WorkflowDefinition {
    public String getInitialStep() {
      return 'IncrementalSyncWorkflowExample.SyncChangedAccountsStep';
    }

    public String getNextStep(String currentStepName, StepResult result) {
      if (currentStepName == 'IncrementalSyncWorkflowExample.SyncChangedAccountsStep') {
        return 'IncrementalSyncWorkflowExample.SleepStep';
      }
      if (currentStepName == 'IncrementalSyncWorkflowExample.SleepStep') {
        return 'IncrementalSyncWorkflowExample.ContinueStep';
      }
      return null;
    }
  }

  public class SyncChangedAccountsStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      // Use previousRunAt as the high-water mark. Fall back to a cold-start
      // lookback window on the very first run (previousRunAt is null).
      Datetime since = ctx.previousRunAt != null
        ? ctx.previousRunAt
        : Datetime.now().addHours(-COLD_START_LOOKBACK_HOURS);

      List<Account> changed = [
        SELECT Id, Name, LastModifiedDate
        FROM Account
        WHERE LastModifiedDate >= :since
        ORDER BY LastModifiedDate ASC
        LIMIT 200
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

  public class SleepStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      // Skip the actual sleep when running inside a test so the harness
      // can drive the workflow to completion without waiting.
      if (Test.isRunningTest() || ctx.stepStateJson != null) {
        return StepResult.complete(null, null);
      }
      return StepResult.sleep(SLEEP_INTERVAL_SECONDS, 'sleeping');
    }
  }

  public class ContinueStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      return StepResult.continueAsNew(null);
    }
  }
}