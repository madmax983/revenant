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
   * Submits every record in a single bulk Approval.process(List<Approval.ProcessSubmitRequest>)
   * call so batches don't spend one DML-counted Approval.process invocation per record. Each
   * individual request has setAllOrNoneHeader(false) so one record's submission failure (most
   * commonly: no active Approval Process yet matches the record, since Approval Processes
   * always deploy inactive) is captured as that record's own failed ProcessResult instead of
   * aborting the whole bulk call -- without this, a single bad record would sink every other
   * record's successful submission in the same batch. The outer try/catch is defense-in-depth
   * for failures that can occur before any ProcessResult is returned, so the invocable's
   * contract -- one SubmitResult per SubmitRequest, never thrown -- holds even in that
   * fallback path.
   */
  @InvocableMethod(
    label='Submit Record For Approval'
    category='Revenant Workflows'
    description='Submits records into a native Salesforce Approval Process via Approval.process().'
  )
  public static List<SubmitResult> submitForApproval(List<SubmitRequest> requests) {
    if (requests == null || requests.isEmpty()) {
      return new List<SubmitResult>();
    }

    List<Approval.ProcessSubmitRequest> submitRequests = new List<Approval.ProcessSubmitRequest>();
    for (SubmitRequest req : requests) {
      Approval.ProcessSubmitRequest submitReq = new Approval.ProcessSubmitRequest();
      submitReq.setObjectId(req.recordId);
      if (String.isNotBlank(req.processDefinitionNameOrId)) {
        submitReq.setProcessDefinitionNameOrId(req.processDefinitionNameOrId);
      }
      submitReq.setAllOrNoneHeader(false);
      submitRequests.add(submitReq);
    }

    List<SubmitResult> results = new List<SubmitResult>();
    try {
      List<Approval.ProcessResult> processResults = Approval.process(submitRequests);
      for (Approval.ProcessResult processResult : processResults) {
        SubmitResult res = new SubmitResult();
        res.success = processResult.isSuccess();
        if (!res.success) {
          res.errorMessage = collectErrorMessage(processResult);
          System.debug(LoggingLevel.WARN, 'Approval submission failed: ' + res.errorMessage);
        }
        results.add(res);
      }
    } catch (Exception e) {
      System.debug(LoggingLevel.WARN, 'Bulk approval submission failed: ' + e.getMessage());
      results.clear();
      for (Integer i = 0; i < requests.size(); i++) {
        SubmitResult res = new SubmitResult();
        res.success = false;
        res.errorMessage = e.getMessage();
        results.add(res);
      }
    }
    return results;
  }

  private static String collectErrorMessage(Approval.ProcessResult processResult) {
    List<String> messages = new List<String>();
    for (Database.Error err : processResult.getErrors()) {
      messages.add(err.getMessage());
    }
    return messages.isEmpty() ? 'Approval submission failed.' : String.join(messages, '; ');
  }
}
