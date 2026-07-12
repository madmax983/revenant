/**
 * @description Example trigger handler that starts a customer onboarding workflow for each
 * Opportunity transitioning into 'Closed Won', demonstrating how to launch workflows from
 * record changes in bulk.
 */
public inherited sharing class OpportunityTriggerHandler {
  /**
   * @description Trigger entry point. Inspects the current Trigger context and
   * dispatches to the matching handler method, keeping the OpportunityTrigger
   * body a single delegation call.
   */
  public static void run() {
    if (Trigger.isAfter && Trigger.isUpdate) {
      handleAfterUpdate(
        (List<Opportunity>) Trigger.new,
        (Map<Id, Opportunity>) Trigger.oldMap
      );
    }
  }

  /**
   * @description Starts an onboarding workflow in bulk for every Opportunity that just
   * transitioned to 'Closed Won'.
   * @param newOpps The updated Opportunity records from the trigger.
   * @param oldOppsMap The prior state of the Opportunities keyed by Id.
   */
  public static void handleAfterUpdate(
    List<Opportunity> newOpps,
    Map<Id, Opportunity> oldOppsMap
  ) {
    List<Id> oppIdsToOnboard = new List<Id>();

    for (Opportunity opp : newOpps) {
      Opportunity oldOpp = oldOppsMap.get(opp.Id);

      // Trigger onboarding only when StageName transitions to 'Closed Won'
      if (opp.StageName == 'Closed Won' && oldOpp.StageName != 'Closed Won') {
        oppIdsToOnboard.add(opp.Id);
      }
    }

    if (oppIdsToOnboard.isEmpty()) {
      return;
    }

    // Query Opportunity with Account details
    List<Opportunity> oppsWithDetails = [
      SELECT Id, Amount, Name, Account.Name
      FROM Opportunity
      WHERE Id IN :oppIdsToOnboard
      WITH USER_MODE
    ];

    List<WorkflowEngine.StartRequest> requests = new List<WorkflowEngine.StartRequest>();
    for (Opportunity opp : oppsWithDetails) {
      // Build the input for the OnboardingWorkflowExample
      Map<String, Object> input = new Map<String, Object>{
        'amount' => opp.Amount != null ? opp.Amount : 0.0,
        'customerName' => opp.Account != null ? opp.Account.Name : opp.Name,
        'email' => 'customer@' +
        (opp.Account != null
          ? opp.Account.Name.replaceAll('[^a-zA-Z0-9]', '').toLowerCase()
          : 'example') +
        '.com'
      };

      // Queue the start request
      requests.add(
        new WorkflowEngine.StartRequest(
          'OnboardingWorkflowExample',
          'Opp_Onboarding_' + opp.Id,
          input
        )
      );
    }

    // Start the customer onboarding workflows in bulk
    WorkflowEngine.start(requests);
  }
}
