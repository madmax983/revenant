public inherited sharing class CaseDebounceTriggerHandler {
  public static void handleAfterUpdate(
    List<Case> newCases,
    Map<Id, Case> oldCasesMap
  ) {
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

        // Start a debounced workflow instance: debounce for 5 seconds
        WorkflowEngine.startDebounced(
          'WorkflowEngineTest.HappyWorkflow',
          'Case_Debounce_' + c.Id,
          JSON.serialize(input),
          5 // debounceSeconds
        );
      }
    }
  }
}
