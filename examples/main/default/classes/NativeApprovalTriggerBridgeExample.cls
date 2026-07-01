/**
 * Reference example for issue #125: an Apex-trigger alternative to
 * Revenant_Native_Approval_Example's Flow-based bridge (two record-triggered Flows +
 * NativeApprovalRequestSubmitInvocableAction / NativeApprovalDecisionSignalInvocableAction).
 * Drives the exact same NativeApprovalWorkflowExample workflow, keyed by Case.Id, via a
 * single trigger (CaseApprovalBridgeTrigger.trigger) and this handler -- no Flow metadata at
 * all. Compare the two: this one trades an admin-reconfigurable, no-code Flow surface for a
 * developer-owned Apex surface that is fully testable end-to-end via real DML in Apex tests
 * (see NativeApprovalTriggerBridgeExampleTest) and carries no Flow-metadata-shape risk.
 *
 * This is example-only wiring on the standard Case object: it acts on every Case in the org,
 * not just demo records, since a real deployment would scope this (e.g. a dedicated Record
 * Type) before adopting the pattern for production use.
 */
public inherited sharing class NativeApprovalTriggerBridgeExample {
  /**
   * Starts NativeApprovalWorkflowExample for each new Case (correlationKey = Case.Id; no
   * amount is passed since ReserveBudgetStep already defaults to 0 when the 'amount' key is
   * absent -- this example's job is to demonstrate the bridge, not re-demonstrate the
   * saga/compensation shape already covered by NativeApprovalWorkflowExampleTest). Submits
   * only the instances that are genuinely new (WorkflowEngine.startOrGet's isNew) into the
   * native Approval Process, so a correlation-key collision with an existing instance never
   * creates an approval whose eventual decision would signal the wrong instance.
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

    List<WorkflowEngine.StartResult> startResults = WorkflowEngine.startOrGet(startRequests);

    List<Approval.ProcessSubmitRequest> submitRequests = new List<Approval.ProcessSubmitRequest>();
    for (Integer i = 0; i < newCases.size(); i++) {
      if (startResults[i] != null && startResults[i].isNew) {
        Approval.ProcessSubmitRequest submitReq = new Approval.ProcessSubmitRequest();
        submitReq.setObjectId(newCases[i].Id);
        submitReq.setAllOrNoneHeader(false);
        submitRequests.add(submitReq);
      }
    }

    if (submitRequests.isEmpty()) {
      return;
    }

    try {
      Approval.process(submitRequests);
    } catch (Exception e) {
      System.debug(LoggingLevel.WARN, 'Case approval submission failed: ' + e.getMessage());
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
  public static void handleAfterUpdate(List<Case> newCases, Map<Id, Case> oldCasesMap) {
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

    if (decidedCaseIds.isEmpty()) {
      return;
    }

    Map<Id, Id> latestProcessInstanceIdByCaseId = new Map<Id, Id>();
    for (ProcessInstance pi : [
      SELECT Id, TargetObjectId
      FROM ProcessInstance
      WHERE TargetObjectId IN :decidedCaseIds
      ORDER BY CreatedDate DESC
      WITH USER_MODE
    ]) {
      if (!latestProcessInstanceIdByCaseId.containsKey(pi.TargetObjectId)) {
        latestProcessInstanceIdByCaseId.put(pi.TargetObjectId, pi.Id);
      }
    }

    Map<Id, String> latestCommentByProcessInstanceId = new Map<Id, String>();
    for (ProcessInstanceStep step : [
      SELECT ProcessInstanceId, Comments
      FROM ProcessInstanceStep
      WHERE
        ProcessInstanceId IN :latestProcessInstanceIdByCaseId.values()
        AND StepStatus IN ('Approved', 'Rejected')
      ORDER BY CreatedDate DESC
      WITH USER_MODE
    ]) {
      if (!latestCommentByProcessInstanceId.containsKey(step.ProcessInstanceId)) {
        latestCommentByProcessInstanceId.put(step.ProcessInstanceId, step.Comments);
      }
    }

    List<WorkflowEngine.SignalRequest> signalRequests = new List<WorkflowEngine.SignalRequest>();
    for (Case c : newCases) {
      if (!decidedCaseIds.contains(c.Id)) {
        continue;
      }
      Id processInstanceId = latestProcessInstanceIdByCaseId.get(c.Id);
      String comments = processInstanceId != null
        ? latestCommentByProcessInstanceId.get(processInstanceId)
        : null;

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

    if (signalRequests.isEmpty()) {
      return;
    }
    WorkflowEngine.signal(signalRequests);
  }
}
