/**
 * @description Reference example for cooperative cancellation (issue #143). A
 * long loop tags Accounts in batches of CHECK_EVERY records. After each batch it
 * calls `ctx.isCancellationRequested()`. When an operator cancels the instance,
 * the loop stops at its next check. The engine drops the returned result, sets
 * the step row to `Cancelled` and rolls back the reserve step when the cancel
 * asked for it.
 *
 * Work after a cancel is at most one batch. Tune CHECK_EVERY: a small value
 * stops sooner, a large value costs fewer SOQL queries.
 */
public inherited sharing class CooperativeCancelWorkflowExample {
  /** Text that the loop writes to `Account.Description`. */
  public static final String TAG = 'Tagged by CooperativeCancelWorkflowExample';
  /** Records for each batch. The loop checks for a cancel after each batch. */
  public static final Integer CHECK_EVERY = 5;
  /** Records for each run. A full run yields, and the next run continues. */
  public static final Integer RUN_LIMIT = 10;

  /**
   * @description Does the work for one batch. A test can replace it.
   */
  public interface AccountTagger {
    /**
     * @description Tags the records.
     * @param batch The records to tag.
     */
    void tag(List<Account> batch);
  }

  /**
   * @description Default tagger: writes TAG to `Description`.
   */
  public inherited sharing class DescriptionTagger implements AccountTagger {
    /**
     * @description Tags the records with one DML.
     * @param batch The records to tag.
     */
    public void tag(List<Account> batch) {
      for (Account acc : batch) {
        acc.Description = TAG;
      }
      Database.update(batch, AccessLevel.USER_MODE);
    }
  }

  @TestVisible
  private static AccountTagger tagger = new DescriptionTagger();

  /**
   * @description Saga: reserve a quota, then tag the Accounts.
   */
  public class CooperativeCancelWorkflow implements WorkflowDefinition {
    /**
     * @description Lists the steps.
     * @return The step names in order.
     */
    public List<String> getSteps() {
      return new List<String>{
        'CooperativeCancelWorkflowExample.ReserveQuotaStep',
        'CooperativeCancelWorkflowExample.TagAccountsStep'
      };
    }

    /**
     * @description Gives the first step.
     * @return The reserve step.
     */
    public String getInitialStep() {
      return 'CooperativeCancelWorkflowExample.ReserveQuotaStep';
    }

    /**
     * @description Runs the tag step after the reserve step.
     * @param currentStepName The step that completed.
     * @param result Its result.
     * @return The next step, or null at the end.
     */
    public String getNextStep(String currentStepName, StepResult result) {
      if (
        currentStepName == 'CooperativeCancelWorkflowExample.ReserveQuotaStep'
      ) {
        return 'CooperativeCancelWorkflowExample.TagAccountsStep';
      }
      return null;
    }
  }

  /**
   * @description Reserves a quota. A cancel with compensations releases it.
   */
  public class ReserveQuotaStep implements CompensatableStep {
    /**
     * @description Reserves the quota.
     * @param ctx The step context.
     * @return COMPLETE.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, 'reserved');
    }

    /**
     * @description Releases the quota. A rollback always finishes:
     * `isCancellationRequested()` is false here.
     * @param ctx The compensation context.
     * @return COMPLETE.
     */
    public StepResult compensate(StepContext ctx) {
      return StepResult.complete(null, 'released');
    }
  }

  /**
   * @description Tags Accounts in batches and stops at the next check after a
   * cancel.
   */
  public class TagAccountsStep implements WorkflowStep {
    /**
     * @description Tags up to RUN_LIMIT records. Checks for a cancel and for
     * governor pressure after each batch.
     * @param ctx The step context.
     * @return YIELD to stop or to continue in a new run, else COMPLETE.
     */
    public StepResult execute(StepContext ctx) {
      TagState state = readState(ctx.stepStateJson);
      List<Account> scope = nextScope(state.lastId);
      List<Account> batch = new List<Account>();
      for (Account acc : scope) {
        batch.add(acc);
        if (batch.size() < CHECK_EVERY) {
          continue;
        }
        flush(batch, state);
        // Check once for each batch, not for each record. After a cancel, the
        // engine drops this YIELD and ends the step.
        if (ctx.isCancellationRequested() || ctx.shouldYield()) {
          return StepResult.yield(JSON.serialize(state));
        }
      }
      flush(batch, state);
      if (scope.size() == RUN_LIMIT) {
        return StepResult.yield(JSON.serialize(state));
      }
      return StepResult.complete(
        null,
        new Map<String, Object>{ 'tagged' => state.tagged }
      );
    }

    // A batch cursor: the step state keeps the position, so a new run reads
    // the next records. It does not route a wait on the data.
    private List<Account> nextScope(Id lastId) {
      if (lastId == null) {
        // revenant-lint-disable-next-line: batch cursor read, see above
        return [
          SELECT Id
          FROM Account
          WITH USER_MODE
          ORDER BY Id
          LIMIT :RUN_LIMIT
        ];
      }
      // revenant-lint-disable-next-line: batch cursor read, see above
      return [
        SELECT Id
        FROM Account
        WHERE Id > :lastId
        WITH USER_MODE
        ORDER BY Id
        LIMIT :RUN_LIMIT
      ];
    }

    private void flush(List<Account> batch, TagState state) {
      if (batch.isEmpty()) {
        return;
      }
      tagger.tag(batch);
      state.tagged += batch.size();
      state.lastId = batch[batch.size() - 1].Id;
      batch.clear();
    }
  }

  /**
   * @description Loop cursor saved in the step state between runs.
   */
  public class TagState {
    /** The last tagged record, or null before the first batch. */
    public Id lastId;
    /** The number of tagged records. */
    public Integer tagged = 0;
  }

  // Reads the state, or makes a new one on the first run.
  private static TagState readState(String stateJson) {
    return String.isBlank(stateJson)
      ? new TagState()
      : (TagState) JSON.deserialize(stateJson, TagState.class);
  }
}
