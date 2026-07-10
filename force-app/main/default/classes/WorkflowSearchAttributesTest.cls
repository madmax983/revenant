@IsTest
public class WorkflowSearchAttributesTest {
  @IsTest
  static void testAttributeValidation() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // 1. Test count limit validation (max 10)
      Map<String, String> overCountAttrs = new Map<String, String>();
      for (Integer i = 0; i < 11; i++) {
        overCountAttrs.put('key' + i, 'val' + i);
      }
      try {
        WorkflowEngine.start(
          'StepContextSignalEngineTest.PlainWaitWorkflow',
          'CK_VAL_1',
          null,
          overCountAttrs
        );
        System.assert(
          false,
          'Should have failed due to over attribute count limit'
        );
      } catch (Exception ex) {
        System.assert(
          ex.getMessage()
            .contains('Attribute count exceeds maximum limit of 10'),
          'Unexpected error message: ' + ex.getMessage()
        );
      }

      // 2. Test key length limit validation (max 100)
      String longKey = 'k'.repeat(101);
      Map<String, String> overKeyLenAttrs = new Map<String, String>{
        longKey => 'val'
      };
      try {
        WorkflowEngine.start(
          'StepContextSignalEngineTest.PlainWaitWorkflow',
          'CK_VAL_2',
          null,
          overKeyLenAttrs
        );
        System.assert(
          false,
          'Should have failed due to over attribute key length limit'
        );
      } catch (Exception ex) {
        System.assert(
          ex.getMessage()
            .contains(
              'Attribute key length exceeds maximum limit of 100 characters'
            ),
          'Unexpected error message: ' + ex.getMessage()
        );
      }

      // 3. Test value length limit validation (max 150)
      String longVal = 'v'.repeat(151);
      Map<String, String> overValLenAttrs = new Map<String, String>{
        'key' => longVal
      };
      try {
        WorkflowEngine.start(
          'StepContextSignalEngineTest.PlainWaitWorkflow',
          'CK_VAL_3',
          null,
          overValLenAttrs
        );
        System.assert(
          false,
          'Should have failed due to over attribute value length limit'
        );
      } catch (Exception ex) {
        System.assert(
          ex.getMessage()
            .contains(
              'Attribute value length exceeds maximum limit of 150 characters'
            ),
          'Unexpected error message: ' + ex.getMessage()
        );
      }
    }
  }

  @IsTest
  static void testAttributePersistence() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      Id instanceId = WorkflowEngine.start(
        'StepContextSignalEngineTest.PlainWaitWorkflow',
        'CK_PERSIST_1',
        null,
        new Map<String, String>{ 'region' => 'EU', 'tier' => 'enterprise' }
      );
      Test.stopTest();

      List<Workflow_Search_Attribute__c> attrs = [
        SELECT Key__c, Value__c, Key_Value__c
        FROM Workflow_Search_Attribute__c
        WHERE Workflow_Instance__c = :instanceId
        ORDER BY Key__c ASC
      ];
      System.assertEquals(
        2,
        attrs.size(),
        'Attributes should have been persisted'
      );
      System.assertEquals('region', attrs[0].Key__c);
      System.assertEquals('EU', attrs[0].Value__c);
      System.assertEquals('region=EU', attrs[0].Key_Value__c);
      System.assertEquals('tier', attrs[1].Key__c);
      System.assertEquals('enterprise', attrs[1].Value__c);
      System.assertEquals('tier=enterprise', attrs[1].Key_Value__c);
    }
  }

  @IsTest
  static void testGetOrStartDedupAttributes() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Map<String, String> attrs1 = new Map<String, String>{ 'region' => 'EU' };
      Map<String, String> attrs2 = new Map<String, String>{ 'region' => 'US' };

      Test.startTest();
      WorkflowEngine.StartResult res1 = WorkflowEngine.startOrGet(
        'StepContextSignalEngineTest.PlainWaitWorkflow',
        'CK_DEDUP_1',
        null,
        attrs1
      );
      System.assert(res1.isNew, 'First start should be new');

      // Sibling / redelivery start with same correlation key but different attributes
      WorkflowEngine.StartResult res2 = WorkflowEngine.startOrGet(
        'StepContextSignalEngineTest.PlainWaitWorkflow',
        'CK_DEDUP_1',
        null,
        attrs2
      );
      System.assert(!res2.isNew, 'Second start should be deduped');
      System.assertEquals(
        res1.instanceId,
        res2.instanceId,
        'Should resolve to same instance'
      );
      Test.stopTest();

      // Verify attributes were not overwritten/updated
      List<Workflow_Search_Attribute__c> dbAttrs = [
        SELECT Key__c, Value__c
        FROM Workflow_Search_Attribute__c
        WHERE Workflow_Instance__c = :res1.instanceId
      ];
      System.assertEquals(1, dbAttrs.size());
      System.assertEquals('region', dbAttrs[0].Key__c);
      System.assertEquals(
        'EU',
        dbAttrs[0].Value__c,
        'Deduplicated start must not overwrite attributes'
      );
    }
  }

  @IsTest
  static void testInvocableActionInvalidJsonHandling() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowStartInvocableAction.StartRequest req = new WorkflowStartInvocableAction.StartRequest();
      req.workflowName = 'StepContextSignalEngineTest.PlainWaitWorkflow';
      req.correlationKey = 'CK_INV_ERR_1';
      req.attributesJson = '[1, 2, 3]';

      try {
        WorkflowStartInvocableAction.startWorkflow(
          new List<WorkflowStartInvocableAction.StartRequest>{ req }
        );
        System.assert(false, 'Should have failed due to invalid JSON casting');
      } catch (Exception ex) {
        System.assert(
          ex.getMessage()
            .contains('Attributes JSON must represent a key-value object'),
          'Unexpected error: ' + ex.getMessage()
        );
      }

      req.attributesJson = 'invalid_json';
      try {
        WorkflowStartInvocableAction.startWorkflow(
          new List<WorkflowStartInvocableAction.StartRequest>{ req }
        );
        System.assert(false, 'Should have failed due to invalid JSON syntax');
      } catch (Exception ex) {
        System.assert(
          ex.getMessage().contains('Invalid Attributes JSON'),
          'Unexpected error: ' + ex.getMessage()
        );
      }
    }
  }
}
