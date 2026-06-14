trigger WorkflowEventTrigger on Workflow_Event__e (after insert) {
    Pattern idPattern = Pattern.compile('^[a-zA-Z0-9]{15}([a-zA-Z0-9]{3})?$');

    // 1. Gather all potential Salesforce IDs from incoming events to query in bulk
    Set<Id> instanceIds = new Set<Id>();
    for (Workflow_Event__e event : Trigger.new) {
        if (String.isNotBlank(event.Workflow_Instance_Id__c) && idPattern.matcher(event.Workflow_Instance_Id__c).matches()) {
            instanceIds.add((Id) event.Workflow_Instance_Id__c);
        }
    }

    Map<Id, Workflow_Instance__c> instancesById = new Map<Id, Workflow_Instance__c>();
    if (!instanceIds.isEmpty()) {
        instancesById = new Map<Id, Workflow_Instance__c>([
            SELECT Id, Correlation_Key__c 
            FROM Workflow_Instance__c 
            WHERE Id IN :instanceIds
            WITH SYSTEM_MODE
        ]);
    }

    List<Workflow_Event__e> throttledEvents = new List<Workflow_Event__e>();

    // 2. Process events in the batch
    for (Workflow_Event__e event : Trigger.new) {
        if (event.Event_Type__c == 'RESUME') {
            String resumeKey = null;
            Boolean isId = false;
            
            if (String.isNotBlank(event.Workflow_Instance_Id__c) && idPattern.matcher(event.Workflow_Instance_Id__c).matches()) {
                isId = true;
                Id instanceId = (Id) event.Workflow_Instance_Id__c;
                if (instancesById.containsKey(instanceId)) {
                    Workflow_Instance__c inst = instancesById.get(instanceId);
                    if (String.isNotBlank(inst.Correlation_Key__c)) {
                        resumeKey = inst.Correlation_Key__c;
                    }
                }
            } else {
                resumeKey = event.Workflow_Instance_Id__c;
            }
            
            if (isId) {
                if (String.isNotBlank(resumeKey)) {
                    WorkflowEngine.resume(resumeKey, event.Payload__c);
                }
            } else {
                WorkflowEngine.resume(resumeKey, event.Payload__c);
            }
            
        } else if (event.Event_Type__c != null && event.Event_Type__c.startsWith('SIGNAL:')) {
            String signalName = event.Event_Type__c.substringAfter('SIGNAL:');
            String correlationKey = event.Workflow_Instance_Id__c;
            
            if (String.isNotBlank(event.Workflow_Instance_Id__c) && idPattern.matcher(event.Workflow_Instance_Id__c).matches()) {
                Id instanceId = (Id) event.Workflow_Instance_Id__c;
                if (instancesById.containsKey(instanceId)) {
                    Workflow_Instance__c inst = instancesById.get(instanceId);
                    if (String.isNotBlank(inst.Correlation_Key__c)) {
                        correlationKey = inst.Correlation_Key__c;
                    }
                }
            }
            WorkflowEngine.signal(correlationKey, signalName, event.Payload__c);
            
        } else if (event.Event_Type__c == 'RUN_STEP' || event.Event_Type__c == 'NEXT_STEP') {
            try {
                if (Limits.getQueueableJobs() < Limits.getLimitQueueableJobs()) {
                    System.enqueueJob(new WorkflowOrchestrator(event.Workflow_Instance_Id__c, event.Payload__c));
                } else {
                    // Accumulate throttled events to republish in bulk
                    throttledEvents.add(new Workflow_Event__e(
                        Workflow_Instance_Id__c = event.Workflow_Instance_Id__c,
                        Event_Type__c = 'RUN_STEP',
                        Payload__c = event.Payload__c
                    ));
                }
            } catch (Exception ex) {
                throttledEvents.add(new Workflow_Event__e(
                    Workflow_Instance_Id__c = event.Workflow_Instance_Id__c,
                    Event_Type__c = 'RUN_STEP',
                    Payload__c = event.Payload__c
                ));
            }
        }
    }

    // 3. Publish throttled events in a single bulk DML statement
    if (!throttledEvents.isEmpty()) {
        List<Database.SaveResult> srs = EventBus.publish(throttledEvents);
        for (Database.SaveResult sr : srs) {
            if (!sr.isSuccess()) {
                List<String> errMsgs = new List<String>();
                for (Database.Error err : sr.getErrors()) {
                    errMsgs.add(err.getStatusCode() + ': ' + err.getMessage());
                }
                throw new WorkflowEngine.WorkflowException(
                    'Failed to publish orchestrator event: ' + String.join(errMsgs, ', ')
                );
            }
        }
    }
}
