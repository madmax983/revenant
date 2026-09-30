/**
 * @description Tests that `savePayloadIfNeeded` marks the files it writes as engine
 * offloads, and writes no file for a small payload.
 */
@IsTest
private class WorkflowPayloadOffloadTest {
  private static Workflow_Instance__c newInstance() {
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
      Status__c = 'Running',
      Correlation_Key__c = 'OffloadFlagKey'
    );
    insert inst;
    return inst;
  }

  @IsTest
  static void testLargePayloadFileIsFlagged() {
    Workflow_Instance__c inst = newInstance();

    String marker = WorkflowPayloadOffload.savePayloadIfNeeded(
      inst.Id,
      'x'.repeat(100001),
      'Output_FlagCheck'
    );

    Id docId = (Id) ((Map<String, Object>) JSON.deserializeUntyped(marker))
      .get('$attachmentId');
    ContentVersion cv = [
      SELECT Revenant_Payload_Offload__c
      FROM ContentVersion
      WHERE ContentDocumentId = :docId AND IsLatest = TRUE
    ];
    System.assertEquals(
      true,
      cv.Revenant_Payload_Offload__c,
      'The offloaded file carries the engine flag'
    );
  }

  @IsTest
  static void testSmallPayloadWritesNoFile() {
    Workflow_Instance__c inst = newInstance();

    String stored = WorkflowPayloadOffload.savePayloadIfNeeded(
      inst.Id,
      '{"a":1}',
      'Output_Small'
    );

    System.assertEquals('{"a":1}', stored, 'A small payload stays inline');
    System.assertEquals(
      0,
      [SELECT COUNT() FROM ContentVersion WHERE Revenant_Payload_Offload__c = TRUE],
      'No flagged file exists'
    );
  }
}
