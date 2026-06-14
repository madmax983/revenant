@isTest
public class OpportunityTriggerHandlerTest {
  @isTest
  static void testOpportunityOnboardingTrigger() {
    // Create parent Account
    Account acc = new Account(Name = 'Test Account');
    insert acc;

    // Create Opportunity in 'Prospecting' stage
    Opportunity opp = new Opportunity(
      Name = 'Onboarding Test Opp',
      AccountId = acc.Id,
      StageName = 'Prospecting',
      CloseDate = Date.today().addDays(30),
      Amount = 25000.00
    );
    insert opp;

    // Verify no workflow instance has been created yet
    String correlationKey = 'Opp_Onboarding_' + opp.Id;
    List<Workflow_Instance__c> instances = [
      SELECT Id, Status__c, Input__c
      FROM Workflow_Instance__c
      WHERE Correlation_Key__c = :correlationKey
    ];
    System.assert(
      instances.isEmpty(),
      'No onboarding workflow should start on insert of Prospecting opportunity.'
    );

    // Update stage to 'Closed Won' to fire onboarding trigger
    Test.startTest();
    opp.StageName = 'Closed Won';
    update opp;
    Test.stopTest(); // Deliver asynchronous platform events/Queueables

    // Verify workflow instance was created
    instances = [
      SELECT Id, Status__c, Input__c
      FROM Workflow_Instance__c
      WHERE Correlation_Key__c = :correlationKey
    ];
    System.assertEquals(
      1,
      instances.size(),
      'One onboarding workflow instance should have started.'
    );

    Workflow_Instance__c inst = instances[0];
    System.assertEquals(
      'Running',
      inst.Status__c,
      'Workflow should be running.'
    );

    // Verify input JSON matches Opportunity details
    Map<String, Object> inputJsonMap = (Map<String, Object>) JSON.deserializeUntyped(
      inst.Input__c
    );
    System.assertEquals(
      25000.00,
      (Decimal) inputJsonMap.get('amount'),
      'Amount should match Opportunity.'
    );
    System.assertEquals(
      'Test Account',
      (String) inputJsonMap.get('customerName'),
      'Customer name should match Account Name.'
    );
    System.assertEquals(
      'customer@testaccount.com',
      (String) inputJsonMap.get('email'),
      'Email should be derived from Account name.'
    );
  }

  @isTest
  static void testNoOnboardingForNonClosedWonTransitions() {
    // Create parent Account
    Account acc = new Account(Name = 'Test Account 2');
    insert acc;

    // Create Opportunity
    Opportunity opp = new Opportunity(
      Name = 'Onboarding Test Opp 2',
      AccountId = acc.Id,
      StageName = 'Prospecting',
      CloseDate = Date.today().addDays(30),
      Amount = 15000.00
    );
    insert opp;

    // Transition from Prospecting to Qualification
    Test.startTest();
    opp.StageName = 'Qualification';
    update opp;
    Test.stopTest();

    // Verify no workflow instance was created
    String correlationKey = 'Opp_Onboarding_' + opp.Id;
    List<Workflow_Instance__c> instances = [
      SELECT Id
      FROM Workflow_Instance__c
      WHERE Correlation_Key__c = :correlationKey
    ];
    System.assert(
      instances.isEmpty(),
      'No onboarding workflow should start on non-Closed Won stage transition.'
    );
  }
}
