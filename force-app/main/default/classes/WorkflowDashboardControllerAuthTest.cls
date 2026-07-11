@IsTest
public class WorkflowDashboardControllerAuthTest {
  /**
   * Asserts that an AuraHandledException raised by an unauthorized dashboard call
   * carries the expected unauthorized/script-thrown message.
   * @param e the exception thrown by the unauthorized call
   */
  private static void assertUnauthorized(AuraHandledException e) {
    System.assert(
      e.getMessage().contains('Unauthorized') ||
      e.getMessage().contains('Script-thrown exception'),
      e.getMessage()
    );
  }

  // Assembles the getFilteredInstances request wrapper by field assignment: a 1:1
  // repackaging of the former positional arguments (identical values, just wrapped).
  private static WorkflowDashboardController.InstanceQuery iqOf(
    String workflowName,
    String status,
    String searchTerm,
    Integer limitSize,
    Integer offsetSize,
    String cacheBuster
  ) {
    WorkflowDashboardController.InstanceQuery q = new WorkflowDashboardController.InstanceQuery();
    q.workflowName = workflowName;
    q.status = status;
    q.searchTerm = searchTerm;
    q.limitSize = limitSize;
    q.offsetSize = offsetSize;
    q.cacheBuster = cacheBuster;
    return q;
  }

  // Assembles the getWorkflowStats request wrapper (reuses InstanceQuery); the rollup
  // reads only workflowName/status/searchTerm.
  private static WorkflowDashboardController.InstanceQuery sqOf(
    String workflowName,
    String status,
    String searchTerm
  ) {
    WorkflowDashboardController.InstanceQuery q = new WorkflowDashboardController.InstanceQuery();
    q.workflowName = workflowName;
    q.status = status;
    q.searchTerm = searchTerm;
    return q;
  }

  // Placeholder cancelWorkflow request for the authorization check (the values are
  // irrelevant because the call is rejected before they are read).
  private static WorkflowDashboardController.CancelRequest unauthCancelReq() {
    WorkflowDashboardController.CancelRequest r = new WorkflowDashboardController.CancelRequest();
    r.instanceId = null;
    r.runCompensations = false;
    return r;
  }

  // Placeholder submitApproval request for the authorization check.
  private static WorkflowDashboardController.ApprovalRequest unauthApprovalReq() {
    WorkflowDashboardController.ApprovalRequest r = new WorkflowDashboardController.ApprovalRequest();
    r.instanceId = null;
    r.approvalKey = '';
    r.approved = false;
    r.comments = '';
    return r;
  }

