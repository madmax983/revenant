@isTest
public class CaseDebounceTriggerHandlerTest {
  @isTest
  static void testCaseTriggerDebounce() {
    WorkflowEngine.disableQueueableInTest = true;
    WorkflowEngine.mockNow = Datetime.now();

    // Create a Case
    Case c = new Case(
      Subject = 'Initial Subject',
      Description = 'Initial Description'
    );
    insert c;

    // Verify no workflow instance started
    String correlationKey = 'Case_Debounce_' + c.Id;
    System.assertEquals(
      0,
      [
        SELECT COUNT()
        FROM Workflow_Instance__c
        WHERE Correlation_Key__c = :correlationKey
      ]
    );

    // Update case multiple times to simulate bursty edits
    Test.startTest();
    c.Subject = 'Edit 1';
    update c;

    c.Subject = 'Edit 2';
    update c;

    c.Subject = 'Final Edit';
    update c;
    Test.stopTest();

    // Verify exactly one Debounce_State__c record exists with the latest input
    List<Debounce_State__c> states = [
      SELECT Id, Input_Json__c, Fire_At__c
      FROM Debounce_State__c
      WHERE Correlation_Key__c = :correlationKey
    ];
    System.assertEquals(1, states.size());
    Map<String, Object> payload = (Map<String, Object>) JSON.deserializeUntyped(
      states[0].Input_Json__c
    );
    System.assertEquals('Final Edit', (String) payload.get('subject'));

    // Advance time and sweep watchdog
    WorkflowEngine.mockNow = WorkflowEngine.mockNow.addSeconds(6);
    WorkflowEngine.processWatchdogHeartbeat();

    // Verify exactly 1 workflow instance has started
    List<Workflow_Instance__c> instances = [
      SELECT Id, Input__c
      FROM Workflow_Instance__c
      WHERE Correlation_Key__c = :correlationKey
    ];
    System.assertEquals(1, instances.size());
    Map<String, Object> instPayload = (Map<String, Object>) JSON.deserializeUntyped(
      instances[0].Input__c
    );
    System.assertEquals('Final Edit', (String) instPayload.get('subject'));
  }
}
