trigger WorkflowEventTrigger on Workflow_Event__e (after insert) {
    for (Workflow_Event__e event : Trigger.new) {
        if (event.Event_Type__c == 'RESUME') {
            // Correlation Key can be stored in the event payload or as a field.
            // Let's support resuming by Instance ID directly or Correlation Key.
            // If the Instance ID is provided, we can look up the instance or resume directly.
            // Let's write a helper to resume by Instance ID.
            
            // To be flexible: if Workflow_Instance_Id__c is a valid Salesforce ID, we can resume by ID.
            // Otherwise, we can treat it as a correlation key.
            try {
                Id instanceId = (Id)event.Workflow_Instance_Id__c;
                // If it is an ID, resume by query on ID
                List<Workflow_Instance__c> instances = [
                    SELECT Correlation_Key__c FROM Workflow_Instance__c 
                    WHERE Id = :instanceId
                    LIMIT 1
                ];
                if (!instances.isEmpty() && String.isNotBlank(instances[0].Correlation_Key__c)) {
                    WorkflowEngine.resume(instances[0].Correlation_Key__c, event.Payload__c);
                }
            } catch (Exception ex) {
                // If it's not a valid ID, treat it as correlation key directly
                WorkflowEngine.resume(event.Workflow_Instance_Id__c, event.Payload__c);
            }
            
        } else if (event.Event_Type__c != null && event.Event_Type__c.startsWith('SIGNAL:')) {
            String signalName = event.Event_Type__c.substringAfter('SIGNAL:');
            String correlationKey = event.Workflow_Instance_Id__c;
            try {
                Id instanceId = (Id)event.Workflow_Instance_Id__c;
                List<Workflow_Instance__c> instances = [
                    SELECT Correlation_Key__c FROM Workflow_Instance__c 
                    WHERE Id = :instanceId
                    LIMIT 1
                ];
                if (!instances.isEmpty() && String.isNotBlank(instances[0].Correlation_Key__c)) {
                    correlationKey = instances[0].Correlation_Key__c;
                }
            } catch (Exception ex) {
                // Not an ID, treat as correlation key
            }
            WorkflowEngine.signal(correlationKey, signalName, event.Payload__c);
            
        } else if (event.Event_Type__c == 'RUN_STEP' || event.Event_Type__c == 'NEXT_STEP') {
            if (Limits.getQueueableJobs() < Limits.getLimitQueueableJobs()) {
                System.enqueueJob(new WorkflowOrchestrator(event.Workflow_Instance_Id__c, event.Payload__c));
            } else {
                // Throttle: If Queueable limit is reached in this transaction batch, 
                // republish the event to be processed in a new trigger context.
                WorkflowEngine.enqueueOrchestrator(event.Workflow_Instance_Id__c, event.Payload__c);
            }
        }
    }
}
