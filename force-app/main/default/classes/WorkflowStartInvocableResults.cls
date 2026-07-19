/**
 * @description Builders for the "Start Workflow" invocable's per-row result
 * ({@link WorkflowStartInvocableAction.StartResult}), factored out of the routing
 * ({@link WorkflowStartInvocableRouter}) so each class stays within the repo's
 * per-class complexity budget. Pure in-memory construction — no SOQL/DML.
 */
public inherited sharing class WorkflowStartInvocableResults {
  /**
   * @description Builds a delivered result (new or dedup-resolved instance),
   * flagged isValid=true.
   * @param engineResult the engine's start result (may be null)
   * @return a StartResult carrying the instance Id / isNew and isValid=true
   */
  public static WorkflowStartInvocableAction.StartResult startedResult(
    WorkflowEngine.StartResult engineResult
  ) {
    WorkflowStartInvocableAction.StartResult res = new WorkflowStartInvocableAction.StartResult();
    res.workflowInstanceId = engineResult == null
      ? null
      : engineResult.instanceId;
    res.isNew = engineResult == null ? null : engineResult.isNew;
    res.isValid = true;
    res.validationError = null;
    return res;
  }

  /**
   * @description Builds a branchable failure result for a row whose new-instance
   * start input violated the workflow's declared contract.
   * @param validationError the enumerated field-level violation message
   * @return a StartResult flagged invalid, with no started instance
   */
  public static WorkflowStartInvocableAction.StartResult invalidResult(
    String validationError
  ) {
    WorkflowStartInvocableAction.StartResult res = new WorkflowStartInvocableAction.StartResult();
    res.workflowInstanceId = null;
    res.isNew = null;
    res.isValid = false;
    res.validationError = validationError;
    return res;
  }

  /**
   * @description Builds the result for an armed debounced row: no instance yet,
   * isValid=true (validation is deferred to sweep).
   * @return a StartResult marking a successfully-armed debounce
   */
  public static WorkflowStartInvocableAction.StartResult debouncedResult() {
    WorkflowStartInvocableAction.StartResult res = new WorkflowStartInvocableAction.StartResult();
    res.workflowInstanceId = null;
    res.isNew = false;
    res.isValid = true;
    res.validationError = null;
    return res;
  }

  /**
   * @description Builds the result for a null input row.
   * @return a StartResult with all fields null
   */
  public static WorkflowStartInvocableAction.StartResult nullResult() {
    WorkflowStartInvocableAction.StartResult res = new WorkflowStartInvocableAction.StartResult();
    res.workflowInstanceId = null;
    res.isNew = null;
    res.isValid = null;
    res.validationError = null;
    return res;
  }
}
