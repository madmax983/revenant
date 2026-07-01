/**
 * Reference example for issue #125: the missing half of the native-Approval-Process bridge.
 * Meeting an Approval Process's entry criteria is not, by itself, sufficient to enter a
 * record into the process -- Salesforce always requires an explicit submission action.
 * This invocable is that submission action, callable declaratively from
 * Revenant_Start_Approval_Workflow_Example.flow-meta.xml right after the workflow starts, so
 * creating an Approval_Request__c both starts the durable workflow AND submits the record
 * for approval in the same transaction.
 */
public inherited sharing class NativeApprovalRequestSubmitInvocableAction {
  public class SubmitRequest {
    @InvocableVariable(label='Record Id' required=true)
    public Id recordId;

    @InvocableVariable(
      label='Approval Process Name or Id'
      description='Optional. Leave blank to let Salesforce pick the first process whose entry criteria the record satisfies.'
    )
    public String processDefinitionNameOrId;
  }

  public class SubmitResult {
    @InvocableVariable(label='Success')
    public Boolean success;

    @InvocableVariable(label='Error Message')
    public String errorMessage;
  }

  /**
   * Submits each record via Approval.process(). Failures (most commonly: no active Approval
   * Process yet matches the record, since Approval Processes always deploy inactive) are
   * captured per-record on the result rather than thrown, so one record's submission failure
   * cannot fault the whole Flow interview or block the workflow-start action that already ran.
   */
  @InvocableMethod(
    label='Submit Record For Approval'
    category='Revenant Workflows'
    description='Submits a record into a native Salesforce Approval Process via Approval.process().'
  )
  public static List<SubmitResult> submitForApproval(List<SubmitRequest> requests) {
    if (requests == null || requests.isEmpty()) {
      return new List<SubmitResult>();
    }

    List<SubmitResult> results = new List<SubmitResult>();
    for (SubmitRequest req : requests) {
      SubmitResult res = new SubmitResult();
      try {
        Approval.ProcessSubmitRequest submitReq = new Approval.ProcessSubmitRequest();
        submitReq.setObjectId(req.recordId);
        if (String.isNotBlank(req.processDefinitionNameOrId)) {
          submitReq.setProcessDefinitionNameOrId(req.processDefinitionNameOrId);
        }
        Approval.ProcessResult processResult = Approval.process(submitReq);
        res.success = processResult.isSuccess();
      } catch (Exception e) {
        res.success = false;
        res.errorMessage = e.getMessage();
        System.debug(LoggingLevel.WARN, 'Approval submission failed: ' + e.getMessage());
      }
      results.add(res);
    }
    return results;
  }
}
