trigger WorkflowInstanceTrigger on Workflow_Instance__c(
  before insert,
  before update
) {
  for (Workflow_Instance__c instance : Trigger.new) {
    if (
      instance.Status__c == 'Pending' ||
      instance.Status__c == 'Running' ||
      instance.Status__c == 'Suspended' ||
      instance.Status__c == 'Compensating' ||
      instance.Status__c == 'Cancelling'
    ) {
      instance.Active_Correlation_Key__c = instance.Correlation_Key__c;
    } else {
      instance.Active_Correlation_Key__c = null;
    }

    // Track terminal state transition to record Terminal_At__c timestamp
    Boolean isTerminal = (instance.Status__c == 'Completed' ||
    instance.Status__c == 'Failed' ||
    instance.Status__c == 'Compensated' ||
    instance.Status__c == 'Cancelled' ||
    instance.Status__c == 'ContinuedAsNew');
    if (isTerminal) {
      if (Trigger.isInsert) {
        instance.Terminal_At__c = System.now();
      } else {
        Workflow_Instance__c oldInstance = Trigger.oldMap.get(instance.Id);
        Boolean wasTerminal = (oldInstance.Status__c == 'Completed' ||
        oldInstance.Status__c == 'Failed' ||
        oldInstance.Status__c == 'Compensated' ||
        oldInstance.Status__c == 'Cancelled' ||
        oldInstance.Status__c == 'ContinuedAsNew');
        if (!wasTerminal) {
          instance.Terminal_At__c = System.now();
        }
      }
    } else {
      instance.Terminal_At__c = null;
    }
  }
}
