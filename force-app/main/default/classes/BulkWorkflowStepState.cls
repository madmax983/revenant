/**
 * Shared step-state helpers for the operator bulk jobs (BulkCancelWorkflow and
 * BulkRedriveWorkflow). Both single-step jobs hydrate their resumable state,
 * read their paging cursor, and coerce running tallies from untyped JSON state
 * identically; centralising that here removes the duplicated JSON plumbing from
 * the two step bodies.
 */
public inherited sharing class BulkWorkflowStepState {
  /**
   * Hydrates step state: on the first run the persisted state is empty, so seed
   * it from the operator's filter (the workflow input), copying exactly the
   * caller-supplied filterKeys; on resume, the yield state carries the cursor and
   * running tallies forward. filterKeys lets each job seed its own filter shape
   * (BulkCancel additionally carries 'runCompensations') without duplicating the
   * surrounding hydration plumbing.
   *
   * @param ctx The step context carrying the persisted state and workflow input.
   * @param filterKeys The filter keys to seed from the input on the first run.
   * @return The hydrated step state map.
   */
  public static Map<String, Object> hydrate(
    StepContext ctx,
    List<String> filterKeys
  ) {
    if (String.isNotBlank(ctx.stepStateJson)) {
      return (Map<String, Object>) JSON.deserializeUntyped(ctx.stepStateJson);
    }
    Map<String, Object> state = new Map<String, Object>();
    if (String.isBlank(ctx.workflowInputJson)) {
      return state;
    }
    Map<String, Object> filter = (Map<String, Object>) JSON.deserializeUntyped(
      ctx.workflowInputJson
    );
    for (String key : filterKeys) {
      state.put(key, filter.get(key));
    }
    return state;
  }

  /**
   * @description Reads the resumable paging cursor (lastId) from hydrated state.
   * @param state The hydrated step state map.
   * @return The cursor Id, or null when no cursor has been recorded yet.
   */
  public static Id cursorFrom(Map<String, Object> state) {
    return state.get('lastId') != null
      ? (Id) (String) state.get('lastId')
      : null;
  }

  /**
   * @description Null-safe Integer coercion for tally values pulled from untyped
   * state.
   * @param o The untyped value to coerce.
   * @return The Integer value, or 0 when the value is null.
   */
  public static Integer intOf(Object o) {
    return o == null ? 0 : Integer.valueOf(String.valueOf(o));
  }
}
