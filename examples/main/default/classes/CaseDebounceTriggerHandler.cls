public inherited sharing class CaseDebounceTriggerHandler {
  public static void handleAfterUpdate(
    List<Case> newCases,
    Map<Id, Case> oldCasesMap
  ) {
    List<WorkflowDebouncer.DebounceRequest> debounceRequests = new List<WorkflowDebouncer.DebounceRequest>();

    for (Case c : newCases) {
      Case oldCase = oldCasesMap.get(c.Id);

      // Coalesce updates when the Case Subject or Description changes
      if (
        c.Subject != oldCase.Subject ||
        c.Description != oldCase.Description
      ) {
        // Build the payload
        Map<String, Object> input = new Map<String, Object>{
          'caseId' => c.Id,
          'subject' => c.Subject,
          'description' => c.Description
        };

        // Collect bulk debounce request: debounce for 5 seconds
        WorkflowDebouncer.DebounceRequest debounceReq = new WorkflowDebouncer.DebounceRequest();
        debounceReq.workflowName = 'CaseDebounceWorkflowExample';
        debounceReq.correlationKey = 'Case_Debounce_' + c.Id;
        debounceReq.inputJson = JSON.serialize(input);
        debounceReq.debounceSeconds = 5;
        debounceReq.maxWaitSeconds = null;
        debounceRequests.add(debounceReq);
      }
    }

    if (!debounceRequests.isEmpty()) {
      WorkflowDebouncer.startDebounced(debounceRequests);
    }
  }
}
