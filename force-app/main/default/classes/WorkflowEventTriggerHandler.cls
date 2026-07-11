/**
 * Handler for WorkflowEventTrigger. All Workflow_Event__e after-insert logic lives
 * here so the trigger itself stays a thin delegate (AvoidLogicInTrigger). Behavior is
 * identical to the original in-trigger implementation: events are classified in-order,
 * resume/signal requests are executed in bulk, and any throttled overflow is republished
 * in a single EventBus.publish call.
 *
 * Sharing: inherited sharing. Triggers execute in system context; a handler with
 * inherited sharing runs with the sharing of its caller (the trigger, i.e. system) and
 * imposes no additional record-level restriction, preserving the original behavior.
 */
public inherited sharing class WorkflowEventTriggerHandler {
  private static final Pattern ID_PATTERN = Pattern.compile(
    '^[a-zA-Z0-9]{15}([a-zA-Z0-9]{3})?$'
  );
  private static final Integer MAX_RESUME_SIGNALS = 20;

  private final List<Workflow_Event__e> events;
  private final List<WorkflowEngine.ResumeRequest> resumeRequests = new List<WorkflowEngine.ResumeRequest>();
  private final List<WorkflowEngine.SignalRequest> signalRequests = new List<WorkflowEngine.SignalRequest>();
  private final List<Workflow_Event__e> throttledEvents = new List<Workflow_Event__e>();
  private Integer processedResumeSignals = 0;

  public WorkflowEventTriggerHandler(List<Workflow_Event__e> events) {
    this.events = events;
  }

  public void handleAfterInsert() {
    // 1. Process events in the batch
    for (Workflow_Event__e event : events) {
      routeEvent(event);
    }

    // 2. Execute bulk resume and signal requests
    dispatchRequests();

    // 3. Publish throttled events in a single bulk DML statement
    publishThrottledEvents();
  }

  private void routeEvent(Workflow_Event__e event) {
    if (event.Event_Type__c == 'RESUME') {
      routeResume(event);
    } else if (
      event.Event_Type__c != null && event.Event_Type__c.startsWith('SIGNAL:')
    ) {
      routeSignal(event);
    } else if (
      event.Event_Type__c == 'RUN_STEP' ||
      event.Event_Type__c == 'NEXT_STEP'
    ) {
      routeStepExecution(event);
    }
  }

  private void routeResume(Workflow_Event__e event) {
    if (processedResumeSignals >= MAX_RESUME_SIGNALS) {
      throttledEvents.add(
        new Workflow_Event__e(
          Workflow_Instance_Id__c = event.Workflow_Instance_Id__c,
          Event_Type__c = event.Event_Type__c,
          Payload__c = event.Payload__c
        )
      );
      return;
    }
    processedResumeSignals++;
    resumeRequests.add(buildResumeRequest(event));
  }

  private WorkflowEngine.ResumeRequest buildResumeRequest(
    Workflow_Event__e event
  ) {
    if (
      String.isNotBlank(event.Workflow_Instance_Id__c) &&
      ID_PATTERN.matcher(event.Workflow_Instance_Id__c).matches()
    ) {
      return new WorkflowEngine.ResumeRequest(
        (Id) event.Workflow_Instance_Id__c,
        event.Payload__c
      );
    }
    return new WorkflowEngine.ResumeRequest(
      event.Workflow_Instance_Id__c,
      event.Payload__c
    );
  }

  private void routeSignal(Workflow_Event__e event) {
    if (processedResumeSignals >= MAX_RESUME_SIGNALS) {
      throttledEvents.add(
        new Workflow_Event__e(
          Workflow_Instance_Id__c = event.Workflow_Instance_Id__c,
          Event_Type__c = event.Event_Type__c,
          Payload__c = event.Payload__c,
          Idempotency_Key__c = event.Idempotency_Key__c
        )
      );
      return;
    }
    processedResumeSignals++;
    String signalName = event.Event_Type__c.substringAfter('SIGNAL:');
    WorkflowEngine.SignalRequest sigReq = new WorkflowEngine.SignalRequest(
      event.Workflow_Instance_Id__c,
      signalName,
      event.Payload__c,
      event.EventUuid
    );
    sigReq.idempotencyKey = event.Idempotency_Key__c;
    signalRequests.add(sigReq);
  }

  private void routeStepExecution(Workflow_Event__e event) {
    try {
      if (Limits.getQueueableJobs() < Limits.getLimitQueueableJobs()) {
        enqueueOrchestrator(event);
      } else {
        // Accumulate throttled events to republish in bulk
        throttledEvents.add(buildThrottledStepEvent(event));
      }
    } catch (Exception ex) {
      throttledEvents.add(buildThrottledStepEvent(event));
    }
  }

  private void enqueueOrchestrator(Workflow_Event__e event) {
    System.enqueueJob(
      new WorkflowOrchestrator(event.Workflow_Instance_Id__c, event.Payload__c)
    );
  }

  private Workflow_Event__e buildThrottledStepEvent(Workflow_Event__e event) {
    return new Workflow_Event__e(
      Workflow_Instance_Id__c = event.Workflow_Instance_Id__c,
      Event_Type__c = 'RUN_STEP',
      Payload__c = event.Payload__c
    );
  }

  private void dispatchRequests() {
    if (!resumeRequests.isEmpty()) {
      WorkflowEngine.resume(resumeRequests);
    }
    if (!signalRequests.isEmpty()) {
      WorkflowEngine.signal(signalRequests);
    }
  }

  private void publishThrottledEvents() {
    if (throttledEvents.isEmpty()) {
      return;
    }
    List<Database.SaveResult> srs = EventBus.publish(throttledEvents);
    for (Database.SaveResult sr : srs) {
      if (!sr.isSuccess()) {
        throw new WorkflowEngine.WorkflowException(
          'Failed to publish orchestrator event: ' + collectErrors(sr)
        );
      }
    }
  }

  private String collectErrors(Database.SaveResult sr) {
    List<String> errMsgs = new List<String>();
    for (Database.Error err : sr.getErrors()) {
      errMsgs.add(err.getStatusCode() + ': ' + err.getMessage());
    }
    return String.join(errMsgs, ', ');
  }
}
