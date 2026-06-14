trigger WorkflowInstanceTrigger on Workflow_Instance__c (before insert, before update) {
    for (Workflow_Instance__c instance : Trigger.new) {
        if (instance.Status__c == 'Pending' || instance.Status__c == 'Running' || instance.Status__c == 'Suspended' || instance.Status__c == 'Compensating' || instance.Status__c == 'Cancelling') {
            instance.Active_Correlation_Key__c = instance.Correlation_Key__c;
        } else {
            instance.Active_Correlation_Key__c = null;
        }
    }
}
