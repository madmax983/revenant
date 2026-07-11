@IsTest
public class WorkflowDashboardControllerInjectTest {
  @IsTest
  static void testSearchWithSingleQuote() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'O\'Connor.Workflow',
        Status__c = 'Suspended',
        Correlation_Key__c = 'O\'ConnorKey',
        Input__c = '"TestInput"'
      );
      insert inst;

      Workflow_Signal__c sig = new Workflow_Signal__c(
        Correlation_Key__c = 'O\'ConnorKey',
        Signal_Name__c = 'O\'ConnorSignal',
        Status__c = 'Unrouted'
      );
      insert sig;

      Test.startTest();
      List<Map<String, Object>> filteredInsts = WorkflowDashboardController.getFilteredInstances(
        '',
        '',
        'O\'Connor',
        10,
        0,
        ''
      );

      List<Map<String, Object>> stalledInsts = WorkflowDashboardController.getStalledInstances(
        '',
        'O\'Connor',
        -1,
        10,
        0,
        ''
      );

      Map<String, Object> stalledCountResult = WorkflowDashboardController.getStalledCount(
        '',
        'O\'Connor',
        -1
      );

      List<Map<String, Object>> unroutedSigs = WorkflowDashboardController.getUnroutedSignals(
        'O\'Connor',
        10,
        0,
        ''
      );

      Map<String, Object> unroutedCountResult = WorkflowDashboardController.getUnroutedSignalCount(
        'O\'Connor'
      );
      Test.stopTest();

      System.assertEquals(
        1,
        filteredInsts.size(),
        'Should find 1 filtered instance'
      );
      System.assertEquals(
        1,
        stalledInsts.size(),
        'Should find 1 stalled instance'
      );
      System.assertEquals(
        1,
        (Integer) stalledCountResult.get('count'),
        'Should count 1 stalled instance'
      );
      System.assertEquals(
        1,
        unroutedSigs.size(),
        'Should find 1 unrouted signal'
      );
      System.assertEquals(
        1,
        (Integer) unroutedCountResult.get('count'),
        'Should count 1 unrouted signal'
      );
    }
  }

  @IsTest
  static void testFailureCategoryFiltering() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      List<Workflow_Instance__c> testInstances = new List<Workflow_Instance__c>{
        new Workflow_Instance__c(
          Workflow_Name__c = 'TestDefA',
          Status__c = 'Failed',
          Correlation_Key__c = 'TimeoutKey',
          Failure_Category__c = 'TIMEOUT'
        ),
        new Workflow_Instance__c(
          Workflow_Name__c = 'TestDefA',
          Status__c = 'Failed',
          Correlation_Key__c = 'StepExceptionKey',
          Failure_Category__c = 'STEP_EXCEPTION'
        ),
        new Workflow_Instance__c(
          Workflow_Name__c = 'TestDefB',
          Status__c = 'Failed',
          Correlation_Key__c = 'RetriesExhaustedKey',
          Failure_Category__c = 'RETRIES_EXHAUSTED'
        )
      };
      insert testInstances;

      Test.startTest();
      // Calls the 7-parameter WorkflowDashboardController.getFilteredInstances with failureCategory = 'TIMEOUT'
      List<Map<String, Object>> resCategory = WorkflowDashboardController.getFilteredInstances(
        '',
        'Failed',
        '',
        'TIMEOUT',
        10,
        0,
        'cb'
      );

      // Calls WorkflowDashboardController.getInstanceDetails for the first instance
      Map<String, Object> details = WorkflowDashboardController.getInstanceDetails(
        testInstances[0].Id
      );

      // Calls the 6-parameter WorkflowDashboardController.getFilteredInstances with searchTerm = 'StepExceptionKey'
      List<Map<String, Object>> resSearch = WorkflowDashboardController.getFilteredInstances(
        '',
        '',
        'StepExceptionKey',
        10,
        0,
        'cb'
      );
      Test.stopTest();

      // asserts only the matching instance is returned and contains the correct category
      System.assertEquals(
        1,
        resCategory.size(),
        'Should find exactly 1 instance for TIMEOUT category'
      );
      System.assertEquals(
        testInstances[0].Id,
        (Id) resCategory[0].get('Id'),
        'Should return the correct instance'
      );
      System.assertEquals(
        'TIMEOUT',
        (String) resCategory[0].get('Failure_Category__c'),
        'Should contain the correct failure category'
      );

      // asserts Failure_Category__c equals 'TIMEOUT'
      Workflow_Instance__c returnedInst = (Workflow_Instance__c) details.get(
        'instance'
      );
      System.assertNotEquals(
        null,
        returnedInst,
        'Returned instance details should not be null'
      );
      System.assertEquals(
        'TIMEOUT',
        returnedInst.Failure_Category__c,
        'Failure_Category__c should be TIMEOUT'
      );

      // asserts the matching instance is returned
      System.assertEquals(
        1,
        resSearch.size(),
        'Should find exactly 1 instance matching StepExceptionKey searchTerm'
      );
      System.assertEquals(
        testInstances[1].Id,
        (Id) resSearch[0].get('Id'),
        'Should return the correct instance matching search term'
      );
    }
  }

  @IsTest
  static void testCompensateWorkflowInstance() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;

      // Create a target Completed workflow instance with compensation stack
      Workflow_Instance__c target = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
        Status__c = 'Completed',
        Compensation_Stack__c = JSON.serialize(
          new List<String>{
            'WorkflowEngineTest.NonCompensatableStep',
            'WorkflowEngineTest.CompensatableHappyStep'
          }
        ),
        Correlation_Key__c = 'TestKey_Comp_Controller',
        Input__c = '{"key": "val"}'
      );
      insert target;

      // Create the original completed step execution for the compensatable step
      Workflow_Step_Execution__c origExec = new Workflow_Step_Execution__c(
        Workflow_Instance__c = target.Id,
        Step_Name__c = 'WorkflowEngineTest.CompensatableHappyStep',
        Status__c = 'Completed',
        Input__c = '{"stepInput": 1}',
        Output__c = '{"stepOutput": 2}'
      );
      insert origExec;

      Test.startTest();
      Id compensatingId = WorkflowDashboardController.compensateWorkflow(
        target.Id
      );
      Test.stopTest();

      System.assertNotEquals(
        null,
        compensatingId,
        'Compensating run ID should be returned from controller'
      );

      // Verify detail retrieval shows Compensated_By__c
      Map<String, Object> details = WorkflowDashboardController.getInstanceDetails(
        target.Id
      );
      Workflow_Instance__c instReload = (Workflow_Instance__c) details.get(
        'instance'
      );
      System.assertEquals(
        compensatingId,
        instReload.Compensated_By__c,
        'getInstanceDetails should return linked Compensated_By__c field'
      );
    }
  }

  @IsTest
  static void testInjectSignalSuccess() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
        Status__c = 'Suspended',
        Correlation_Key__c = 'SignalKey1',
        Input__c = '"InputData"',
        Sleep_Until__c = Datetime.now().addDays(1)
      );
      insert inst;

      WorkflowEngine.disableQueueableInTest = true;

      Test.startTest();
      WorkflowDashboardController.injectSignal(
        inst.Id,
        'PaymentReceived',
        '{"amount": 100}'
      );
      Test.stopTest();

      List<Workflow_Signal__c> signals = [
        SELECT Id, Signal_Name__c, Payload__c
        FROM Workflow_Signal__c
        WHERE Workflow_Instance__c = :inst.Id
      ];
      System.assertEquals(1, signals.size());
      System.assertEquals('PaymentReceived', signals[0].Signal_Name__c);
      System.assert(
        signals[0].Payload__c.contains('"amount":100') ||
        signals[0].Payload__c.contains('"amount": 100'),
        'Payload should match'
      );

      // Verify status mutation and sleep until clearing
      Workflow_Instance__c updatedInst = [
        SELECT Status__c, Sleep_Until__c
        FROM Workflow_Instance__c
        WHERE Id = :inst.Id
      ];
      System.assertEquals(
        'Running',
        updatedInst.Status__c,
        'Instance status should transition to Running after signal injection'
      );
      System.assertEquals(
        null,
        updatedInst.Sleep_Until__c,
        'Sleep_Until__c should be cleared (null) after signal injection'
      );
    }
  }

  @IsTest
  static void testInjectSignalNonSuspendedRejection() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
        Status__c = 'Running',
        Correlation_Key__c = 'SignalKey2',
        Input__c = '"InputData"'
      );
      insert inst;

      try {
        WorkflowDashboardController.injectSignal(
          inst.Id,
          'PaymentReceived',
          '{}'
        );
        System.assert(
          false,
          'Should throw exception on non-Suspended instance'
        );
      } catch (AuraHandledException e) {
        System.assert(e.getMessage().contains('Suspended'), e.getMessage());
      }
    }
  }

  @IsTest
  static void testInjectSignalInvalidJsonRejection() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
        Status__c = 'Suspended',
        Correlation_Key__c = 'SignalKey3',
        Input__c = '"InputData"'
      );
      insert inst;

      try {
        WorkflowDashboardController.injectSignal(
          inst.Id,
          'PaymentReceived',
          '{invalid}'
        );
        System.assert(false, 'Should throw exception on invalid JSON');
      } catch (AuraHandledException e) {
        System.assert(
          e.getMessage().contains('Invalid payload JSON'),
          e.getMessage()
        );
      }
    }
  }

  @IsTest
  static void testInjectSignalAuthorization() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Profile stdProfile = [
        SELECT Id
        FROM Profile
        WHERE Name = 'Standard User'
        LIMIT 1
      ];
      User stdUser = new User(
        Alias = 'sigusr',
        Email = 'siguser@testorg.com',
        EmailEncodingKey = 'UTF-8',
        LastName = 'Signaler',
        LanguageLocaleKey = 'en_US',
        LocaleSidKey = 'en_US',
        ProfileId = stdProfile.Id,
        TimeZoneSidKey = 'America/Los_Angeles',
        UserName = 'stduser_sig_test_' +
          DateTime.now().getTime() +
          '@testorg.com'
      );

      System.runAs(new User(Id = UserInfo.getUserId())) {
        insert stdUser;
        CustomPermission cp = [
          SELECT Id
          FROM CustomPermission
          WHERE DeveloperName = 'Workflow_Admin'
          LIMIT 1
        ];
        PermissionSet ps = new PermissionSet(
          Label = 'Workflow Admin Sig PS',
          Name = 'Workflow_Admin_Sig_PS'
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
        Correlation_Key__c = 'SignalKey4',
        Input__c = '"InputData"'
      );
      insert inst;

      System.runAs(stdUser) {
        try {
          WorkflowDashboardController.injectSignal(
            inst.Id,
            'PaymentReceived',
            '{}'
          );
          System.assert(
            false,
            'Should be blocked without Workflow_Signal_Injection permission'
          );
        } catch (AuraHandledException e) {
          System.assert(
            e.getMessage().contains('Workflow_Signal_Injection'),
            e.getMessage()
          );
        }
      }

    }
  }

  @IsTest
  static void testInjectSignalAttribution() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
        Status__c = 'Suspended',
        Correlation_Key__c = 'SignalKey5',
        Input__c = '"InputData"'
      );
      insert inst;

      WorkflowEngine.disableQueueableInTest = true;

      Test.startTest();
      WorkflowDashboardController.injectSignal(
        inst.Id,
        'PaymentReceived',
        '{}'
      );
      Test.stopTest();

      List<Workflow_Signal__c> signals = [
        SELECT Id, Payload__c
        FROM Workflow_Signal__c
        WHERE Workflow_Instance__c = :inst.Id
      ];
      System.assertEquals(1, signals.size());

      Map<String, Object> payloadMap = (Map<String, Object>) JSON.deserializeUntyped(
        signals[0].Payload__c
      );
      System.assertEquals(
        UserInfo.getUserId(),
        (String) payloadMap.get('operatorId'),
        'operatorId should match running user ID'
      );
      System.assertEquals(
        UserInfo.getUserName(),
        (String) payloadMap.get('operatorUsername'),
        'operatorUsername should match running user username'
      );
      System.assertEquals(
        UserInfo.getName(),
        (String) payloadMap.get('operator'),
        'operator should match running user display name'
      );
    }
  }

  @IsTest
  static void testInjectSignalNullInstanceRejection() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      try {
        WorkflowDashboardController.injectSignal(null, 'PaymentReceived', '{}');
        System.assert(false, 'Should throw exception on null instance ID');
      } catch (AuraHandledException e) {
        System.assert(
          e.getMessage().contains('Workflow instance not found') ||
          e.getMessage().contains('Instance ID is required'),
          'Exception message should contain relevant validation error, but was: ' +
          e.getMessage()
        );
      }
    }
  }

  @IsTest
  static void testInjectSignalBlankSignalNameRejection() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
        Status__c = 'Suspended',
        Correlation_Key__c = 'SignalKeyBlankSig',
        Input__c = '"InputData"'
      );
      insert inst;

      try {
        WorkflowDashboardController.injectSignal(inst.Id, ' ', '{}');
        System.assert(false, 'Should throw exception on blank signal name');
      } catch (AuraHandledException e) {
        System.assert(
          e.getMessage().contains('Signal name is required.'),
          e.getMessage()
        );
      }
    }
  }

  @IsTest
  static void testInjectSignalNoDashboardAccess() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Profile stdProfile = [
        SELECT Id
        FROM Profile
        WHERE Name = 'Standard User'
        LIMIT 1
      ];
      User stdUser = new User(
        Alias = 'signo',
        Email = 'signouser@testorg.com',
        EmailEncodingKey = 'UTF-8',
        LastName = 'SignalerNo',
        LanguageLocaleKey = 'en_US',
        LocaleSidKey = 'en_US',
        ProfileId = stdProfile.Id,
        TimeZoneSidKey = 'America/Los_Angeles',
        UserName = 'stduser_signo_test_' +
          DateTime.now().getTime() +
          '@testorg.com'
      );
      insert stdUser;

      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
        Status__c = 'Suspended',
        Correlation_Key__c = 'SignalKey7',
        Input__c = '"InputData"'
      );
      insert inst;

      System.runAs(stdUser) {
        try {
          WorkflowDashboardController.injectSignal(
            inst.Id,
            'PaymentReceived',
            '{}'
          );
          System.assert(false, 'Should have thrown AuraHandledException');
        } catch (AuraHandledException e) {
          System.assert(
            e.getMessage()
              .contains(
                'Unauthorized: Access to the Workflow Dashboard is restricted.'
              ),
            e.getMessage()
          );
        }
      }

    }
  }

  @IsTest
  static void testInjectSignalAuthorizationSuccess() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Profile stdProfile = [
        SELECT Id
        FROM Profile
        WHERE Name = 'Standard User'
        LIMIT 1
      ];
      User stdUser = new User(
        Alias = 'sigok',
        Email = 'sigokuser@testorg.com',
        EmailEncodingKey = 'UTF-8',
        LastName = 'SignalerOk',
        LanguageLocaleKey = 'en_US',
        LocaleSidKey = 'en_US',
        ProfileId = stdProfile.Id,
        TimeZoneSidKey = 'America/Los_Angeles',
        UserName = 'stduser_sigok_test_' +
          DateTime.now().getTime() +
          '@testorg.com'
      );

      System.runAs(new User(Id = UserInfo.getUserId())) {
        insert stdUser;

        CustomPermission cpAdmin = [
          SELECT Id
          FROM CustomPermission
          WHERE DeveloperName = 'Workflow_Admin'
          LIMIT 1
        ];
        CustomPermission cpInject = [
          SELECT Id
          FROM CustomPermission
          WHERE DeveloperName = 'Workflow_Signal_Injection'
          LIMIT 1
        ];

        PermissionSet ps = new PermissionSet(
          Label = 'Workflow Admin and Inject PS',
          Name = 'Workflow_Admin_Inject_PS'
        );
        insert ps;

        insert new List<SetupEntityAccess>{
          new SetupEntityAccess(ParentId = ps.Id, SetupEntityId = cpAdmin.Id),
          new SetupEntityAccess(ParentId = ps.Id, SetupEntityId = cpInject.Id)
        };
        insert new PermissionSetAssignment(
          AssigneeId = stdUser.Id,
          PermissionSetId = ps.Id
        );
      }

      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
        Status__c = 'Suspended',
        Correlation_Key__c = 'SignalKey6',
        Input__c = '"InputData"'
      );
      insert inst;

      WorkflowEngine.disableQueueableInTest = true;

      System.runAs(stdUser) {
        Test.startTest();
        WorkflowDashboardController.injectSignal(
          inst.Id,
          'PaymentReceived',
          '{}'
        );
        Test.stopTest();
      }

      List<Workflow_Signal__c> signals = [
        SELECT Id, Signal_Name__c, Payload__c
        FROM Workflow_Signal__c
        WHERE Workflow_Instance__c = :inst.Id
      ];
      System.assertEquals(
        1,
        signals.size(),
        'Should have inserted one signal record'
      );
    }
  }

  @IsTest
  static void testInjectSignalExceptionMapping() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
        Status__c = 'Suspended',
        Correlation_Key__c = 'SignalKeyException',
        Input__c = '"InputData"'
      );
      insert inst;

      // Use a signal name that is too long (length > 255) to trigger a DmlException inside WorkflowEngine.signal
      String longSignalName = 'A'.repeat(300);

      try {
        WorkflowDashboardController.injectSignal(inst.Id, longSignalName, '{}');
        System.assert(
          false,
          'Should have thrown AuraHandledException due to DmlException mapping'
        );
      } catch (AuraHandledException e) {
        System.assertNotEquals(
          null,
          e.getMessage(),
          'Exception message should not be null'
        );
      }
    }
  }

  @IsTest
  static void testInjectSignalOversizedPayloadRejection() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
        Status__c = 'Suspended',
        Correlation_Key__c = 'SignalKeyOversized',
        Input__c = '"InputData"'
      );
      insert inst;

      String oversizedString = 'A'.repeat(250001);

      try {
        WorkflowDashboardController.injectSignal(
          inst.Id,
          'PaymentReceived',
          oversizedString
        );
        System.assert(
          false,
          'Should have thrown AuraHandledException due to oversized payload'
        );
      } catch (AuraHandledException e) {
        System.assert(
          e.getMessage().contains('Payload size exceeds maximum'),
          'Exception message should indicate payload size limit: ' +
          e.getMessage()
        );
      }
    }
  }

  @IsTest
  static void testResumePastStepControllerAuthorization() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Profile stdProfile = [
        SELECT Id
        FROM Profile
        WHERE Name = 'Standard User'
        LIMIT 1
      ];
      User stdUser = new User(
        Alias = 'stdno',
        Email = 'stdno@testorg.com',
        EmailEncodingKey = 'UTF-8',
        LastName = 'NoAdmin',
        LanguageLocaleKey = 'en_US',
        LocaleSidKey = 'en_US',
        ProfileId = stdProfile.Id,
        TimeZoneSidKey = 'America/Los_Angeles',
        UserName = 'stduser_noadmin_test_' +
          DateTime.now().getTime() +
          '@testorg.com'
      );
      insert stdUser;

      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
        Status__c = 'Failed',
        Correlation_Key__c = 'SkipKeyAuth'
      );
      insert inst;

      System.runAs(stdUser) {
        try {
          WorkflowDashboardController.resumePastStepInstance(
            inst.Id,
            'StepOne',
            '{}'
          );
          System.assert(false, 'Should have thrown AuraHandledException');
        } catch (AuraHandledException e) {
          System.assert(
            e.getMessage().contains('Unauthorized'),
            e.getMessage()
          );
        }
      }

    }
  }

  /**
   * Invokes resumePastStepInstance and returns the AuraHandledException message it
   * raises, or null if the call unexpectedly succeeded.
   * @param instanceId the workflow instance id to resume
   * @param stepName the past step to resume from
   * @param payload the resume payload
   * @return the rejection message, or null if no exception was thrown
   */
  private static String resumeRejectionMessage(
    Id instanceId,
    String stepName,
    String payload
  ) {
    try {
      WorkflowDashboardController.resumePastStepInstance(
        instanceId,
        stepName,
        payload
      );
      return null;
    } catch (AuraHandledException e) {
      return e.getMessage();
    }
  }

  @IsTest
  static void testResumePastStepControllerRejections() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
        Status__c = 'Running',
        Correlation_Key__c = 'SkipKeyRej'
      );
      insert inst;

      // Test: invalid status
      String msg = resumeRejectionMessage(inst.Id, 'StepOne', '{}');
      System.assertNotEquals(null, msg, 'Should fail for non-failed instance');
      System.assert(msg.contains('Resume past step is only allowed'), msg);

      // Test: null instance
      msg = resumeRejectionMessage(null, 'StepOne', '{}');
      System.assertNotEquals(null, msg, 'Should fail for null instance');
      System.assert(msg.contains('Instance ID is required'), msg);

      // Test: blank step name
      msg = resumeRejectionMessage(inst.Id, ' ', '{}');
      System.assertNotEquals(null, msg, 'Should fail for blank step name');
      System.assert(msg.contains('Step name is required'), msg);

      // Test: malformed JSON
      inst.Status__c = 'Failed';
      update as system inst;

      // We also need a mock step execution to test invalid step/JSON:
      Workflow_Step_Execution__c se = new Workflow_Step_Execution__c(
        Workflow_Instance__c = inst.Id,
        Step_Name__c = 'StepOne',
        Status__c = 'Failed'
      );
      insert as system se;

      inst.Current_Step__c = 'StepOne';
      update as system inst;

      msg = resumeRejectionMessage(inst.Id, 'StepOne', '{invalid_json}');
      System.assertNotEquals(null, msg, 'Should fail on invalid JSON');
      System.assert(msg.contains('valid JSON'), msg);

      // Test: oversized payload
      msg = resumeRejectionMessage(inst.Id, 'StepOne', 'A'.repeat(250001));
      System.assertNotEquals(null, msg, 'Should fail on oversized payload');
      System.assert(msg.contains('exceeds maximum allowed limit'), msg);

      // Test: CompensationFailed status (should fail, as there is resumeCompensation)
      inst.Status__c = 'CompensationFailed';
      update as system inst;
      msg = resumeRejectionMessage(inst.Id, 'StepOne', '{}');
      System.assertNotEquals(
        null,
        msg,
        'Should fail for CompensationFailed instance'
      );
      System.assert(
        msg.contains(
          'Resume past step is only allowed for instances in Failed state'
        ),
        msg
      );

      // Test: Reject reserved $attachmentId marker
      inst.Status__c = 'Failed';
      update as system inst;
      msg = resumeRejectionMessage(
        inst.Id,
        'StepOne',
        '{"$attachmentId":"069Sv00000KaTSzKAN"}'
      );
      System.assertNotEquals(
        null,
        msg,
        'Should fail on reserved $attachmentId marker'
      );
      System.assert(
        msg.contains('cannot contain reserved "$attachmentId" markers'),
        msg
      );

      // Test: Reject skipping a step that is not Failed (e.g. Pending)
      se.Status__c = 'Pending';
      update as system se;
      msg = resumeRejectionMessage(inst.Id, 'StepOne', '{}');
      System.assertNotEquals(
        null,
        msg,
        'Should fail for non-failed step execution'
      );
      System.assert(
        msg.contains('cannot be skipped because it is not in Failed status'),
        msg
      );
    }
  }

  @IsTest
  static void testGetInstanceDetailsIncludesBreadcrumbs() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
        Status__c = 'Running'
      );
      insert inst;

      Datetime now = Datetime.now();

      List<Workflow_Log__c> logs = new List<Workflow_Log__c>{
        new Workflow_Log__c(
          Workflow_Instance__c = inst.Id,
          Workflow_Name__c = inst.Workflow_Name__c,
          Log_Type__c = StepContext.LOG_TYPE_BREADCRUMB,
          Level__c = 'INFO',
          Message__c = 'Second Breadcrumb',
          Fire_Time__c = now.addSeconds(10)
        ),
        new Workflow_Log__c(
          Workflow_Instance__c = inst.Id,
          Workflow_Name__c = inst.Workflow_Name__c,
          Log_Type__c = StepContext.LOG_TYPE_BREADCRUMB,
          Level__c = 'INFO',
          Message__c = 'First Breadcrumb',
          Fire_Time__c = now
        ),
        new Workflow_Log__c(
          Workflow_Instance__c = inst.Id,
          Workflow_Name__c = inst.Workflow_Name__c,
          Log_Type__c = 'SomeOtherType', // should not be returned
          Level__c = 'INFO',
          Message__c = 'Not a breadcrumb',
          Fire_Time__c = now.addSeconds(5)
        )
      };
      insert logs;

      Test.startTest();
      Map<String, Object> result = WorkflowDashboardController.getInstanceDetails(
        inst.Id
      );
      Test.stopTest();

      System.assertNotEquals(null, result, 'Result should not be null');
      System.assert(
        result.containsKey('breadcrumbs'),
        'Result should contain breadcrumbs key'
      );

      List<Workflow_Log__c> breadcrumbs = (List<Workflow_Log__c>) result.get(
        'breadcrumbs'
      );
      System.assertEquals(
        2,
        breadcrumbs.size(),
        'Should only return StepBreadcrumb logs'
      );
      System.assertEquals(
        'First Breadcrumb',
        breadcrumbs[0].Message__c,
        'Chronological ordering by Fire_Time__c ASC failed'
      );
      System.assertEquals(
        'Second Breadcrumb',
        breadcrumbs[1].Message__c,
        'Chronological ordering by Fire_Time__c ASC failed'
      );
    }
  }
}
