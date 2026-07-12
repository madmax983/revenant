/**
 * @description Example after-update Case trigger handler that debounces rapid
 * Subject/Description edits into a single coalesced workflow start via
 * WorkflowDebouncer, so a burst of updates launches one instance per Case.
 */
public inherited sharing class CaseDebounceTriggerHandler {
  /**
   * @description Trigger entry point. Inspects the current Trigger context and
   * dispatches to the matching handler method, keeping the CaseDebounceTrigger
   * body a single delegation call.
   */
  public static void run() {
    if (Trigger.isAfter && Trigger.isUpdate) {
      handleAfterUpdate(
        (List<Case>) Trigger.new,
        (Map<Id, Case>) Trigger.oldMap
      );
    }
  }

  /**
   * @description Collects a debounced workflow-start request for every Case
   * whose Subject or Description changed, then submits them in bulk with a
   * short debounce window.
   * @param newCases Trigger.new list of updated Case records.
   * @param oldCasesMap Trigger.oldMap of prior Case states.
   */
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
