trigger OpportunityTrigger on Opportunity(after update) {
  OpportunityTriggerHandler.run();
}
