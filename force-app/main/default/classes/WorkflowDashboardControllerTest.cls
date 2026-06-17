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
    List<Map<String, Object>> instances = WorkflowDashboardController.getFilteredInstances(
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
    List<Map<String, Object>> resWorkflow = WorkflowDashboardController.getFilteredInstances(
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
    List<Map<String, Object>> resStatus = WorkflowDashboardController.getFilteredInstances(
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
    System.assertEquals(
      'OrangeKey',
      (String) resStatus[0].get('Correlation_Key__c')
    );

    // 3. Test filtering by Search Term on Correlation Key
    List<Map<String, Object>> resSearchKey = WorkflowDashboardController.getFilteredInstances(
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
    System.assertEquals(
      'BananaKey',
      (String) resSearchKey[0].get('Correlation_Key__c')
    );

    // 4. Test filtering by Search Term case-insensitivity on Correlation Key
    List<Map<String, Object>> resSearchError = WorkflowDashboardController.getFilteredInstances(
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
    List<Map<String, Object>> page1 = WorkflowDashboardController.getFilteredInstances(
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

    List<Map<String, Object>> page2 = WorkflowDashboardController.getFilteredInstances(
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
    List<Map<String, Object>> res = WorkflowDashboardController.getFilteredInstances(
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
    System.assertEquals(inst.Id, (Id) res[0].get('Id'));
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

    // Attachment-backed payloads that were truncated should expose a download
    // descriptor; tiny/inline payloads should not.
    Map<String, Object> payloadFiles = (Map<String, Object>) details.get(
      'payloadFiles'
    );
    System.assertNotEquals(
      null,
      payloadFiles,
      'payloadFiles should be present'
    );

    // instance.Output (cv2, 50005 chars) crossed the display limit -> has a file.
    System.assert(
      payloadFiles.containsKey('instance.Output'),
      'Truncated attachment-backed instance Output should have a download file'
    );
    Map<String, Object> outFile = (Map<String, Object>) payloadFiles.get(
      'instance.Output'
    );
    System.assertEquals(50005, (Integer) outFile.get('fullLength'));
    System.assert(
      ((String) outFile.get('downloadUrl'))
        .startsWith('/sfc/servlet.shepherd/document/download/'),
      'downloadUrl should point at the ContentDocument: ' +
      outFile.get('downloadUrl')
    );

    // BulkStep Input (cv3, 60000 chars) crossed the limit -> has a file.
    System.assert(
      payloadFiles.containsKey('step.' + returnedStep1.Id + '.Input'),
      'Truncated attachment-backed step Input should have a download file'
    );

    // Tiny inline payloads (instance Input cv1, BulkStep Output cv4) get no file.
    System.assert(
      !payloadFiles.containsKey('instance.Input'),
      'Small inline instance Input should not have a download file'
    );
    System.assert(
      !payloadFiles.containsKey('step.' + returnedStep1.Id + '.Output'),
      'Small inline step Output should not have a download file'
    );
    // The raw (non-attachment) 51k Safety Input is truncated but has no file to link.
    System.assert(
      !payloadFiles.containsKey('step.' + returnedStepSafety.Id + '.Input'),
      'Non-attachment truncated payload should not have a download file'
    );
  }

  @isTest
  static void testWatchdogStatusAndEnqueue() {
    // Mock the WatchdogWorkflow instance
    Workflow_Instance__c watchdogInst = new Workflow_Instance__c(
      Workflow_Name__c = 'WatchdogWorkflow',
      Status__c = 'Suspended',
      Correlation_Key__c = 'SystemWatchdog'
    );
    insert watchdogInst;

    Test.startTest();
    Map<String, Object> status = WorkflowDashboardController.getWatchdogStatus();
    WorkflowDashboardController.enqueueWatchdog();
    Test.stopTest();

    System.assertNotEquals(null, status);
    System.assertEquals(true, status.get('isRunning'));
    System.assertNotEquals(null, status.get('latestJob'));
    System.assert(status.containsKey('scheduledJobsCount'));
    System.assert(status.containsKey('sleepingInstances'));
    System.assert(status.containsKey('pendingTimeouts'));
    System.assert(status.containsKey('config'));
    System.assert(status.containsKey('dailyAsyncValue'));
    System.assert(status.containsKey('dailyAsyncLimit'));
    System.assert(status.containsKey('hasElasticLimit'));
    System.assert(status.containsKey('elasticAsyncValue'));
    System.assert(status.containsKey('elasticAsyncLimit'));
  }

  @isTest
  static void testResumeWorkflowAndWaitingOn() {
    // Create a mock suspended instance
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
      Status__c = 'Suspended',
      Correlation_Key__c = 'TestResumeKey',
      Sleep_Until__c = DateTime.now().addMinutes(5),
      Async_Job_Id__c = '08e000000000000AAA'
    );
    insert as system inst;

    // Test getFilteredInstances returns the computed waitingOn
    Test.startTest();
    List<Map<String, Object>> instances = WorkflowDashboardController.getFilteredInstances(
      '',
      'Suspended',
      '',
      10,
      0,
      ''
    );
    System.assertEquals(1, instances.size());
    // Since it's a fake ID and not active, it should fall back to 'Watchdog'
    System.assertEquals('Watchdog', (String) instances[0].get('waitingOn'));

    // Test getInstanceDetails returns details + waitingOn
    Map<String, Object> details = WorkflowDashboardController.getInstanceDetails(
      inst.Id
    );
    System.assertNotEquals(null, details);
    System.assertEquals('Watchdog', (String) details.get('waitingOn'));

    // Test resumeWorkflowInstance
    WorkflowDashboardController.resumeWorkflowInstance(inst.Id);
    Test.stopTest();

    // Verify it updated the status and cleared sleep and async job fields
    Workflow_Instance__c updatedInst = [
      SELECT Status__c, Sleep_Until__c, Async_Job_Id__c
      FROM Workflow_Instance__c
      WHERE Id = :inst.Id
    ];
    System.assert(
      updatedInst.Status__c == 'Running' ||
        updatedInst.Status__c == 'Completed',
      'Expected Status to be Running or Completed but was: ' +
      updatedInst.Status__c
    );
    System.assertEquals(null, updatedInst.Sleep_Until__c);
    System.assertEquals(null, updatedInst.Async_Job_Id__c);
  }

  @isTest
  static void testFilteredInstancesClamping() {
    Test.startTest();
    List<Map<String, Object>> res1 = WorkflowDashboardController.getFilteredInstances(
      '',
      '',
      '',
      -10,
      -5,
      ''
    );
    List<Map<String, Object>> res2 = WorkflowDashboardController.getFilteredInstances(
      '',
      '',
      '',
      500,
      5000,
      ''
    );
    Test.stopTest();
    System.assertNotEquals(null, res1);
    System.assertNotEquals(null, res2);
  }

  @isTest
  static void testGetDefinitionsFallback() {
    // Force the ApexTypeImplementor fallback path (used when the source scan would
    // approach a governor limit) and verify it still discovers top-level and inner-class
    // workflow definitions.
    WorkflowDashboardController.forceDefinitionFallback = true;
    Test.startTest();
    List<String> definitions = WorkflowDashboardController.getDefinitions();
    Test.stopTest();
    WorkflowDashboardController.forceDefinitionFallback = false;

    System.assertNotEquals(null, definitions, 'Fallback should return a list');
    System.assert(
      definitions.contains('CleanupWorkflow'),
      'Fallback should find top-level CleanupWorkflow: ' + definitions
    );
    System.assert(
      definitions.contains('SagaWorkflowExample.SagaWorkflow'),
      'Fallback should find inner-class SagaWorkflowExample.SagaWorkflow: ' +
      definitions
    );
    // Test workflow definitions must remain excluded in the fallback path too.
    for (String def : definitions) {
      System.assert(
        !def.contains('WorkflowEngineTest'),
        'Test workflow definitions must be excluded: ' + def
      );
    }
  }

  @isTest
  static void testSubmitApprovalRoleEnforced() {
    // A non-admin user holding Workflow_Admin (so they pass the dashboard gate) but NOT
    // the approval's designated role must be blocked from approving that specific gate.
    Profile stdProfile = [
      SELECT Id
      FROM Profile
      WHERE Name = 'Standard User'
      LIMIT 1
    ];
    User stdUser = new User(
      Alias = 'apprusr',
      Email = 'appruser@testorg.com',
      EmailEncodingKey = 'UTF-8',
      LastName = 'Approver',
      LanguageLocaleKey = 'en_US',
      LocaleSidKey = 'en_US',
      ProfileId = stdProfile.Id,
      TimeZoneSidKey = 'America/Los_Angeles',
      UserName = 'stduser_approval_test_' +
        DateTime.now().getTime() +
        '@testorg.com'
    );
    // Isolate setup-object DML (User/PermissionSet/...) in its own context so it does not
    // collide with the non-setup Workflow_Instance__c DML below (MIXED_DML_OPERATION).
    System.runAs(new User(Id = UserInfo.getUserId())) {
      insert stdUser;
      CustomPermission cp = [
        SELECT Id
        FROM CustomPermission
        WHERE DeveloperName = 'Workflow_Admin'
        LIMIT 1
      ];
      PermissionSet ps = new PermissionSet(
        Label = 'Workflow Admin Appr PS',
        Name = 'Workflow_Admin_Appr_PS'
      );
      insert ps;
      insert new SetupEntityAccess(ParentId = ps.Id, SetupEntityId = cp.Id);
      insert new PermissionSetAssignment(
        AssigneeId = stdUser.Id,
        PermissionSetId = ps.Id
      );
    }

    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
      Status__c = 'Suspended',
      Correlation_Key__c = 'RoleApprovalKey',
      Input__c = '"InputData"'
    );
    insert inst;

    // Pending approval gate that requires a custom permission the std user does not hold.
    Workflow_Step_Execution__c step = new Workflow_Step_Execution__c(
      Workflow_Instance__c = inst.Id,
      Step_Name__c = 'WorkflowEngineTest.HappyStep1',
      Status__c = 'Pending',
      Retry_Count__c = 0,
      Output__c = JSON.serialize(
        new Map<String, Object>{
          'waitingForApproval' => true,
          'approvalKey' => 'ExpenseApproval',
          'approvalRole' => 'Nonexistent_Finance_Approver_Perm'
        }
      )
    );
    insert step;

    Test.startTest();
    System.runAs(stdUser) {
      Boolean threw = false;
      try {
        WorkflowDashboardController.submitApproval(
          inst.Id,
          'ExpenseApproval',
          true,
          'Approving without the role'
        );
      } catch (AuraHandledException e) {
        threw = true;
        System.assert(
          e.getMessage().contains('requires') ||
            e.getMessage().contains('Unauthorized') ||
            e.getMessage().contains('Script-thrown exception'),
          e.getMessage()
        );
      }
      System.assert(
        threw,
        'Approver without the designated role must be blocked'
      );
    }
    Test.stopTest();

    // No approval signal should have been recorded.
    System.assertEquals(
      0,
      [
        SELECT COUNT()
        FROM Workflow_Signal__c
        WHERE Workflow_Instance__c = :inst.Id
      ],
      'No signal should be created when the role check fails'
    );
  }

  // ==========================================
  // Bulk re-drive of failed instances
  // ==========================================

  private static void seedFailed(String key) {
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
      Status__c = 'Failed',
      Correlation_Key__c = key,
      Current_Step__c = 'WorkflowEngineTest.HappyStep1',
      Error_Message__c = 'Endpoint down'
    );
    insert inst;
    insert new Workflow_Step_Execution__c(
      Workflow_Instance__c = inst.Id,
      Step_Name__c = 'WorkflowEngineTest.HappyStep1',
      Status__c = 'Failed',
      Retry_Count__c = 1,
      Error_Details__c = 'boom'
    );
  }

  @isTest
  static void testGetRedriveEligibleCount() {
    seedFailed('CntA');
    seedFailed('CntB');
    seedFailed('CntC');
    insert new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
      Status__c = 'Completed',
      Correlation_Key__c = 'CntDone'
    );

    Test.startTest();
    Integer eligible = WorkflowDashboardController.getRedriveEligibleCount(
      'WorkflowEngineTest.HappyWorkflow',
      'Failed',
      ''
    );
    // The confirm-count must match what getWorkflowStats reports for the same
    // Failed filter (which, scoped to Failed only, is the failed bucket).
    Map<String, Integer> stats = WorkflowDashboardController.getWorkflowStats(
      'WorkflowEngineTest.HappyWorkflow',
      'Failed',
      ''
    );
    Test.stopTest();

    System.assertEquals(3, eligible, 'Three Failed instances are eligible');
    System.assertEquals(
      stats.get('failed'),
      eligible,
      'Eligible count must match getWorkflowStats for the Failed filter'
    );
  }

  @isTest
  static void testRedriveMatchingInstancesLaunches() {
    WorkflowEngine.disableQueueableInTest = true;
    seedFailed('RdA');
    seedFailed('RdB');

    Test.startTest();
    Map<String, Object> outcome = WorkflowDashboardController.redriveMatchingInstances(
      'WorkflowEngineTest.HappyWorkflow',
      'Failed',
      ''
    );
    Test.stopTest();

    System.assertEquals(
      true,
      outcome.get('started'),
      'A re-drive should be launched'
    );
    System.assertEquals(
      2,
      outcome.get('eligibleCount'),
      'Exact eligible count returned'
    );
    System.assertNotEquals(null, outcome.get('redriveInstanceId'));

    // A BulkRedriveWorkflow instance was created to perform the work.
    System.assertEquals(
      1,
      [
        SELECT COUNT()
        FROM Workflow_Instance__c
        WHERE Workflow_Name__c = 'BulkRedriveWorkflow'
      ],
      'A re-driver workflow instance is created'
    );
    // The two targets were re-driven (orchestrator ran at stopTest).
    System.assertEquals(
      2,
      [
        SELECT COUNT()
        FROM Workflow_Instance__c
        WHERE
          Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow'
          AND Status__c = 'Running'
      ],
      'Both Failed targets transitioned to Running'
    );
  }

  @isTest
  static void testRedriveMatchingZeroEligible() {
    insert new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
      Status__c = 'Completed',
      Correlation_Key__c = 'NoneFailed'
    );

    Test.startTest();
    Map<String, Object> outcome = WorkflowDashboardController.redriveMatchingInstances(
      'WorkflowEngineTest.HappyWorkflow',
      'Failed',
      ''
    );
    Test.stopTest();

    System.assertEquals(
      false,
      outcome.get('started'),
      'Nothing to do, no launch'
    );
    System.assertEquals(0, outcome.get('eligibleCount'));
    System.assertEquals(
      0,
      [
        SELECT COUNT()
        FROM Workflow_Instance__c
        WHERE Workflow_Name__c = 'BulkRedriveWorkflow'
      ],
      'No re-driver workflow is created when nothing is eligible'
    );
  }

  @isTest
  static void testRedriveAuthorizationEnforced() {
    User restricted = buildRestrictedUser();
    Boolean threw = false;
    System.runAs(restricted) {
      Test.startTest();
      try {
        WorkflowDashboardController.getRedriveEligibleCount('', 'Failed', '');
        System.assert(
          false,
          'Expected AuraHandledException for unauthorized user'
        );
      } catch (AuraHandledException e) {
        threw = true;
      }
      Test.stopTest();
    }
    System.assert(
      threw,
      'Unauthorized users must be blocked from re-drive count'
    );
  }

  // ── RED → GREEN: Stalled-instance detection tests (issue #26) ───────────────

  @isTest
  static void testStalledInstanceFlaggedInFilteredInstances() {
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = 'StallTest.ZombieWorkflow',
      Status__c = 'Suspended',
      Correlation_Key__c = 'Stall-Zombie-Flag'
    );
    insert as system inst;

    WorkflowEngine.staleThresholdMinutes = -1;

    Test.startTest();
    List<Map<String, Object>> instances = WorkflowDashboardController.getFilteredInstances(
      '',
      'Suspended',
      '',
      10,
      0,
      ''
    );
    Test.stopTest();

    System.assertEquals(
      1,
      instances.size(),
      'Should return the suspended instance'
    );
    System.assertEquals(
      true,
      (Boolean) instances[0].get('stalled'),
      'Instance with no resume mechanism and exceeded threshold should be stalled'
    );
    Object idleMinutes = instances[0].get('idleMinutes');
    System.assertNotEquals(
      null,
      idleMinutes,
      'idleMinutes should be populated for Suspended'
    );
    System.assert(
      (Long) idleMinutes >= 0,
      'idleMinutes should be non-negative'
    );
  }

  @isTest
  static void testFreshSuspendedNotStalled() {
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = 'StallTest.ZombieWorkflow',
      Status__c = 'Suspended',
      Correlation_Key__c = 'Stall-Fresh-Key'
    );
    insert as system inst;

    WorkflowEngine.staleThresholdMinutes = 60;

    Test.startTest();
    List<Map<String, Object>> instances = WorkflowDashboardController.getFilteredInstances(
      '',
      'Suspended',
      '',
      10,
      0,
      ''
    );
    Test.stopTest();

    System.assertEquals(1, instances.size());
    System.assertEquals(
      false,
      (Boolean) instances[0].get('stalled'),
      'Fresh Suspended instance should not be stalled under default threshold'
    );
  }

  @isTest
  static void testSuspendedWithActiveTimerNotStalled() {
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = 'StallTest.TimerWorkflow',
      Status__c = 'Suspended',
      Correlation_Key__c = 'Stall-Timer-Key',
      Sleep_Until__c = DateTime.now().addMinutes(30)
    );
    insert as system inst;

    WorkflowEngine.staleThresholdMinutes = -1;

    Test.startTest();
    List<Map<String, Object>> instances = WorkflowDashboardController.getFilteredInstances(
      '',
      'Suspended',
      '',
      10,
      0,
      ''
    );
    Test.stopTest();

    System.assertEquals(1, instances.size());
    System.assertEquals(
      false,
      (Boolean) instances[0].get('stalled'),
      'Suspended with active Sleep_Until timer should not be stalled'
    );
  }

  @isTest
  static void testSuspendedWithStepTimeoutNotStalled() {
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = 'StallTest.TimeoutWorkflow',
      Status__c = 'Suspended',
      Correlation_Key__c = 'Stall-Timeout-Key'
    );
    insert as system inst;

    Workflow_Step_Execution__c step = new Workflow_Step_Execution__c(
      Workflow_Instance__c = inst.Id,
      Step_Name__c = 'StallTest.SomeStep',
      Status__c = 'Running',
      Retry_Count__c = 0,
      Timeout_At__c = DateTime.now().addMinutes(5)
    );
    insert as system step;

    WorkflowEngine.staleThresholdMinutes = -1;

    Test.startTest();
    List<Map<String, Object>> instances = WorkflowDashboardController.getFilteredInstances(
      '',
      'Suspended',
      '',
      10,
      0,
      ''
    );
    Test.stopTest();

    System.assertEquals(1, instances.size());
    System.assertEquals(
      false,
      (Boolean) instances[0].get('stalled'),
      'Suspended with a step execution having Timeout_At should not be stalled'
    );
  }

  @isTest
  static void testGetStalledInstancesReturnsAndSorts() {
    List<Workflow_Instance__c> insts = new List<Workflow_Instance__c>{
      new Workflow_Instance__c(
        Workflow_Name__c = 'StallTest.ZombieWorkflow',
        Status__c = 'Suspended',
        Correlation_Key__c = 'Stall-Sort-A'
      ),
      new Workflow_Instance__c(
        Workflow_Name__c = 'StallTest.ZombieWorkflow',
        Status__c = 'Suspended',
        Correlation_Key__c = 'Stall-Sort-B'
      )
    };
    insert as system insts;

    Test.startTest();
    List<Map<String, Object>> stalled = WorkflowDashboardController.getStalledInstances(
      '',
      '',
      -1,
      10,
      0,
      ''
    );
    Test.stopTest();

    System.assertEquals(
      2,
      stalled.size(),
      'Both stalled instances should be returned'
    );
    DateTime t0 = (DateTime) stalled[0].get('LastModifiedDate');
    DateTime t1 = (DateTime) stalled[1].get('LastModifiedDate');
    System.assert(
      t0 <= t1,
      'Results should be sorted oldest idle first (LastModifiedDate ASC)'
    );
  }

  @isTest
  static void testGetStalledInstancesThresholdDefault() {
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = 'StallTest.ZombieWorkflow',
      Status__c = 'Suspended',
      Correlation_Key__c = 'Stall-DefaultThresh'
    );
    insert as system inst;

    WorkflowEngine.staleThresholdMinutes = 60;

    Test.startTest();
    List<Map<String, Object>> stalled = WorkflowDashboardController.getStalledInstances(
      '',
      '',
      null,
      10,
      0,
      ''
    );
    Test.stopTest();

    System.assertEquals(
      0,
      stalled.size(),
      'Fresh record should not appear when null threshold falls back to default 60 min'
    );
  }

  @isTest
  static void testGetStalledInstancesNegativeThreshold() {
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = 'StallTest.ZombieWorkflow',
      Status__c = 'Suspended',
      Correlation_Key__c = 'Stall-NegThresh'
    );
    insert as system inst;

    Test.startTest();
    List<Map<String, Object>> stalled = WorkflowDashboardController.getStalledInstances(
      '',
      '',
      -1,
      10,
      0,
      ''
    );
    Test.stopTest();

    System.assertEquals(
      1,
      stalled.size(),
      'Explicit negative threshold should include fresh records'
    );
    System.assertEquals(
      true,
      (Boolean) stalled[0].get('stalled'),
      'Returned record should be marked stalled'
    );
  }

  @isTest
  static void testGetStalledInstancesPaginatesAfterFiltering() {
    // Two genuinely stalled instances, plus one that must be excluded because it
    // has a step with a declared timeout (anti-join). With limitSize=1 the two
    // stalled rows must page out one-per-page and the excluded one must never
    // appear — proving pagination runs over the filtered set, not raw candidates.
    List<Workflow_Instance__c> insts = new List<Workflow_Instance__c>{
      new Workflow_Instance__c(
        Workflow_Name__c = 'StallTest.ZombieWorkflow',
        Status__c = 'Suspended',
        Correlation_Key__c = 'Stall-Page-A'
      ),
      new Workflow_Instance__c(
        Workflow_Name__c = 'StallTest.ZombieWorkflow',
        Status__c = 'Suspended',
        Correlation_Key__c = 'Stall-Page-B'
      ),
      new Workflow_Instance__c(
        Workflow_Name__c = 'StallTest.ZombieWorkflow',
        Status__c = 'Suspended',
        Correlation_Key__c = 'Stall-Page-Excluded'
      )
    };
    insert as system insts;

    Workflow_Step_Execution__c step = new Workflow_Step_Execution__c(
      Workflow_Instance__c = insts[2].Id,
      Step_Name__c = 'StallTest.SomeStep',
      Status__c = 'Running',
      Retry_Count__c = 0,
      Timeout_At__c = DateTime.now().addMinutes(5)
    );
    insert as system step;

    Test.startTest();
    List<Map<String, Object>> page0 = WorkflowDashboardController.getStalledInstances(
      '',
      '',
      -1,
      1,
      0,
      ''
    );
    List<Map<String, Object>> page1 = WorkflowDashboardController.getStalledInstances(
      '',
      '',
      -1,
      1,
      1,
      ''
    );
    List<Map<String, Object>> page2 = WorkflowDashboardController.getStalledInstances(
      '',
      '',
      -1,
      1,
      2,
      ''
    );
    Test.stopTest();

    System.assertEquals(
      1,
      page0.size(),
      'First page should hold exactly one stalled row'
    );
    System.assertEquals(
      1,
      page1.size(),
      'Second page should hold the other stalled row'
    );
    System.assertEquals(
      0,
      page2.size(),
      'Third page should be empty — only two stalled rows exist (excluded one filtered out)'
    );

    Set<Id> returned = new Set<Id>{
      (Id) page0[0].get('Id'),
      (Id) page1[0].get('Id')
    };
    System.assert(
      returned.contains(insts[0].Id),
      'Stall-Page-A should be surfaced across pages'
    );
    System.assert(
      returned.contains(insts[1].Id),
      'Stall-Page-B should be surfaced across pages'
    );
    System.assert(
      !returned.contains(insts[2].Id),
      'Instance with a declared step timeout must be excluded from the stalled set'
    );
  }

  @isTest
  static void testGetStalledCount() {
    List<Workflow_Instance__c> insts = new List<Workflow_Instance__c>{
      new Workflow_Instance__c(
        Workflow_Name__c = 'StallTest.ZombieWorkflow',
        Status__c = 'Suspended',
        Correlation_Key__c = 'SCount-Stall-1'
      ),
      new Workflow_Instance__c(
        Workflow_Name__c = 'StallTest.ZombieWorkflow',
        Status__c = 'Suspended',
        Correlation_Key__c = 'SCount-Stall-2'
      ),
      new Workflow_Instance__c(
        Workflow_Name__c = 'StallTest.ZombieWorkflow',
        Status__c = 'Suspended',
        Correlation_Key__c = 'SCount-Timer-3',
        Sleep_Until__c = DateTime.now().addMinutes(10)
      )
    };
    insert as system insts;

    Test.startTest();
    Map<String, Object> result = WorkflowDashboardController.getStalledCount(
      '',
      '',
      -1
    );
    Test.stopTest();

    System.assertEquals(
      2,
      (Integer) result.get('count'),
      'Only instances with no resume mechanism should be counted as stalled'
    );
    System.assertEquals(
      false,
      (Boolean) result.get('capped'),
      'Should not be capped for small test data'
    );
  }

  @isTest
  static void testIdleMinutesForNonSuspendedNonTerminal() {
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = 'StallTest.RunningWorkflow',
      Status__c = 'Running',
      Correlation_Key__c = 'Stall-Running-Key'
    );
    insert as system inst;

    Test.startTest();
    List<Map<String, Object>> instances = WorkflowDashboardController.getFilteredInstances(
      '',
      'Running',
      '',
      10,
      0,
      ''
    );
    Test.stopTest();

    System.assertEquals(1, instances.size());
    Object idleMinutes = instances[0].get('idleMinutes');
    System.assertNotEquals(
      null,
      idleMinutes,
      'idleMinutes should be populated for non-terminal Running instances'
    );
    System.assert(
      (Long) idleMinutes >= 0,
      'idleMinutes should be non-negative'
    );
    System.assertEquals(
      false,
      (Boolean) instances[0].get('stalled'),
      'Running instances should never be classified as stalled'
    );
  }

  @isTest
  static void testIdleMinutesNullForTerminal() {
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = 'StallTest.DoneWorkflow',
      Status__c = 'Completed',
      Correlation_Key__c = 'Stall-Completed-Key'
    );
    insert as system inst;

    Test.startTest();
    List<Map<String, Object>> instances = WorkflowDashboardController.getFilteredInstances(
      '',
      'Completed',
      '',
      10,
      0,
      ''
    );
    Test.stopTest();

    System.assertEquals(1, instances.size());
    System.assertEquals(
      null,
      instances[0].get('idleMinutes'),
      'idleMinutes should be null for terminal (Completed) instances'
    );
    System.assertEquals(
      false,
      (Boolean) instances[0].get('stalled'),
      'Terminal instances should not be classified as stalled'
    );
  }

  @isTest
  static void testStaleThresholdConfigFallback() {
    System.assert(
      WorkflowEngine.staleThresholdMinutes >= 0,
      'staleThresholdMinutes must be non-negative, got: ' +
      WorkflowEngine.staleThresholdMinutes
    );
    System.assertEquals(
      60,
      WorkflowEngine.staleThresholdMinutes,
      'Default stale threshold should be 60 minutes'
    );
  }

  @isTest
  static void testStalledReadOnlyNoSideEffects() {
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = 'StallTest.ZombieWorkflow',
      Status__c = 'Suspended',
      Correlation_Key__c = 'Stall-ReadOnly-Key'
    );
    insert as system inst;

    Integer instanceCountBefore = [SELECT COUNT() FROM Workflow_Instance__c];
    Integer stepCountBefore = [SELECT COUNT() FROM Workflow_Step_Execution__c];

    WorkflowEngine.staleThresholdMinutes = -1;

    Test.startTest();
    WorkflowDashboardController.getFilteredInstances(
      '',
      'Suspended',
      '',
      10,
      0,
      ''
    );
    WorkflowDashboardController.getStalledInstances('', '', -1, 10, 0, '');
    WorkflowDashboardController.getStalledCount('', '', -1);
    Test.stopTest();

    System.assertEquals(
      instanceCountBefore,
      [SELECT COUNT() FROM Workflow_Instance__c],
      'No Workflow_Instance__c records should be created or deleted'
    );
    System.assertEquals(
      stepCountBefore,
      [SELECT COUNT() FROM Workflow_Step_Execution__c],
      'No Workflow_Step_Execution__c records should be created or deleted'
    );
    Workflow_Instance__c unchanged = [
      SELECT Status__c
      FROM Workflow_Instance__c
      WHERE Id = :inst.Id
    ];
    System.assertEquals(
      'Suspended',
      unchanged.Status__c,
      'Instance status must not be modified by staleness detection'
    );
  }

  @isTest
  static void testGetStalledInstancesAuthorization() {
    Profile stdProfile = [
      SELECT Id
      FROM Profile
      WHERE Name = 'Standard User'
      LIMIT 1
    ];
    User stdUser = new User(
      Alias = 'stldusr',
      Email = 'stalleduser@testorg.com',
      EmailEncodingKey = 'UTF-8',
      LastName = 'StalledTest',
      LanguageLocaleKey = 'en_US',
      LocaleSidKey = 'en_US',
      ProfileId = stdProfile.Id,
      TimeZoneSidKey = 'America/Los_Angeles',
      UserName = 'stalled_dashboard_test_' +
        DateTime.now().getTime() +
        '@testorg.com'
    );
    insert stdUser;

    System.runAs(stdUser) {
      Test.startTest();
      try {
        WorkflowDashboardController.getStalledInstances('', '', -1, 10, 0, '');
        System.assert(
          false,
          'Expected AuraHandledException for getStalledInstances'
        );
      } catch (AuraHandledException e) {
        System.assert(
          e.getMessage().contains('Unauthorized') ||
          e.getMessage().contains('Script-thrown exception'),
          e.getMessage()
        );
      }

      try {
        WorkflowDashboardController.getStalledCount('', '', -1);
        System.assert(
          false,
          'Expected AuraHandledException for getStalledCount'
        );
      } catch (AuraHandledException e) {
        System.assert(
          e.getMessage().contains('Unauthorized') ||
          e.getMessage().contains('Script-thrown exception'),
          e.getMessage()
        );
      }
      Test.stopTest();
    }
  }

  private static User buildRestrictedUser() {
    Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
    User u = new User(
      Alias = 'rdrv',
      Email = 'redrive.restricted@example.com',
      EmailEncodingKey = 'UTF-8',
      LastName = 'Restricted',
      LanguageLocaleKey = 'en_US',
      LocaleSidKey = 'en_US',
      ProfileId = p.Id,
      TimeZoneSidKey = 'America/Los_Angeles',
      Username = 'redrive.restricted.' +
        DateTime.now().getTime() +
        '@example.com'
    );
    insert u;
    return u;
  }
}
