@isTest
public class ChildWorkflowFanOutExampleTest {
  @isTest
  static void testDynamicFanOutAndRejoin() {
    List<Map<String, Object>> items = new List<Map<String, Object>>{
      new Map<String, Object>{ 'id' => 'itemA', 'value' => 15 },
      new Map<String, Object>{ 'id' => 'itemB', 'value' => 25 },
      new Map<String, Object>{ 'id' => 'itemC', 'value' => 5 }
    };

    Test.startTest();
    Id parentId = WorkflowEngine.start(
      'ChildWorkflowFanOutExample',
      'FanOutKey_' + Crypto.getRandomInteger(),
      items
    );
    WorkflowTestHarness harness = new WorkflowTestHarness(parentId);
    WorkflowTestHarness.Result result = harness.drive();
    Test.stopTest();

    System.assertEquals('Completed', result.status);

    Workflow_Instance__c parentInst = [
      SELECT Output__c
      FROM Workflow_Instance__c
      WHERE Id = :parentId
    ];
    Map<String, Object> output = (Map<String, Object>) JSON.deserializeUntyped(
      WorkflowEngine.resolvePayload(parentInst.Output__c)
    );
    // Expected totalScore = (15*2) + (25*2) + (5*2) = 30 + 50 + 10 = 90
    System.assertEquals(90, ((Decimal) output.get('totalScore')).intValue());
  }

  @isTest
  static void testDynamicFanOutWithObjectItems() {
    Map<String, Object> input = new Map<String, Object>{
      'items' => new List<Map<String, Object>>{
        new Map<String, Object>{ 'id' => 'itemA', 'value' => 15 },
        new Map<String, Object>{ 'id' => 'itemB', 'value' => 25 }
      }
    };

    Test.startTest();
    Id parentId = WorkflowEngine.start(
      'ChildWorkflowFanOutExample',
      'FanOutKeyObject_' + Crypto.getRandomInteger(),
      input
    );
    WorkflowTestHarness harness = new WorkflowTestHarness(parentId);
    WorkflowTestHarness.Result result = harness.drive();
    Test.stopTest();

    System.assertEquals('Completed', result.status);

    Workflow_Instance__c parentInst = [
      SELECT Output__c
      FROM Workflow_Instance__c
      WHERE Id = :parentId
    ];
    Map<String, Object> output = (Map<String, Object>) JSON.deserializeUntyped(
      WorkflowEngine.resolvePayload(parentInst.Output__c)
    );
    // Expected totalScore = (15*2) + (25*2) = 30 + 50 = 80
    System.assertEquals(80, ((Decimal) output.get('totalScore')).intValue());
  }
}
