// Clear old instances and logs to start fresh
System.debug('Cleaning up existing workflow data...');
delete [SELECT Id FROM Workflow_Instance__c];
delete [SELECT Id FROM Workflow_Signal__c];

// Define target batch size (70)
// Staying below 150 DML statements (each start executes 2 DMLs: 1 insert + 1 EventBus.publish)
// while exceeding the 50 Queueable limit to test the trigger queueable throttling.
Integer batchSize = 70;
System.debug('Starting ' + batchSize + ' SagaWorkflow instances concurrently...');

// Start workflows in a loop.
for (Integer i = 0; i < batchSize; i++) {
    WorkflowEngine.start(
        'SagaWorkflowExample.SagaWorkflow', 
        'SagaLoadTest_' + i, 
        new Map<String, Object>{ 'email' => 'loadtest_' + i + '@example.com' }
    );
}

System.debug('Successfully initiated ' + batchSize + ' workflows.');
System.debug('All platform events published. Salesforce will process them asynchronously.');
System.debug('DML statements consumed: ' + Limits.getDmlStatements());
System.debug('Queueable jobs added in this transaction: ' + Limits.getQueueableJobs());
System.debug('Wait 10-15 seconds and then query Workflow_Instance__c to monitor progress.');
