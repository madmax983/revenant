/**
 * @description Unit tests for WorkflowStorageFootprintService: verifies per-object record
 * counts and estimated bytes, 7-/30-day growth deltas (including exclusion of records older
 * than the window), the summed ContentVersion byte volume scoped to engine-owned offloaded
 * payloads (and exclusion of non-engine files), the org data-storage-allowance metrics, and
 * the configurable warning-threshold classification. All reads are bounded aggregates; the
 * tests seed a small, fixed number of records per object.
 */
@IsTest
private class WorkflowStorageFootprintServiceTest {
  // Locates the per-object row for the given API name in the service's objects list.
  private static Map<String, Object> rowFor(
    List<Object> objects,
    String apiName
  ) {
    for (Object o : objects) {
      Map<String, Object> row = (Map<String, Object>) o;
      if (apiName.equals(row.get('apiName'))) {
        return row;
      }
    }
    return null;
  }

  @IsTest
  static void testFootprintCountsDeltasAndContentBytes() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Three instances; one back-dated 40 days so it is outside both growth windows.
      List<Workflow_Instance__c> instances = new List<Workflow_Instance__c>();
      for (Integer i = 0; i < 3; i++) {
        instances.add(
          new Workflow_Instance__c(
            Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
            Status__c = 'Completed',
            Correlation_Key__c = 'FootprintKey' + i
          )
        );
      }
      insert instances;
      Test.setCreatedDate(instances[0].Id, System.now().addDays(-40));

      // One step and one signal to prove the other objects are counted independently.
      insert new Workflow_Step_Execution__c(
        Workflow_Instance__c = instances[1].Id,
        Step_Name__c = 'WorkflowEngineTest.HappyStep1',
        Status__c = 'Completed'
      );
      insert new Workflow_Signal__c(
        Workflow_Instance__c = instances[1].Id,
        Signal_Name__c = 'FootprintSignal',
        Status__c = 'Received'
      );

      // Engine-owned offloaded payload (counted) plus a user file (must NOT be counted).
      ContentVersion engineCv = new ContentVersion(
        Title = 'Output_FootprintPayload',
        PathOnClient = 'Output_FootprintPayload.json',
        VersionData = Blob.valueOf('x'.repeat(5000))
      );
      insert engineCv;
      insert new ContentVersion(
        Title = 'UserUploadedFile',
        PathOnClient = 'UserUploadedFile.txt',
        VersionData = Blob.valueOf('y'.repeat(4000))
      );
      Long engineBytes = [
        SELECT ContentSize
        FROM ContentVersion
        WHERE Id = :engineCv.Id
      ]
      .ContentSize;

      Test.startTest();
      Map<String, Object> result = WorkflowDashboardController.getStorageFootprint();
      Test.stopTest();

      List<Object> objects = (List<Object>) result.get('objects');
      System.assertEquals(
        7,
        objects.size(),
        'All seven Revenant objects should be reported'
      );

      Map<String, Object> instRow = rowFor(objects, 'Workflow_Instance__c');
      System.assertEquals(
        3,
        instRow.get('recordCount'),
        'All three instances counted'
      );
      System.assertEquals(
        2,
        instRow.get('delta30'),
        '30-day delta excludes the 40-day-old instance'
      );
      System.assertEquals(
        2,
        instRow.get('delta7'),
        '7-day delta excludes the 40-day-old instance'
      );
      System.assertEquals(
        3L * 2000,
        instRow.get('estimatedBytes'),
        'Estimated bytes are record count times the per-record estimate'
      );
      System.assertEquals(
        'Workflow Instance',
        instRow.get('label'),
        'Display label is derived from the API name'
      );

      Map<String, Object> stepRow = rowFor(
        objects,
        'Workflow_Step_Execution__c'
      );
      System.assertEquals(1, stepRow.get('recordCount'), 'One step counted');
      Map<String, Object> signalRow = rowFor(objects, 'Workflow_Signal__c');
      System.assertEquals(
        1,
        signalRow.get('recordCount'),
        'One signal counted'
      );

      // Only the engine-owned file contributes to the ContentVersion byte total.
      System.assertEquals(
        engineBytes,
        (Long) result.get('contentVersionBytes'),
        'Content bytes reflect only the engine-owned offloaded payload'
      );

      Long recordBytes = (Long) result.get('estimatedRecordBytes');
      System.assertEquals(
        recordBytes + engineBytes,
        (Long) result.get('estimatedTotalBytes'),
        'Total bytes are record estimate plus content bytes'
      );

      // Allowance metrics are present; the threshold defaults to the CMDT value.
      System.assertNotEquals(
        null,
        result.get('percentOfAllowance'),
        'Allowance percentage is populated'
      );
      System.assertEquals(
        75,
        (Decimal) result.get('warningThresholdPercent'),
        'Warning threshold defaults to the configured 75%'
      );
      System.assert(
        result.get('isOverThreshold') instanceof Boolean,
        'Over-threshold flag is a Boolean'
      );
    }
  }

  @IsTest
  static void testThresholdClassificationFlips() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      insert new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
        Status__c = 'Completed',
        Correlation_Key__c = 'ThresholdKey'
      );

      Test.startTest();
      // A zero threshold classifies any non-zero footprint as over-threshold whenever the
      // org exposes a data-storage allowance.
      WorkflowEngine.storageWarningThresholdPercent = 0;
      Map<String, Object> low = WorkflowDashboardController.getStorageFootprint();
      // An unreachable threshold never trips.
      WorkflowEngine.storageWarningThresholdPercent = 999999;
      Map<String, Object> high = WorkflowDashboardController.getStorageFootprint();
      Test.stopTest();

      Boolean hasLimit = (Boolean) low.get('hasStorageLimit');
      System.assertEquals(
        hasLimit,
        (Boolean) low.get('isOverThreshold'),
        'At threshold 0, over-threshold matches whether an allowance exists'
      );
      System.assertEquals(
        false,
        (Boolean) high.get('isOverThreshold'),
        'An unreachable threshold is never crossed'
      );
    }
  }
}
