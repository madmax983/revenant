/**
 * Reference example for issue #125: an Apex-trigger alternative to
 * Revenant_Native_Approval_Example's Flow-based bridge (two record-triggered Flows +
 * NativeApprRequestSubmitAction / NativeApprDecisionSignalAction).
 * Drives the exact same NativeApprovalWorkflowExample workflow, keyed by Case.Id, via a
 * trigger bridge. This bridge makes it easy to prove the round-trip behavior in pure Apex tests
 * (see NativeApprovalTriggerBridgeExampleTest) and carries no Flow-metadata-shape risk.
 *
 * This is example-only wiring on the standard Case object: it acts on every Case in the org,
 * not just demo records, since a real deployment would scope this (e.g. a dedicated Record
 * Type) before adopting the pattern for production use.
 */
public inherited sharing class NativeApprovalTriggerBridgeExample {
  /**
   * Trigger entry point. Inspects the current Trigger context and dispatches to the
   * matching handler method, keeping the CaseApprovalBridgeTrigger body a single delegation call.
   */
  public static void run() {
    if (Trigger.isAfter && Trigger.isInsert) {
      handleAfterInsert((List<Case>) Trigger.new);
    }
    if (Trigger.isAfter && Trigger.isUpdate) {
      handleAfterUpdate(
        (List<Case>) Trigger.new,
        (Map<Id, Case>) Trigger.oldMap
      );
    }
  }

  /**
   * Starts NativeApprovalWorkflowExample for each new Case (correlationKey = Case.Id; no
   * custom key fields required) and runs its initial steps. (Note: the budget step and
   * saga/compensation shape already covered by NativeApprovalWorkflowExampleTest). Submits
   * the Case into the native Case.Revenant_Trigger_Approval_Example process.
   */
  public static void handleAfterInsert(List<Case> newCases) {
    List<WorkflowEngine.StartRequest> startRequests = new List<WorkflowEngine.StartRequest>();
    for (Case c : newCases) {
      startRequests.add(
        new WorkflowEngine.StartRequest(
          'NativeApprovalWorkflowExample',
          c.Id,
          new Map<String, Object>()
        )
      );
    }

    List<WorkflowEngine.StartResult> startResults = WorkflowEngine.startOrGet(
      startRequests
    );

    List<Approval.ProcessSubmitRequest> submitRequests = new List<Approval.ProcessSubmitRequest>();
    for (Integer i = 0; i < newCases.size(); i++) {
      if (startResults[i] != null && startResults[i].isNew) {
        Approval.ProcessSubmitRequest submitReq = new Approval.ProcessSubmitRequest();
        submitReq.setObjectId(newCases[i].Id);
        submitRequests.add(submitReq);
      }
    }

    if (submitRequests.isEmpty()) {
      return;
    }

    try {
      Approval.process(submitRequests, false);
    } catch (Exception ignored) {
      // Native submission may fail (e.g. inactive Approval Process); the workflow still
      // suspends awaiting the decision signal, so the failure is intentionally swallowed.
    }
  }

  /**
   * Reads the approver's actual decision comment from the standard approval history
   * (ProcessInstance / ProcessInstanceStep.Comments -- Salesforce's built-in Approve/Reject
   * comment box is stored there, not written back onto the record automatically) and signals
   * the workflow directly, bypassing Flow entirely. JSON.serialize() builds the payload, so a
   * multi-line or quote-containing comment can never produce invalid JSON the way a
   * hand-assembled Flow-formula string could.
   */
  public static void handleAfterUpdate(
    List<Case> newCases,
    Map<Id, Case> oldCasesMap
  ) {
    Set<Id> decidedCaseIds = collectDecidedCaseIds(newCases, oldCasesMap);
    if (decidedCaseIds.isEmpty()) {
      return;
    }

    Map<Id, Id> latestProcessInstanceIdByCaseId = queryLatestProcessInstanceIdByCaseId(
      decidedCaseIds
    );
    Map<Id, String> latestCommentByProcessInstanceId = queryLatestCommentByProcessInstanceId(
      latestProcessInstanceIdByCaseId.values()
    );
    Map<Id, String> commentByCaseId = resolveCommentByCaseId(
      decidedCaseIds,
      latestProcessInstanceIdByCaseId,
      latestCommentByProcessInstanceId
    );

    List<WorkflowEngine.SignalRequest> signalRequests = buildSignalRequests(
      newCases,
      decidedCaseIds,
      commentByCaseId
    );

    if (signalRequests.isEmpty()) {
      return;
    }
    WorkflowEngine.signal(signalRequests);
  }

  /**
   * Returns the Ids of Cases whose Approval_Status__c changed to a decided (non-Pending)
   * value in this update, i.e. the Cases an approver has just approved or rejected.
   */
  private static Set<Id> collectDecidedCaseIds(
    List<Case> newCases,
    Map<Id, Case> oldCasesMap
  ) {
    Set<Id> decidedCaseIds = new Set<Id>();
    for (Case c : newCases) {
      Case oldCase = oldCasesMap.get(c.Id);
      if (
        c.Approval_Status__c != oldCase.Approval_Status__c &&
        c.Approval_Status__c != 'Pending'
      ) {
        decidedCaseIds.add(c.Id);
      }
    }
    return decidedCaseIds;
  }

  /**
   * Maps each decided Case Id to its most recent ProcessInstance Id (approval history header).
   */
  private static Map<Id, Id> queryLatestProcessInstanceIdByCaseId(
    Set<Id> decidedCaseIds
  ) {
    Map<Id, Id> latestProcessInstanceIdByCaseId = new Map<Id, Id>();
    for (ProcessInstance pi : [
      SELECT Id, TargetObjectId
      FROM ProcessInstance
      WHERE TargetObjectId IN :decidedCaseIds
      WITH USER_MODE
      ORDER BY CreatedDate DESC
    ]) {
      if (!latestProcessInstanceIdByCaseId.containsKey(pi.TargetObjectId)) {
        latestProcessInstanceIdByCaseId.put(pi.TargetObjectId, pi.Id);
      }
    }
    return latestProcessInstanceIdByCaseId;
  }

  /**
   * Maps each ProcessInstance Id to the approver's comment on its latest Approved/Rejected step.
   */
  private static Map<Id, String> queryLatestCommentByProcessInstanceId(
    List<Id> processInstanceIds
  ) {
    Map<Id, String> latestCommentByProcessInstanceId = new Map<Id, String>();
    for (ProcessInstanceStep step : [
      SELECT ProcessInstanceId, Comments
      FROM ProcessInstanceStep
      WHERE
        ProcessInstanceId IN :processInstanceIds
        AND StepStatus IN ('Approved', 'Rejected')
      WITH USER_MODE
      ORDER BY CreatedDate DESC
    ]) {
      if (
        !latestCommentByProcessInstanceId.containsKey(step.ProcessInstanceId)
      ) {
        latestCommentByProcessInstanceId.put(
          step.ProcessInstanceId,
          step.Comments
        );
      }
    }
    return latestCommentByProcessInstanceId;
  }

  /**
   * Flattens the two-hop lookup (Case -> ProcessInstance -> approval comment) into a
   * single Case Id -> comment map, preserving the exact "latest" semantics of the two
   * source maps so buildSignalRequests can stay a simple one-argument-per-Case builder.
   */
  private static Map<Id, String> resolveCommentByCaseId(
    Set<Id> decidedCaseIds,
    Map<Id, Id> processInstanceIdByCaseId,
    Map<Id, String> commentByProcessInstanceId
  ) {
    Map<Id, String> commentByCaseId = new Map<Id, String>();
    for (Id caseId : decidedCaseIds) {
      Id processInstanceId = processInstanceIdByCaseId.get(caseId);
      commentByCaseId.put(
        caseId,
        processInstanceId != null
          ? commentByProcessInstanceId.get(processInstanceId)
          : null
      );
    }
    return commentByCaseId;
  }

  /**
   * Builds one idempotent decision SignalRequest per decided Case, carrying the approved
   * flag, the approver's comment (when available), and the approver's name.
   */
  private static List<WorkflowEngine.SignalRequest> buildSignalRequests(
    List<Case> newCases,
    Set<Id> decidedCaseIds,
    Map<Id, String> commentByCaseId
  ) {
    List<WorkflowEngine.SignalRequest> signalRequests = new List<WorkflowEngine.SignalRequest>();
    for (Case c : newCases) {
      if (!decidedCaseIds.contains(c.Id)) {
        continue;
      }
      String comments = commentByCaseId.get(c.Id);

      String payload = JSON.serialize(
        new Map<String, Object>{
          'approved' => c.Approval_Status__c == 'Approved',
          'comments' => comments,
          'approver' => UserInfo.getName()
        }
      );

      WorkflowEngine.SignalRequest req = new WorkflowEngine.SignalRequest(
        c.Id,
        NativeApprovalWorkflowExample.DECISION_SIGNAL,
        payload
      );
      req.idempotencyKey = c.Id;
      signalRequests.add(req);
    }
    return signalRequests;
  }
}
