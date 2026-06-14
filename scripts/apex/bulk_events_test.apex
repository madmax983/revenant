// 1. Clean up old test data
System.debug('Cleaning up old test data...');
delete [SELECT Id FROM Workflow_Instance__c WHERE Correlation_Key__c LIKE 'ResumeScale_%'];

// 2. Create 40 suspended instances using a main-codebase class to avoid non-test context errors
System.debug('Creating 40 suspended instances...');
List<Workflow_Instance__c> instances = new List<Workflow_Instance__c>();
for (Integer i = 0; i < 40; i++) {
    instances.add(new Workflow_Instance__c(
        Workflow_Name__c = 'CleanupWorkflow',
        Status__c = 'Suspended',
        Correlation_Key__c = 'ResumeScale_' + i,
        Current_Step__c = 'CleanupWorkflow.PurgeOldInstancesStep'
    ));
}
insert instances;

// Insert step executions for them
List<Workflow_Step_Execution__c> stepExecs = new List<Workflow_Step_Execution__c>();
for (Workflow_Instance__c inst : instances) {
    stepExecs.add(new Workflow_Step_Execution__c(
        Workflow_Instance__c = inst.Id,
        Step_Name__c = 'CleanupWorkflow.PurgeOldInstancesStep',
        Status__c = 'Pending',
        Retry_Count__c = 0
    ));
}
insert stepExecs;

// 3. Publish 40 RESUME events at once
List<Workflow_Event__e> events = new List<Workflow_Event__e>();
for (Integer i = 0; i < 40; i++) {
    events.add(new Workflow_Event__e(
        Workflow_Instance_Id__c = 'ResumeScale_' + i,
        Event_Type__c = 'RESUME',
        Payload__c = null
    ));
}

System.debug('Publishing 40 RESUME platform events...');
EventBus.publish(events);
System.debug('Transaction complete. Events published.');
