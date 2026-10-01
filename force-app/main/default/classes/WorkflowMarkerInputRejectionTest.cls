@IsTest
public class WorkflowMarkerInputRejectionTest {
  private static final String MARKER = '{"$attachmentId":"069000000000001AAA"}';
  private static final String WORKFLOW = 'WorkflowEngineTest.HappyWorkflow';

  private static Workflow_Instance__c suspended(String key) {
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = WORKFLOW,
      Status__c = 'Suspended',
      Correlation_Key__c = key,
      Input__c = '"x"'
    );
    insert inst;
    return inst;
  }

  private static void assertMarkerError(Exception ex) {
    Assert.isNotNull(ex, 'The call must throw.');
    Assert.isTrue(
      ex.getMessage().contains('offload marker'),
      'Wrong message: ' + ex.getMessage()
    );
  }

  private static void assertNoRows(Integer instances, String why) {
    Assert.areEqual(
      instances,
      [SELECT COUNT() FROM Workflow_Instance__c],
      why + ': no instance row'
    );
    Assert.areEqual(
      0,
      [SELECT COUNT() FROM Workflow_Signal__c],
      why + ': no signal row'
    );
  }

  @IsTest
  static void startRejectsMarkerInputJson() {
    WorkflowEngine.StartRequest req = new WorkflowEngine.StartRequest(
      WORKFLOW,
      'MarkerStart1',
      null
    );
    req.inputJson = MARKER;
    Exception caught;
    try {
      WorkflowEngine.start(req);
    } catch (WorkflowEngine.WorkflowException ex) {
      caught = ex;
    }
    assertMarkerError(caught);
    assertNoRows(0, 'start');
  }

  @IsTest
  static void startRejectsMarkerShapedMapInput() {
    Exception caught;
    try {
      WorkflowEngine.start(
        WORKFLOW,
        'MarkerStart2',
        new Map<String, Object>{ '$attachmentId' => '069000000000001AAA' }
      );
    } catch (WorkflowEngine.WorkflowException ex) {
      caught = ex;
    }
    assertMarkerError(caught);
    assertNoRows(0, 'start map');
  }

  @IsTest
  static void startRejectsTypedMapMarkerInput() {
    Exception caught;
    try {
      WorkflowEngine.start(
        WORKFLOW,
        'MarkerStartTyped',
        new Map<String, Id>{ '$attachmentId' => UserInfo.getUserId() }
      );
    } catch (WorkflowEngine.WorkflowException ex) {
      caught = ex;
    }
    assertMarkerError(caught);
    assertNoRows(0, 'start typed map');
  }

  @IsTest
  static void startOrGetRejectsMarkerInputJson() {
    WorkflowEngine.StartRequest req = new WorkflowEngine.StartRequest(
      WORKFLOW,
      'MarkerStart3',
      null
    );
    req.inputJson = MARKER;
    Exception caught;
    try {
      WorkflowEngine.startOrGet(req);
    } catch (WorkflowEngine.WorkflowException ex) {
      caught = ex;
    }
    assertMarkerError(caught);
    assertNoRows(0, 'startOrGet');
  }

  @IsTest
  static void bulkStartRejectsMarkerInputJson() {
    WorkflowEngine.StartRequest good = new WorkflowEngine.StartRequest(
      WORKFLOW,
      'MarkerBulkGood',
      null
    );
    WorkflowEngine.StartRequest bad = new WorkflowEngine.StartRequest(
      WORKFLOW,
      'MarkerBulkBad',
      null
    );
    bad.inputJson = MARKER;
    Exception caught;
    try {
      WorkflowEngine.startOrGet(
        new List<WorkflowEngine.StartRequest>{ good, bad }
      );
    } catch (WorkflowEngine.WorkflowException ex) {
      caught = ex;
    }
    assertMarkerError(caught);
    assertNoRows(0, 'bulk start');
  }

  @IsTest
  static void signalRejectsMarkerPayload() {
    Workflow_Instance__c inst = suspended('MarkerSignal1');
    Exception caught;
    try {
      WorkflowEngine.signal(inst.Correlation_Key__c, 'Go', MARKER);
    } catch (WorkflowEngine.WorkflowException ex) {
      caught = ex;
    }
    assertMarkerError(caught);
    assertNoRows(1, 'signal');
  }

  @IsTest
  static void signalRequestRejectsMarkerPayload() {
    Workflow_Instance__c inst = suspended('MarkerSignal2');
    Exception caught;
    try {
      WorkflowEngine.signal(
        new WorkflowEngine.SignalRequest(inst.Correlation_Key__c, 'Go', MARKER)
      );
    } catch (WorkflowEngine.WorkflowException ex) {
      caught = ex;
    }
    assertMarkerError(caught);
    assertNoRows(1, 'signal request');
  }

  @IsTest
  static void bulkSignalRejectsMarkerPayload() {
    Workflow_Instance__c inst = suspended('MarkerSignal3');
    Exception caught;
    try {
      WorkflowEngine.signal(
        new List<WorkflowEngine.SignalRequest>{
          new WorkflowEngine.SignalRequest(inst.Correlation_Key__c, 'Go', '{}'),
          new WorkflowEngine.SignalRequest(
            inst.Correlation_Key__c,
            'Go',
            MARKER
          )
        }
      );
    } catch (WorkflowEngine.WorkflowException ex) {
      caught = ex;
    }
    assertMarkerError(caught);
    assertNoRows(1, 'bulk signal');
  }

  @IsTest
  static void signalOrStartRejectsMarkerSignalPayload() {
    Exception caught;
    try {
      WorkflowEngine.signalOrStart(
        new WorkflowEngine.SignalOrStartRequest(
          new WorkflowEngine.StartRequest(WORKFLOW, 'MarkerSos1', null),
          'Go',
          MARKER
        )
      );
    } catch (WorkflowEngine.WorkflowException ex) {
      caught = ex;
    }
    assertMarkerError(caught);
    assertNoRows(0, 'signalOrStart payload');
  }

  @IsTest
  static void signalOrStartRejectsMarkerInput() {
    WorkflowEngine.StartRequest start = new WorkflowEngine.StartRequest(
      WORKFLOW,
      'MarkerSos2',
      null
    );
    start.inputJson = MARKER;
    Exception caught;
    try {
      WorkflowEngine.signalOrStart(
        new WorkflowEngine.SignalOrStartRequest(start, 'Go', '{}')
      );
    } catch (WorkflowEngine.WorkflowException ex) {
      caught = ex;
    }
    assertMarkerError(caught);
    assertNoRows(0, 'signalOrStart input');
  }

  @IsTest
  static void resumeRejectsMarkerPayload() {
    Workflow_Instance__c inst = suspended('MarkerResume1');
    Exception caught;
    try {
      WorkflowResumeService.resume(inst.Correlation_Key__c, MARKER);
    } catch (WorkflowEngine.WorkflowException ex) {
      caught = ex;
    }
    assertMarkerError(caught);
    Assert.areEqual(
      'Suspended',
      [SELECT Status__c FROM Workflow_Instance__c WHERE Id = :inst.Id].Status__c
    );
  }

  @IsTest
  static void resumeInstanceRejectsMarkerPayload() {
    Workflow_Instance__c inst = suspended('MarkerResume2');
    Exception caught;
    try {
      WorkflowResumeService.resumeInstance(inst.Id, MARKER);
    } catch (WorkflowEngine.WorkflowException ex) {
      caught = ex;
    }
    assertMarkerError(caught);
    Assert.areEqual(
      'Suspended',
      [SELECT Status__c FROM Workflow_Instance__c WHERE Id = :inst.Id].Status__c
    );
  }

  @IsTest
  static void bulkResumeRejectsMarkerPayload() {
    Workflow_Instance__c inst = suspended('MarkerResume3');
    Exception caught;
    try {
      WorkflowBulkResumeService.resume(
        new List<WorkflowEngine.ResumeRequest>{
          new WorkflowEngine.ResumeRequest(inst.Correlation_Key__c, MARKER)
        }
      );
    } catch (WorkflowEngine.WorkflowException ex) {
      caught = ex;
    }
    assertMarkerError(caught);
    Assert.areEqual(
      'Suspended',
      [SELECT Status__c FROM Workflow_Instance__c WHERE Id = :inst.Id].Status__c
    );
  }

  @IsTest
  static void startInvocableRejectsMarkerInput() {
    WorkflowStartInvocableAction.StartRequest req = new WorkflowStartInvocableAction.StartRequest();
    req.workflowName = WORKFLOW;
    req.correlationKey = 'MarkerInvStart';
    req.inputJson = MARKER;
    Exception caught;
    try {
      WorkflowStartInvocableAction.startWorkflow(
        new List<WorkflowStartInvocableAction.StartRequest>{ req }
      );
    } catch (WorkflowEngine.WorkflowException ex) {
      caught = ex;
    }
    assertMarkerError(caught);
    assertNoRows(0, 'start invocable');
  }

  @IsTest
  static void debouncedStartInvocableRejectsMarkerInput() {
    WorkflowStartInvocableAction.StartRequest req = new WorkflowStartInvocableAction.StartRequest();
    req.workflowName = WORKFLOW;
    req.correlationKey = 'MarkerInvDebounce';
    req.inputJson = MARKER;
    req.debounceSeconds = 30;
    Exception caught;
    try {
      WorkflowStartInvocableAction.startWorkflow(
        new List<WorkflowStartInvocableAction.StartRequest>{ req }
      );
    } catch (WorkflowEngine.WorkflowException ex) {
      caught = ex;
    }
    assertMarkerError(caught);
    Assert.areEqual(0, [SELECT COUNT() FROM Debounce_State__c]);
  }

  @IsTest
  static void signalInvocableRejectsMarkerPayload() {
    Workflow_Instance__c inst = suspended('MarkerInvSignal');
    WorkflowSignalInvocableAction.SignalRequest req = new WorkflowSignalInvocableAction.SignalRequest();
    req.targetKey = inst.Correlation_Key__c;
    req.signalName = 'Go';
    req.payloadJson = MARKER;
    Exception caught;
    try {
      WorkflowSignalInvocableAction.signalWorkflow(
        new List<WorkflowSignalInvocableAction.SignalRequest>{ req }
      );
    } catch (WorkflowEngine.WorkflowException ex) {
      caught = ex;
    }
    assertMarkerError(caught);
    assertNoRows(1, 'signal invocable');
  }

  @IsTest
  static void signalOrStartInvocableRejectsMarkerPayload() {
    WorkflowSignalOrStartInvocableAction.SignalOrStartRequest req = new WorkflowSignalOrStartInvocableAction.SignalOrStartRequest();
    req.workflowName = WORKFLOW;
    req.correlationKey = 'MarkerInvSos';
    req.signalName = 'Go';
    req.payloadJson = MARKER;
    Exception caught;
    try {
      WorkflowSignalOrStartInvocableAction.signalOrStartWorkflow(
        new List<WorkflowSignalOrStartInvocableAction.SignalOrStartRequest>{
          req
        }
      );
    } catch (WorkflowEngine.WorkflowException ex) {
      caught = ex;
    }
    assertMarkerError(caught);
    assertNoRows(0, 'signalOrStart invocable');
  }

  @IsTest
  static void dashboardStartRejectsMarkerInput() {
    Exception caught;
    try {
      WorkflowDashboardCommandController.startWorkflow(
        WORKFLOW,
        'MarkerDashStart',
        MARKER
      );
    } catch (AuraHandledException ex) {
      caught = ex;
    }
    assertMarkerError(caught);
    assertNoRows(0, 'dashboard start');
  }

  @IsTest
  static void dashboardInjectRejectsMarkerPayload() {
    Workflow_Instance__c inst = suspended('MarkerDashInject');
    Exception caught;
    try {
      WorkflowDashboardCommandController.injectSignal(inst.Id, 'Go', MARKER);
    } catch (AuraHandledException ex) {
      caught = ex;
    }
    assertMarkerError(caught);
    assertNoRows(1, 'dashboard inject');
  }

  @IsTest
  static void eventPathStillDeliversMarkerSignalPayload() {
    Workflow_Instance__c inst = suspended('MarkerEventSignal');
    WorkflowEngine.disableQueueableInTest = true;
    Test.startTest();
    new WorkflowEventTriggerHandler(
        new List<Workflow_Event__e>{
          new Workflow_Event__e(
            Workflow_Instance_Id__c = inst.Correlation_Key__c,
            Event_Type__c = 'SIGNAL:ChildCompleted',
            Payload__c = MARKER
          )
        }
      )
      .handleAfterInsert();
    Test.stopTest();
    List<Workflow_Signal__c> signals = [
      SELECT Payload__c
      FROM Workflow_Signal__c
      WHERE Workflow_Instance__c = :inst.Id
    ];
    Assert.areEqual(1, signals.size(), 'The event path must store the signal.');
    Assert.isTrue(signals[0].Payload__c.startsWith('{"$attachmentId":'));
  }

  @IsTest
  static void eventPathStillResumesWithMarkerPayload() {
    Workflow_Instance__c inst = suspended('MarkerEventResume');
    WorkflowEngine.disableQueueableInTest = true;
    Test.startTest();
    new WorkflowEventTriggerHandler(
        new List<Workflow_Event__e>{
          new Workflow_Event__e(
            Workflow_Instance_Id__c = String.valueOf(inst.Id),
            Event_Type__c = 'RESUME',
            Payload__c = MARKER
          )
        }
      )
      .handleAfterInsert();
    Test.stopTest();
    Assert.areNotEqual(
      'Suspended',
      [SELECT Status__c FROM Workflow_Instance__c WHERE Id = :inst.Id]
      .Status__c,
      'The event path must resume the instance.'
    );
  }
}
