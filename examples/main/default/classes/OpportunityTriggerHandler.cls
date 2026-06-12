public class OpportunityTriggerHandler {
    
    public static void handleAfterUpdate(List<Opportunity> newOpps, Map<Id, Opportunity> oldOppsMap) {
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
        ];

        for (Opportunity opp : oppsWithDetails) {
            // Build the input for the OnboardingWorkflowExample
            Map<String, Object> input = new Map<String, Object>{
                'amount' => opp.Amount != null ? opp.Amount : 0.0,
                'customerName' => opp.Account != null ? opp.Account.Name : opp.Name,
                'email' => 'customer@' + (opp.Account != null ? opp.Account.Name.replaceAll('[^a-zA-Z0-9]', '').toLowerCase() : 'example') + '.com'
            };

            // Start the customer onboarding workflow
            WorkflowEngine.start(
                'OnboardingWorkflowExample', 
                'Opp_Onboarding_' + opp.Id, 
                input
            );
        }
    }
}
