/**
 * @description Builders for the "Signal or Start" invocable's per-row result
 * ({@link WorkflowSignalOrStartInvocableAction.SignalOrStartResult}), factored out
 * of the invocable and its suspect resolver so each class stays within the repo's
 * per-class complexity budget. Pure in-memory construction — no SOQL/DML.
 */
public inherited sharing class WorkflowSignalOrStartResults {
  /**
   * @description Builds a delivered result (new or dedup-resolved instance),
   * flagged isValid=true.
   * @param engineResult the engine's start result (may be null)
   * @return a SignalOrStartResult carrying the instance Id / isNew and isValid=true
   */
  public static WorkflowSignalOrStartInvocableAction.SignalOrStartResult deliveredResult(
    WorkflowEngine.StartResult engineResult
  ) {
    WorkflowSignalOrStartInvocableAction.SignalOrStartResult res = new WorkflowSignalOrStartInvocableAction.SignalOrStartResult();
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
   * @return a SignalOrStartResult flagged invalid, with no instance
   */
  public static WorkflowSignalOrStartInvocableAction.SignalOrStartResult invalidResult(
    String validationError
  ) {
    WorkflowSignalOrStartInvocableAction.SignalOrStartResult res = new WorkflowSignalOrStartInvocableAction.SignalOrStartResult();
    res.workflowInstanceId = null;
    res.isNew = null;
    res.isValid = false;
    res.validationError = validationError;
    return res;
  }

  /**
   * @description Builds the result for a null input row.
   * @return a SignalOrStartResult with all fields null
   */
  public static WorkflowSignalOrStartInvocableAction.SignalOrStartResult nullResult() {
    WorkflowSignalOrStartInvocableAction.SignalOrStartResult res = new WorkflowSignalOrStartInvocableAction.SignalOrStartResult();
    res.workflowInstanceId = null;
    res.isNew = null;
    res.isValid = null;
    res.validationError = null;
    return res;
  }
}