  @IsTest
  static void testAuthorizationFailures() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
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
          WorkflowDashboardController.getFilteredInstances(
            iqOf('', '', '', 10, 0, '')
          );
          System.assert(
            false,
            'Expected AuraHandledException for getFilteredInstances'
          );
        } catch (AuraHandledException e) {
          assertUnauthorized(e);
        }

        // 2. getWorkflowStats
        try {
          WorkflowDashboardController.getWorkflowStats(sqOf('', '', ''));
          System.assert(
            false,
            'Expected AuraHandledException for getWorkflowStats'
          );
        } catch (AuraHandledException e) {
          assertUnauthorized(e);
        }

        // 3. getInstanceDetails
        try {
          WorkflowDashboardController.getInstanceDetails(null);
          System.assert(
            false,
            'Expected AuraHandledException for getInstanceDetails'
          );
        } catch (AuraHandledException e) {
          assertUnauthorized(e);
        }

        // 4. getDefinitions
        try {
          WorkflowDashboardController.getDefinitions();
          System.assert(
            false,
            'Expected AuraHandledException for getDefinitions'
          );
        } catch (AuraHandledException e) {
          assertUnauthorized(e);
        }

        // 5. startWorkflow
        try {
          WorkflowDashboardController.startWorkflow('', '', '');
          System.assert(
            false,
            'Expected AuraHandledException for startWorkflow'
          );
        } catch (AuraHandledException e) {
          assertUnauthorized(e);
        }

        // 6. retryWorkflowInstance
        try {
          WorkflowDashboardController.retryWorkflowInstance(null);
          System.assert(
            false,
            'Expected AuraHandledException for retryWorkflowInstance'
          );
        } catch (AuraHandledException e) {
          assertUnauthorized(e);
        }

        // 7. cancelWorkflow
        try {
          WorkflowDashboardController.cancelWorkflow(unauthCancelReq());
          System.assert(
            false,
            'Expected AuraHandledException for cancelWorkflow'
          );
        } catch (AuraHandledException e) {
          assertUnauthorized(e);
        }

        // 8. submitApproval
        try {
          WorkflowDashboardController.submitApproval(unauthApprovalReq());
          System.assert(
            false,
            'Expected AuraHandledException for submitApproval'
          );
        } catch (AuraHandledException e) {
          assertUnauthorized(e);
        }
      }

    }
  }

  @IsTest
  static void testAuthorizationSuccessWithCustomPermission() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
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
  }

  @IsTest
  static void testSearchByErrorMessage() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
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
        iqOf('', '', 'xyz', 10, 0, 'cbError')
      );
      Test.stopTest();

      System.assertEquals(
        1,
        res.size(),
        'Should find 1 instance with Error Message matching xyz'
      );
      System.assertEquals(inst.Id, (Id) res[0].get('Id'));
    }
  }

  /**
   * Seeds the attachment-backed payload fixture: four ContentVersions (tiny,
   * 50005-char, 60000-char, tiny), an instance and two steps referencing them
   * via $attachmentId markers plus a raw oversized step input.
   * @return the created Workflow_Instance__c
   */
  private static Workflow_Instance__c seedBulkPayloadFixture() {
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

    // Link ContentDocuments to the instance to pass ownership checks
    List<ContentDocumentLink> cdls = new List<ContentDocumentLink>();
    for (Id docId : cvIdToDocId.values()) {
      cdls.add(
        new ContentDocumentLink(
          ContentDocumentId = docId,
          LinkedEntityId = inst.Id,
          ShareType = 'V'
        )
      );
    }
    insert cdls;

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

    return inst;
  }

  @IsTest
  static void testBulkPayloadResolutionAndTruncation() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = seedBulkPayloadFixture();

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
  }

  @IsTest
  static void testProgressRehydrationInDetails() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // 1. Create a ContentVersion record for offloaded progress
      ContentVersion cv = new ContentVersion(
        Title = 'TestProgressCV',
        PathOnClient = 'progress.json',
        VersionData = Blob.valueOf('P'.repeat(50005))
      );
      insert cv;

      Id docId = [
        SELECT ContentDocumentId
        FROM ContentVersion
        WHERE Id = :cv.Id
      ]
      .ContentDocumentId;
      String offloadedMarker = '{"$attachmentId":"' + docId + '"}';

      // 2. Create one instance with inline progress, and one with offloaded progress
      Workflow_Instance__c instInline = new Workflow_Instance__c(
        Workflow_Name__c = 'TestDefInlineProgress',
        Status__c = 'Running',
        Correlation_Key__c = 'ProgressInlineKey',
        Progress__c = '{"percent":42.0}'
      );
      Workflow_Instance__c instOffloaded = new Workflow_Instance__c(
        Workflow_Name__c = 'TestDefOffloadedProgress',
        Status__c = 'Running',
        Correlation_Key__c = 'ProgressOffloadedKey',
        Progress__c = offloadedMarker
      );
      insert new List<Workflow_Instance__c>{ instInline, instOffloaded };

      ContentDocumentLink cdl = new ContentDocumentLink(
        ContentDocumentId = docId,
        LinkedEntityId = instOffloaded.Id,
        ShareType = 'V'
      );
      insert cdl;

      Test.startTest();
      Map<String, Object> inlineDetails = WorkflowDashboardController.getInstanceDetails(
        instInline.Id
      );
      Map<String, Object> offloadedDetails = WorkflowDashboardController.getInstanceDetails(
        instOffloaded.Id
      );
      Test.stopTest();

      Workflow_Instance__c returnedInline = (Workflow_Instance__c) inlineDetails.get(
        'instance'
      );
      System.assertEquals('{"percent":42.0}', returnedInline.Progress__c);
      Map<String, Object> inlinePayloadFiles = (Map<String, Object>) inlineDetails.get(
        'payloadFiles'
      );
      System.assert(
        !inlinePayloadFiles.containsKey('instance.Progress'),
        'Small inline progress should not have a download file'
      );

      Workflow_Instance__c returnedOffloaded = (Workflow_Instance__c) offloadedDetails.get(
        'instance'
      );
      System.assertEquals(
        'P'.repeat(50000) + '... (truncated)',
        returnedOffloaded.Progress__c
      );
      Map<String, Object> offloadedPayloadFiles = (Map<String, Object>) offloadedDetails.get(
        'payloadFiles'
      );
      System.assert(
        offloadedPayloadFiles.containsKey('instance.Progress'),
        'Truncated offloaded progress should have a download file'
      );
      Map<String, Object> progressFile = (Map<String, Object>) offloadedPayloadFiles.get(
        'instance.Progress'
      );
      System.assertEquals(50005, (Integer) progressFile.get('fullLength'));
      System.assertEquals(docId, (Id) progressFile.get('contentDocumentId'));
    }
  }

  @IsTest
  static void testWatchdogStatusAndEnqueue() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
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
  }

  @IsTest
  static void testConcurrencyStatus() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // A governed workflow with a durable counter and a parked instance.
      ConcurrencyGate.mockConfigs.put(
        'DashConcWf',
        (Concurrency_Config__mdt) JSON.deserialize(
          '{"DeveloperName":"DashConcWf","Max_Concurrent_Instances__c":5}',
          Concurrency_Config__mdt.class
        )
      );
      insert new Concurrency_State__c(
        Workflow_Definition__c = 'DashConcWf',
        In_Flight_Count__c = 5
      );
      insert new Workflow_Instance__c(
        Workflow_Name__c = 'DashConcWf',
        Status__c = 'Suspended',
        Correlation_Key__c = 'dash-parked-1',
        Concurrency_Parked__c = true
      );

      Test.startTest();
      List<Map<String, Object>> rows = WorkflowDashboardController.getConcurrencyStatus();
      Test.stopTest();

      System.assertEquals(1, rows.size(), 'One governed workflow row expected');
      Map<String, Object> row = rows[0];
      System.assertEquals('DashConcWf', row.get('workflowName'));
      System.assertEquals(
        5,
        row.get('ceiling'),
        'Ceiling surfaced from config'
      );
      System.assertEquals(
        5,
        row.get('inFlight'),
        'In-flight surfaced from counter'
      );
      System.assertEquals(1, row.get('parked'), 'Parked count surfaced');
    }
  }

  @IsTest
  static void testResumeWorkflowAndWaitingOn() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Create a mock suspended instance
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
        Status__c = 'Suspended',
        Correlation_Key__c = 'TestResumeKey',
        Sleep_Until__c = DateTime.now().addMinutes(5),
        Async_Job_Id__c = TestIdFactory.generate(AsyncApexJob.SObjectType)
      );
      insert as system inst;

      // Test getFilteredInstances returns the computed waitingOn
      Test.startTest();
      List<Map<String, Object>> instances = WorkflowDashboardController.getFilteredInstances(
        iqOf('', 'Suspended', '', 10, 0, '')
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
  }

  @IsTest
  static void testFilteredInstancesClamping() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      List<Map<String, Object>> res1 = WorkflowDashboardController.getFilteredInstances(
        iqOf('', '', '', -10, -5, '')
      );
      List<Map<String, Object>> res2 = WorkflowDashboardController.getFilteredInstances(
        iqOf('', '', '', 500, 5000, '')
      );
      Test.stopTest();
      System.assertNotEquals(null, res1);
      System.assertNotEquals(null, res2);
    }
  }

  @IsTest
  static void testGetDefinitionsFallback() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Force the ApexTypeImplementor fallback path (used when the source scan would
      // approach a governor limit) and verify it still discovers top-level and inner-class
      // workflow definitions.
      WorkflowDashboardController.forceDefinitionFallback = true;
      Test.startTest();
      List<String> definitions = WorkflowDashboardController.getDefinitions();
      Test.stopTest();
      WorkflowDashboardController.forceDefinitionFallback = false;

      System.assertNotEquals(
        null,
        definitions,
        'Fallback should return a list'
      );
      System.assert(
        definitions.contains('CleanupWorkflow'),
        'Fallback should find top-level CleanupWorkflow: ' + definitions
      );
      System.assert(
        !definitions.contains('BulkCancelWorkflow'),
        'Fallback should not find BulkCancelWorkflow (system workflow): ' +
        definitions
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
  }

  @IsTest
  static void testSubmitApprovalRoleEnforced() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
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
          WorkflowDashboardController.ApprovalRequest approvalReq = new WorkflowDashboardController.ApprovalRequest();
          approvalReq.instanceId = inst.Id;
          approvalReq.approvalKey = 'ExpenseApproval';
          approvalReq.approved = true;
          approvalReq.comments = 'Approving without the role';
          WorkflowDashboardController.submitApproval(approvalReq);
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
  }
}
