/**
 * Reference example for issue #125: the outbound half of the native-Approval-Process bridge.
 * Builds the decision payload with JSON.serialize() instead of a hand-assembled Flow-formula
 * string, so approver comments containing quotes, backslashes, or line breaks cannot produce
 * invalid JSON. Also hardcodes the target signal name to
 * NativeApprovalWorkflowExample.DECISION_SIGNAL so the Flow never carries its own copy of the
 * 'Approve:' + key literal to drift out of sync with the Apex constant.
 */
public inherited sharing class NativeApprovalDecisionSignalInvocableAction {
  public class DecisionRequest {
    @InvocableVariable(label='Correlation Key / Instance Id' required=true)
    public String targetKey;

    @InvocableVariable(label='Approved' required=true)
    public Boolean approved;

    @InvocableVariable(label='Comments')
    public String comments;

    @InvocableVariable(label='Approver Name')
    public String approverName;

    @InvocableVariable(label='Idempotency Key')
    public String idempotencyKey;
  }

  @InvocableMethod(
    label='Signal Native Approval Decision'
    category='Revenant Workflows'
    description='Publishes the NativeApprovalWorkflowExample decision signal with a safely-serialized JSON payload.'
  )
  public static void signalDecision(List<DecisionRequest> requests) {
    if (requests == null || requests.isEmpty()) {
      return;
    }

    for (DecisionRequest req : requests) {
      String payload = JSON.serialize(
        new Map<String, Object>{
          'approved' => req.approved,
          'comments' => req.comments,
          'approver' => req.approverName
        }
      );
      WorkflowEngine.signal(
        req.targetKey,
        NativeApprovalWorkflowExample.DECISION_SIGNAL,
        payload,
        req.idempotencyKey
      );
    }
  }
}
