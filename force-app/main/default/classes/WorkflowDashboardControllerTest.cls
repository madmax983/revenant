@isTest
public class WorkflowDashboardControllerTest {
  @isTest
  static void testGetInstancesAndDetails() {
    // Create mock parent workflow instance
    Workflow_Instance__c parentInst = new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
      Status__c = 'Completed',
      Correlation_Key__c = 'TestParentKey',
      Input__c = '"ParentInput"'
    );
    insert parentInst;

    // Create mock child workflow instance
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
      Status__c = 'Pending',
      Correlation_Key__c = 'TestDashboardKey',
      Input__c = '"InputData"',
      Parent_Instance__c = parentInst.Id
    );
    insert inst;

    // Create mock step execution
    Workflow_Step_Execution__c step = new Workflow_Step_Execution__c(
      Workflow_Instance__c = inst.Id,
      Step_Name__c = 'WorkflowEngineTest.HappyStep1',
      Status__c = 'Completed',
      Input__c = '"InputData"',
      Output__c = '"Output1"',
      Retry_Count__c = 0
    );
    insert step;

    Test.startTest();
    List<Workflow_Instance__c> instances = WorkflowDashboardController.getFilteredInstances(
      '',
      '',
      '',
      10,
      0,
      ''
    );
    Map<String, Object> details = WorkflowDashboardController.getInstanceDetails(
      inst.Id
    );
    Map<String, Object> parentDetails = WorkflowDashboardController.getInstanceDetails(
      parentInst.Id
    );
    Test.stopTest();

    // Re-query parentInst to get the auto-number Name field
    parentInst = [
      SELECT Name
      FROM Workflow_Instance__c
      WHERE Id = :parentInst.Id
    ];

    // Should find two instances now
    System.assertEquals(2, instances.size(), 'Should find two instances');

    Workflow_Instance__c returnedInst = (Workflow_Instance__c) details.get(
      'instance'
    );
    List<Workflow_Step_Execution__c> returnedSteps = (List<Workflow_Step_Execution__c>) details.get(
      'steps'
    );
    List<Workflow_Instance__c> returnedChildren = (List<Workflow_Instance__c>) details.get(
      'children'
    );

    System.assertEquals(inst.Id, returnedInst.Id);
    System.assertEquals(parentInst.Id, returnedInst.Parent_Instance__c);
    System.assertEquals(parentInst.Name, returnedInst.Parent_Instance__r.Name);
    System.assertEquals(
      1,
      returnedSteps.size(),
      'Should find one step execution'
    );
    System.assertEquals(step.Id, returnedSteps[0].Id);
    System.assertEquals(0, returnedChildren.size(), 'Child has no children');

    // Check parent's details for children
    List<Workflow_Instance__c> parentChildren = (List<Workflow_Instance__c>) parentDetails.get(
      'children'
    );
    System.assertEquals(
      1,
      parentChildren.size(),
      'Parent should have one child'
    );
    System.assertEquals(inst.Id, parentChildren[0].Id);
  }

  @isTest
  static void testGetDefinitions() {
    Test.startTest();
    List<String> definitions = WorkflowDashboardController.getDefinitions();
    Test.stopTest();

    // Should return a list of classes containing "implements WorkflowDefinition" or "implements VersionedWorkflow"
    System.assert(definitions != null, 'Definitions list should not be null');
    System.assert(
      definitions.contains('CleanupWorkflow'),
      'Should find CleanupWorkflow'
    );
    System.assert(
      definitions.contains('BatchFanoutWorkflowExample.BatchFanoutWorkflow'),
      'Should find BatchFanoutWorkflowExample.BatchFanoutWorkflow inner class'
    );
    System.assert(
      definitions.contains('SagaWorkflowExample.SagaWorkflow'),
      'Should find SagaWorkflowExample.SagaWorkflow inner class'
    );
  }

  @isTest
  static void testStartWorkflow() {
    Test.startTest();
    Id instanceId = WorkflowDashboardController.startWorkflow(
      'WorkflowEngineTest.HappyWorkflow',
      'StartDashboardKey',
      '"InputPayload"'
    );
    Test.stopTest();

    System.assertNotEquals(
      null,
      instanceId,
      'Should start workflow and return ID'
    );

    Workflow_Instance__c inst = [
      SELECT Workflow_Name__c, Status__c, Correlation_Key__c, Input__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals(
      'WorkflowEngineTest.HappyWorkflow',
      inst.Workflow_Name__c
    );
    System.assertEquals('StartDashboardKey', inst.Correlation_Key__c);
    System.assertEquals('"InputPayload"', inst.Input__c);
  }

  @isTest
  static void testRetryWorkflowInstance() {
    // Create a failed instance
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
      Status__c = 'Failed',
      Correlation_Key__c = 'FailedKey',
      Input__c = '"InputData"',
      Current_Step__c = 'WorkflowEngineTest.HappyStep1'
    );
    insert inst;

    Workflow_Step_Execution__c step = new Workflow_Step_Execution__c(
      Workflow_Instance__c = inst.Id,
      Step_Name__c = 'WorkflowEngineTest.HappyStep1',
      Status__c = 'Failed',
      Retry_Count__c = 1,
      Error_Details__c = 'Some error'
    );
    insert step;

    Test.startTest();
    WorkflowDashboardController.retryWorkflowInstance(inst.Id);
    Test.stopTest();

    Workflow_Instance__c updatedInst = [
      SELECT Status__c, Error_Message__c
      FROM Workflow_Instance__c
      WHERE Id = :inst.Id
    ];
    System.assertEquals('Running', updatedInst.Status__c);
    System.assertEquals(null, updatedInst.Error_Message__c);

    Workflow_Step_Execution__c updatedStep = [
      SELECT Status__c, Retry_Count__c, Error_Details__c
      FROM Workflow_Step_Execution__c
      WHERE Id = :step.Id
    ];
    System.assertEquals('Completed', updatedStep.Status__c);
    System.assertEquals(0, updatedStep.Retry_Count__c);
    System.assertEquals(null, updatedStep.Error_Details__c);
  }

  @isTest
  static void testSubmitApproval() {
    // Create active instance
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
      Status__c = 'Suspended',
      Correlation_Key__c = 'ApprovalKey',
      Input__c = '"InputData"'
    );
    insert inst;

    Test.startTest();
    WorkflowDashboardController.submitApproval(
      inst.Id,
      'ExpenseApproval',
      true,
      'Looks good'
    );
    Test.stopTest();

    // Deliver Platform Event
    Test.getEventBus().deliver();

    // Verify a signal is received in database
    List<Workflow_Signal__c> signals = [
      SELECT Id, Signal_Name__c, Payload__c, Status__c
      FROM Workflow_Signal__c
      WHERE Workflow_Instance__c = :inst.Id
    ];
    System.assertEquals(1, signals.size());
    System.assertEquals('Approve:ExpenseApproval', signals[0].Signal_Name__c);
    System.assert(signals[0].Payload__c.contains('"approved":true'));
    System.assert(signals[0].Payload__c.contains('"comments":"Looks good"'));
  }

  @isTest
  static void testCancelWorkflowInstance() {
    // Create running instance
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
      Status__c = 'Running',
      Correlation_Key__c = 'CancelDashKey',
      Input__c = '"InputData"'
    );
    insert inst;

    Test.startTest();
    WorkflowDashboardController.cancelWorkflow(inst.Id, false);
    Test.stopTest();

    Workflow_Instance__c updatedInst = [
      SELECT Status__c, Error_Message__c
      FROM Workflow_Instance__c
      WHERE Id = :inst.Id
    ];
    System.assertEquals('Cancelled', updatedInst.Status__c);
    System.assertEquals('Cancelled by user.', updatedInst.Error_Message__c);
  }

  @isTest
  static void testGetFilteredInstances() {
    // Create 3 instances with distinct details
    List<Workflow_Instance__c> testInstances = new List<Workflow_Instance__c>{
      new Workflow_Instance__c(
        Workflow_Name__c = 'TestDefA',
        Status__c = 'Completed',
        Correlation_Key__c = 'AppleKey',
        Input__c = '"TestInput"'
      ),
      new Workflow_Instance__c(
        Workflow_Name__c = 'TestDefA',
        Status__c = 'Failed',
        Correlation_Key__c = 'BananaKey',
        Input__c = '"TestInput"',
        Error_Message__c = 'Slipped on banana'
      ),
      new Workflow_Instance__c(
        Workflow_Name__c = 'TestDefB',
        Status__c = 'Running',
        Correlation_Key__c = 'OrangeKey',
        Input__c = '"TestInput"'
      )
    };
    insert testInstances;

    Test.startTest();
    // 1. Test filtering by Workflow Name
    List<Workflow_Instance__c> resWorkflow = WorkflowDashboardController.getFilteredInstances(
      'TestDefA',
      '',
      '',
      10,
      0,
      'cb1'
    );
    System.assertEquals(
      2,
      resWorkflow.size(),
      'Should find 2 instances with definition TestDefA'
    );

    // 2. Test filtering by Status
    List<Workflow_Instance__c> resStatus = WorkflowDashboardController.getFilteredInstances(
      '',
      'Running',
      '',
      10,
      0,
      'cb2'
    );
    System.assertEquals(
      1,
      resStatus.size(),
      'Should find 1 instance with Status Running'
    );
    System.assertEquals('OrangeKey', resStatus[0].Correlation_Key__c);

    // 3. Test filtering by Search Term on Correlation Key
    List<Workflow_Instance__c> resSearchKey = WorkflowDashboardController.getFilteredInstances(
      '',
      '',
      'Banana',
      10,
      0,
      'cb3'
    );
    System.assertEquals(
      1,
      resSearchKey.size(),
      'Should find 1 instance matching search Banana'
    );
    System.assertEquals('BananaKey', resSearchKey[0].Correlation_Key__c);

    // 4. Test filtering by Search Term case-insensitivity on Correlation Key
    List<Workflow_Instance__c> resSearchError = WorkflowDashboardController.getFilteredInstances(
      '',
      '',
      'banana',
      10,
      0,
      'cb4'
    );
    System.assertEquals(
      1,
      resSearchError.size(),
      'Search term search should be case-insensitive'
    );

    // 5. Test pagination: limit and offset
    List<Workflow_Instance__c> page1 = WorkflowDashboardController.getFilteredInstances(
      '',
      '',
      '',
      2,
      0,
      'cb5'
    );
    System.assertEquals(
      2,
      page1.size(),
      'Page 1 limit 2 should return 2 records'
    );

    List<Workflow_Instance__c> page2 = WorkflowDashboardController.getFilteredInstances(
      '',
      '',
      '',
      2,
      2,
      'cb6'
    );
    System.assertEquals(
      1,
      page2.size(),
      'Page 2 offset 2 limit 2 should return the remaining 1 record'
    );

    Test.stopTest();
  }

  @isTest
  static void testGetWorkflowStats() {
    // Create 3 instances with distinct details
    List<Workflow_Instance__c> testInstances = new List<Workflow_Instance__c>{
      new Workflow_Instance__c(
        Workflow_Name__c = 'TestDefA',
        Status__c = 'Completed',
        Correlation_Key__c = 'AppleKey',
        Input__c = '"TestInput"'
      ),
      new Workflow_Instance__c(
        Workflow_Name__c = 'TestDefA',
        Status__c = 'Failed',
        Correlation_Key__c = 'BananaKey',
        Input__c = '"TestInput"',
        Error_Message__c = 'Slipped on banana'
      ),
      new Workflow_Instance__c(
        Workflow_Name__c = 'TestDefB',
        Status__c = 'Running',
        Correlation_Key__c = 'OrangeKey',
        Input__c = '"TestInput"'
      )
    };
    insert testInstances;

    Test.startTest();
    // 1. Get stats overall (no filters)
    Map<String, Integer> statsAll = WorkflowDashboardController.getWorkflowStats(
      '',
      '',
      ''
    );
    System.assertEquals(3, statsAll.get('total'), 'Should count 3 total runs');
    System.assertEquals(1, statsAll.get('active'), 'Should count 1 active run');
    System.assertEquals(
      1,
      statsAll.get('completed'),
      'Should count 1 completed run'
    );
    System.assertEquals(1, statsAll.get('failed'), 'Should count 1 failed run');

    // 2. Get stats filtered by definition A
    Map<String, Integer> statsDefA = WorkflowDashboardController.getWorkflowStats(
      'TestDefA',
      '',
      ''
    );
    System.assertEquals(2, statsDefA.get('total'));
    System.assertEquals(0, statsDefA.get('active'));
    System.assertEquals(1, statsDefA.get('completed'));
    System.assertEquals(1, statsDefA.get('failed'));

    // 3. Get stats filtered by search term
    Map<String, Integer> statsSearch = WorkflowDashboardController.getWorkflowStats(
      '',
      '',
      'Banana'
    );
    System.assertEquals(1, statsSearch.get('total'));
    System.assertEquals(1, statsSearch.get('failed'));
    Test.stopTest();
  }

  @isTest
  static void testAuthorizationFailures() {
    // Create standard user who does not have the custom permission or System Administrator profile
    Profile stdProfile = [
      SELECT Id
      FROM Profile
      WHERE Name = 'Standard User'
      LIMIT 1
    ];
    User stdUser = new User(
      Alias = 'stdusr',
      Email = 'stduser@testorg.com',
      EmailEncodingKey = 'UTF-8',
      LastName = 'Testing',
      LanguageLocaleKey = 'en_US',
      LocaleSidKey = 'en_US',
      ProfileId = stdProfile.Id,
      TimeZoneSidKey = 'America/Los_Angeles',
      UserName = 'stduser_dashboard_test_' +
        DateTime.now().getTime() +
        '@testorg.com'
    );
    insert stdUser;

    System.runAs(stdUser) {
      // 1. getFilteredInstances
      try {
        WorkflowDashboardController.getFilteredInstances('', '', '', 10, 0, '');
        System.assert(
          false,
          'Expected AuraHandledException for getFilteredInstances'
        );
      } catch (AuraHandledException e) {
        System.assert(
          e.getMessage().contains('Unauthorized') ||
          e.getMessage().contains('Script-thrown exception'),
          e.getMessage()
        );
      }

      // 2. getWorkflowStats
      try {
        WorkflowDashboardController.getWorkflowStats('', '', '');
        System.assert(
          false,
          'Expected AuraHandledException for getWorkflowStats'
        );
      } catch (AuraHandledException e) {
        System.assert(
          e.getMessage().contains('Unauthorized') ||
          e.getMessage().contains('Script-thrown exception'),
          e.getMessage()
        );
      }

      // 3. getInstanceDetails
      try {
        WorkflowDashboardController.getInstanceDetails(null);
        System.assert(
          false,
          'Expected AuraHandledException for getInstanceDetails'
        );
      } catch (AuraHandledException e) {
        System.assert(
          e.getMessage().contains('Unauthorized') ||
          e.getMessage().contains('Script-thrown exception'),
          e.getMessage()
        );
      }

      // 4. getDefinitions
      try {
        WorkflowDashboardController.getDefinitions();
        System.assert(
          false,
          'Expected AuraHandledException for getDefinitions'
        );
      } catch (AuraHandledException e) {
        System.assert(
          e.getMessage().contains('Unauthorized') ||
          e.getMessage().contains('Script-thrown exception'),
          e.getMessage()
        );
      }

      // 5. startWorkflow
      try {
        WorkflowDashboardController.startWorkflow('', '', '');
        System.assert(false, 'Expected AuraHandledException for startWorkflow');
      } catch (AuraHandledException e) {
        System.assert(
          e.getMessage().contains('Unauthorized') ||
          e.getMessage().contains('Script-thrown exception'),
          e.getMessage()
        );
      }

      // 6. retryWorkflowInstance
      try {
        WorkflowDashboardController.retryWorkflowInstance(null);
        System.assert(
          false,
          'Expected AuraHandledException for retryWorkflowInstance'
        );
      } catch (AuraHandledException e) {
        System.assert(
          e.getMessage().contains('Unauthorized') ||
          e.getMessage().contains('Script-thrown exception'),
          e.getMessage()
        );
      }

      // 7. cancelWorkflow
      try {
        WorkflowDashboardController.cancelWorkflow(null, false);
        System.assert(
          false,
          'Expected AuraHandledException for cancelWorkflow'
        );
      } catch (AuraHandledException e) {
        System.assert(
          e.getMessage().contains('Unauthorized') ||
          e.getMessage().contains('Script-thrown exception'),
          e.getMessage()
        );
      }

      // 8. submitApproval
      try {
        WorkflowDashboardController.submitApproval(null, '', false, '');
        System.assert(
          false,
          'Expected AuraHandledException for submitApproval'
        );
      } catch (AuraHandledException e) {
        System.assert(
          e.getMessage().contains('Unauthorized') ||
          e.getMessage().contains('Script-thrown exception'),
          e.getMessage()
        );
      }
    }
  }

  @isTest
  static void testAuthorizationSuccessWithCustomPermission() {
    // Create standard user
    Profile stdProfile = [
      SELECT Id
      FROM Profile
      WHERE Name = 'Standard User'
      LIMIT 1
    ];
    User stdUser = new User(
      Alias = 'stdusr',
      Email = 'stduser@testorg.com',
      EmailEncodingKey = 'UTF-8',
      LastName = 'Testing',
      LanguageLocaleKey = 'en_US',
      LocaleSidKey = 'en_US',
      ProfileId = stdProfile.Id,
      TimeZoneSidKey = 'America/Los_Angeles',
      UserName = 'stduser_dashboard_ok_' +
        DateTime.now().getTime() +
        '@testorg.com'
    );
    insert stdUser;

    // Create a PermissionSet and SetupEntityAccess for custom permission
    CustomPermission cp = [
      SELECT Id
      FROM CustomPermission
      WHERE DeveloperName = 'Workflow_Admin'
      LIMIT 1
    ];
    PermissionSet ps = new PermissionSet(
      Label = 'Workflow Admin Test PS',
      Name = 'Workflow_Admin_Test_PS'
    );
    insert ps;

    SetupEntityAccess sea = new SetupEntityAccess(
      ParentId = ps.Id,
      SetupEntityId = cp.Id
    );
    insert sea;

    PermissionSetAssignment psa = new PermissionSetAssignment(
      AssigneeId = stdUser.Id,
      PermissionSetId = ps.Id
    );
    insert psa;

    System.runAs(stdUser) {
      // Call getDefinitions, should not throw unauthorized exception
      List<String> definitions = WorkflowDashboardController.getDefinitions();
      System.assertNotEquals(null, definitions);
    }
  }

  @isTest
  static void testSearchByErrorMessage() {
    // Create instance with error message
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = 'TestDefC',
      Status__c = 'Failed',
      Correlation_Key__c = 'UnrelatedKey',
      Input__c = '"TestInput"',
      Error_Message__c = 'Unique error message xyz'
    );
    insert inst;

    Test.startTest();
    List<Workflow_Instance__c> res = WorkflowDashboardController.getFilteredInstances(
      '',
      '',
      'xyz',
      10,
      0,
      'cbError'
    );
    Test.stopTest();

    System.assertEquals(
      1,
      res.size(),
      'Should find 1 instance with Error Message matching xyz'
    );
    System.assertEquals(inst.Id, res[0].Id);
  }

  @isTest
  static void testBulkPayloadResolutionAndTruncation() {
    // Create ContentVersion records
    ContentVersion cv1 = new ContentVersion(
      Title = 'TestCV1',
      PathOnClient = 'test1.json',
      VersionData = Blob.valueOf('{"small":"json"}')
    );
    ContentVersion cv2 = new ContentVersion(
      Title = 'TestCV2',
      PathOnClient = 'test2.json',
      VersionData = Blob.valueOf('A'.repeat(50005))
    );
    ContentVersion cv3 = new ContentVersion(
      Title = 'TestCV3',
      PathOnClient = 'test3.json',
      VersionData = Blob.valueOf('B'.repeat(60000))
    );
    ContentVersion cv4 = new ContentVersion(
      Title = 'TestCV4',
      PathOnClient = 'test4.json',
      VersionData = Blob.valueOf('{"result":"ok"}')
    );
    insert new List<ContentVersion>{ cv1, cv2, cv3, cv4 };

    // Query ContentDocumentId for each
    List<ContentVersion> cvs = [
      SELECT ContentDocumentId
      FROM ContentVersion
      WHERE Id IN (:cv1.Id, :cv2.Id, :cv3.Id, :cv4.Id)
    ];
    Map<Id, Id> cvIdToDocId = new Map<Id, Id>();
    for (ContentVersion cv : [
      SELECT Id, ContentDocumentId
      FROM ContentVersion
      WHERE Id IN (:cv1.Id, :cv2.Id, :cv3.Id, :cv4.Id)
    ]) {
      cvIdToDocId.put(cv.Id, cv.ContentDocumentId);
    }

    String marker1 = '{"$attachmentId":"' + cvIdToDocId.get(cv1.Id) + '"}';
    String marker2 = '{"$attachmentId":"' + cvIdToDocId.get(cv2.Id) + '"}';
    String marker3 = '{"$attachmentId":"' + cvIdToDocId.get(cv3.Id) + '"}';
    String marker4 = '{"$attachmentId":"' + cvIdToDocId.get(cv4.Id) + '"}';

    // Create instance
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = 'TestDefBulk',
      Status__c = 'Running',
      Correlation_Key__c = 'BulkKey',
      Input__c = marker1,
      Output__c = marker2
    );
    insert inst;

    // Create step
    Workflow_Step_Execution__c step = new Workflow_Step_Execution__c(
      Workflow_Instance__c = inst.Id,
      Step_Name__c = 'BulkStep',
      Status__c = 'Completed',
      Input__c = marker3,
      Output__c = marker4,
      Retry_Count__c = 0
    );
    insert step;

    // Create another step with raw long input (exceeding 50k characters) to test safety truncation
    Workflow_Step_Execution__c stepSafety = new Workflow_Step_Execution__c(
      Workflow_Instance__c = inst.Id,
      Step_Name__c = 'SafetyStep',
      Status__c = 'Completed',
      Input__c = 'C'.repeat(51000),
      Output__c = 'ShortOutput',
      Retry_Count__c = 0
    );
    insert stepSafety;

    Test.startTest();
    Map<String, Object> details = WorkflowDashboardController.getInstanceDetails(
      inst.Id
    );
    Test.stopTest();

    Workflow_Instance__c returnedInst = (Workflow_Instance__c) details.get(
      'instance'
    );
    List<Workflow_Step_Execution__c> returnedSteps = (List<Workflow_Step_Execution__c>) details.get(
      'steps'
    );

    System.assertEquals('{"small":"json"}', returnedInst.Input__c);
    System.assertEquals(
      'A'.repeat(50000) + '... (truncated)',
      returnedInst.Output__c
    );

    // Check steps
    Workflow_Step_Execution__c returnedStep1;
    Workflow_Step_Execution__c returnedStepSafety;
    for (Workflow_Step_Execution__c s : returnedSteps) {
      if (s.Step_Name__c == 'BulkStep') {
        returnedStep1 = s;
      } else if (s.Step_Name__c == 'SafetyStep') {
        returnedStepSafety = s;
      }
    }

    System.assertNotEquals(null, returnedStep1);
    System.assertEquals(
      'B'.repeat(50000) + '... (truncated)',
      returnedStep1.Input__c
    );
    System.assertEquals('{"result":"ok"}', returnedStep1.Output__c);

    System.assertNotEquals(null, returnedStepSafety);
    System.assertEquals(
      'C'.repeat(50000) + '... (truncated)',
      returnedStepSafety.Input__c
    );
    System.assertEquals('ShortOutput', returnedStepSafety.Output__c);
  }
}
