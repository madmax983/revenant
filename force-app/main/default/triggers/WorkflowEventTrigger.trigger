trigger WorkflowEventTrigger on Workflow_Event__e(after insert) {
  Pattern idPattern = Pattern.compile('^[a-zA-Z0-9]{15}([a-zA-Z0-9]{3})?$');

  List<WorkflowEngine.ResumeRequest> resumeRequests = new List<WorkflowEngine.ResumeRequest>();
  List<WorkflowEngine.SignalRequest> signalRequests = new List<WorkflowEngine.SignalRequest>();
  List<Workflow_Event__e> throttledEvents = new List<Workflow_Event__e>();

  Integer processedResumeSignals = 0;
  Integer maxResumeSignals = 20;

  // 1. Process events in the batch
  for (Workflow_Event__e event : Trigger.new) {
    if (event.Event_Type__c == 'RESUME') {
      if (processedResumeSignals < maxResumeSignals) {
        processedResumeSignals++;
        if (
          String.isNotBlank(event.Workflow_Instance_Id__c) &&
          idPattern.matcher(event.Workflow_Instance_Id__c).matches()
        ) {
          resumeRequests.add(
            new WorkflowEngine.ResumeRequest(
              (Id) event.Workflow_Instance_Id__c,
              event.Payload__c
            )
          );
        } else {
          resumeRequests.add(
            new WorkflowEngine.ResumeRequest(
              event.Workflow_Instance_Id__c,
              event.Payload__c
            )
          );
        }
      } else {
        throttledEvents.add(
          new Workflow_Event__e(
            Workflow_Instance_Id__c = event.Workflow_Instance_Id__c,
            Event_Type__c = event.Event_Type__c,
            Payload__c = event.Payload__c
          )
        );
      }
    } else if (
      event.Event_Type__c != null && event.Event_Type__c.startsWith('SIGNAL:')
    ) {
      if (processedResumeSignals < maxResumeSignals) {
        processedResumeSignals++;
        String signalName = event.Event_Type__c.substringAfter('SIGNAL:');
        signalRequests.add(
          new WorkflowEngine.SignalRequest(
            event.Workflow_Instance_Id__c,
            signalName,
            event.Payload__c
          )
        );
      } else {
        throttledEvents.add(
          new Workflow_Event__e(
            Workflow_Instance_Id__c = event.Workflow_Instance_Id__c,
            Event_Type__c = event.Event_Type__c,
            Payload__c = event.Payload__c
          )
        );
      }
    } else if (
      event.Event_Type__c == 'RUN_STEP' ||
      event.Event_Type__c == 'NEXT_STEP'
    ) {
      try {
        if (Limits.getQueueableJobs() < Limits.getLimitQueueableJobs()) {
          System.enqueueJob(
            new WorkflowOrchestrator(
              event.Workflow_Instance_Id__c,
              event.Payload__c
            )
          );
        } else {
          // Accumulate throttled events to republish in bulk
          throttledEvents.add(
            new Workflow_Event__e(
              Workflow_Instance_Id__c = event.Workflow_Instance_Id__c,
              Event_Type__c = 'RUN_STEP',
              Payload__c = event.Payload__c
            )
          );
        }
      } catch (Exception ex) {
        throttledEvents.add(
          new Workflow_Event__e(
            Workflow_Instance_Id__c = event.Workflow_Instance_Id__c,
            Event_Type__c = 'RUN_STEP',
            Payload__c = event.Payload__c
          )
        );
      }
    }
  }

  // 2. Execute bulk resume and signal requests
  if (!resumeRequests.isEmpty()) {
    WorkflowEngine.resume(resumeRequests);
  }
  if (!signalRequests.isEmpty()) {
    WorkflowEngine.signal(signalRequests);
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
