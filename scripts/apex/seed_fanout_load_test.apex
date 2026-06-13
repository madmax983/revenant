// Clean up old workflow instances and signals
System.debug('Cleaning up existing workflow data...');
delete [SELECT Id FROM Workflow_Instance__c];
delete [SELECT Id FROM Workflow_Signal__c];

// Clean up old test accounts from previous runs
System.debug('Cleaning up old test accounts...');
delete [SELECT Id FROM Account WHERE Name LIKE 'FanoutTest_Account_%'];

// Seed 60 actual Accounts to trigger a large fan-out batch
Integer accountsToCreate = 60;
System.debug('Seeding ' + accountsToCreate + ' Accounts in the database...');
List<Account> accounts = new List<Account>();
for (Integer i = 0; i < accountsToCreate; i++) {
    accounts.add(new Account(
        Name = 'FanoutTest_Account_' + i,
        Phone = '555-010' + i
    ));
}
insert accounts;
System.debug('Successfully seeded ' + accounts.size() + ' Accounts.');

// Start the parent BatchFanoutWorkflow
System.debug('Kicking off the parent BatchFanoutWorkflow...');
Id parentInstanceId = WorkflowEngine.start(
    'BatchFanoutWorkflowExample.BatchFanoutWorkflow',
    'ParentFanout_LoadTest',
    null
);

System.debug('Parent workflow started successfully. Instance ID: ' + parentInstanceId);
System.debug('Wait 15-20 seconds for the asynchronous fan-out trigger and child jobs to finish,');
System.debug('then run the verification script to check updated accounts and workflow status.');
