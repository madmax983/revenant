List<Workflow_Instance__c> instances = [
    SELECT Correlation_Key__c, Status__c, Current_Step__c 
    FROM Workflow_Instance__c 
    WHERE Correlation_Key__c LIKE 'ResumeScale_%'
    ORDER BY Correlation_Key__c ASC
];

Integer suspendedCount = 0;
Integer runningCount = 0;
Integer completedCount = 0;

for (Workflow_Instance__c inst : instances) {
    if (inst.Status__c == 'Suspended') {
        suspendedCount++;
    } else if (inst.Status__c == 'Running') {
        runningCount++;
    } else if (inst.Status__c == 'Completed') {
        completedCount++;
    }
}

System.debug('===========================================');
System.debug('Total Instances: ' + instances.size());
System.debug('Suspended: ' + suspendedCount + ' / 40');
System.debug('Running: ' + runningCount + ' / 40');
System.debug('Completed: ' + completedCount + ' / 40');
System.debug('===========================================');
