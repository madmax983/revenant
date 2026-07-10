@IsTest
public class WorkflowAlertManagerTest {
  private static Workflow_Alert_Config__mdt createMockConfig(
    String devName,
    String recipients,
    Boolean enabled,
    Integer consecutiveLimit,
    Integer failLimit,
    Integer windowMin
  ) {
    return createMockConfig(
      devName,
      recipients,
      enabled,
      consecutiveLimit,
      failLimit,
      windowMin,
      false
    );
  }

  private static Workflow_Alert_Config__mdt createMockConfig(
    String devName,
    String recipients,
    Boolean enabled,
    Integer consecutiveLimit,
    Integer failLimit,
    Integer windowMin,
    Boolean publishEvent
  ) {
    Map<String, Object> fields = new Map<String, Object>{
      'DeveloperName' => devName,
      'Email_Recipients__c' => recipients,
      'Enable_Alerts__c' => enabled,
      'Consecutive_Failures_Limit__c' => consecutiveLimit,
      'Failure_Count_Limit__c' => failLimit,
      'Time_Window_Minutes__c' => windowMin,
      'Publish_Alert_Event__c' => publishEvent
    };
    return (Workflow_Alert_Config__mdt) JSON.deserialize(
      JSON.serialize(fields),
      Workflow_Alert_Config__mdt.class
    );
  }

  @IsTest
  static void testSendAlertWithMockConfig() {
    // Mock Config
    WorkflowAlertManager.mockConfigs.put(
      'WorkflowEngineTest_HappyWorkflow',
      createMockConfig(
        'WorkflowEngineTest_HappyWorkflow',
        'test@example.com',
        true,
        null,
        null,
        null
      )
    );
    WorkflowAlertManager.sentEmailsCount = 0;

    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
      Status__c = 'Failed',
      Correlation_Key__c = 'TestKey1'
    );
    insert inst;

    // Query Name to avoid SObjectException
    inst = [
      SELECT Id, Name, Workflow_Name__c, Status__c, Correlation_Key__c
      FROM Workflow_Instance__c
      WHERE Id = :inst.Id
    ];

    Test.startTest();
    WorkflowAlertManager.sendAlert(inst, 'Some error');
    Test.stopTest();

    System.assertEquals(
      1,
      WorkflowAlertManager.sentEmailsCount,
      'Alert should be sent'
    );
  }

  @IsTest
  static void testSendAlertWithDefaultConfigFallback() {
    // Setup only Default config in mock
    WorkflowAlertManager.mockConfigs.clear();
    WorkflowAlertManager.mockConfigs.put(
      'Default',
      createMockConfig('Default', 'default@example.com', true, null, null, null)
    );
    WorkflowAlertManager.sentEmailsCount = 0;

    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = 'SomeRandomWorkflow',
      Status__c = 'Failed'
    );
    insert inst;
    inst = [
      SELECT Id, Name, Workflow_Name__c, Status__c, Correlation_Key__c
      FROM Workflow_Instance__c
      WHERE Id = :inst.Id
    ];

    Test.startTest();
    WorkflowAlertManager.sendAlert(inst, 'Some fallback error');
    Test.stopTest();

    System.assertEquals(
      1,
      WorkflowAlertManager.sentEmailsCount,
      'Should fallback to Default and send alert'
    );
  }

  @IsTest
  static void testSendAlertWithTruncatedDevNameConfig() {
    String longWorkflowName = 'WorkflowEngineTest.HappyWorkflowWithVeryLongName';
    String expectedTruncatedDevName = longWorkflowName.replaceAll(
        '[^a-zA-Z0-9_]',
        '_'
      )
      .substring(0, 40);

    WorkflowAlertManager.mockConfigs.clear();
    WorkflowAlertManager.mockConfigs.put(
      expectedTruncatedDevName,
      createMockConfig(
        expectedTruncatedDevName,
        'longname@example.com',
        true,
        null,
        null,
        null
      )
    );
    WorkflowAlertManager.sentEmailsCount = 0;

    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = longWorkflowName,
      Status__c = 'Failed'
    );
    insert inst;
    inst = [
      SELECT Id, Name, Workflow_Name__c, Status__c, Correlation_Key__c
      FROM Workflow_Instance__c
      WHERE Id = :inst.Id
    ];

    Test.startTest();
    WorkflowAlertManager.sendAlert(inst, 'Long workflow name error');
    Test.stopTest();

    System.assertEquals(
      1,
      WorkflowAlertManager.sentEmailsCount,
      'Should resolve via truncated DeveloperName and send alert'
    );
  }

  @IsTest
  static void testSendAlertDisabled() {
    WorkflowAlertManager.mockConfigs.clear();
    WorkflowAlertManager.mockConfigs.put(
      'WorkflowEngineTest_HappyWorkflow',
      createMockConfig(
        'WorkflowEngineTest_HappyWorkflow',
        'test@example.com',
        false,
        null,
        null,
        null
      )
    );
    WorkflowAlertManager.sentEmailsCount = 0;

    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
      Status__c = 'Failed'
    );
    insert inst;
    inst = [
      SELECT Id, Name, Workflow_Name__c, Status__c, Correlation_Key__c
      FROM Workflow_Instance__c
      WHERE Id = :inst.Id
    ];

    Test.startTest();
    WorkflowAlertManager.sendAlert(inst, 'Some error');
    Test.stopTest();

    System.assertEquals(
      0,
      WorkflowAlertManager.sentEmailsCount,
      'No alert should be sent because config is disabled'
    );
  }

  @IsTest
  static void testSendAlertNoRecipients() {
    WorkflowAlertManager.mockConfigs.clear();
    WorkflowAlertManager.mockConfigs.put(
      'WorkflowEngineTest_HappyWorkflow',
      createMockConfig(
        'WorkflowEngineTest_HappyWorkflow',
        '',
        true,
        null,
        null,
        null
      )
    );
    WorkflowAlertManager.sentEmailsCount = 0;

    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
      Status__c = 'Failed'
    );
    insert inst;
    inst = [
      SELECT Id, Name, Workflow_Name__c, Status__c, Correlation_Key__c
      FROM Workflow_Instance__c
      WHERE Id = :inst.Id
    ];

    Test.startTest();
    WorkflowAlertManager.sendAlert(inst, 'Some error');
    Test.stopTest();

    System.assertEquals(
      0,
      WorkflowAlertManager.sentEmailsCount,
      'No alert should be sent when email recipients is blank'
    );
  }

  @IsTest
  static void testConsecutiveFailuresThreshold() {
    WorkflowAlertManager.mockConfigs.clear();
    WorkflowAlertManager.mockConfigs.put(
      'WorkflowEngineTest_HappyWorkflow',
      createMockConfig(
        'WorkflowEngineTest_HappyWorkflow',
        'test@example.com',
        true,
        3,
        null,
        null
      )
    );
    WorkflowAlertManager.sentEmailsCount = 0;

    String wfName = 'WorkflowEngineTest.HappyWorkflow';

    // Insert first failure
    Workflow_Instance__c inst1 = new Workflow_Instance__c(
      Workflow_Name__c = wfName,
      Status__c = 'Failed'
    );
    insert inst1;
    inst1 = [
      SELECT Id, Name, Workflow_Name__c, Status__c, Correlation_Key__c
      FROM Workflow_Instance__c
      WHERE Id = :inst1.Id
    ];

    WorkflowAlertManager.sendAlert(inst1, 'Err 1');
    System.assertEquals(
      0,
      WorkflowAlertManager.sentEmailsCount,
      'Not sent yet (consecutive count = 1, limit = 3)'
    );

    // Insert second failure
    Workflow_Instance__c inst2 = new Workflow_Instance__c(
      Workflow_Name__c = wfName,
      Status__c = 'Compensated'
    );
    insert inst2;
    inst2 = [
      SELECT Id, Name, Workflow_Name__c, Status__c, Correlation_Key__c
      FROM Workflow_Instance__c
      WHERE Id = :inst2.Id
    ];

    WorkflowAlertManager.sendAlert(inst2, 'Err 2');
    System.assertEquals(
      0,
      WorkflowAlertManager.sentEmailsCount,
      'Not sent yet (consecutive count = 2, limit = 3)'
    );

    // Insert third failure
    Workflow_Instance__c inst3 = new Workflow_Instance__c(
      Workflow_Name__c = wfName,
      Status__c = 'Failed'
    );
    insert inst3;
    inst3 = [
      SELECT Id, Name, Workflow_Name__c, Status__c, Correlation_Key__c
      FROM Workflow_Instance__c
      WHERE Id = :inst3.Id
    ];

    WorkflowAlertManager.sendAlert(inst3, 'Err 3');
    System.assertEquals(
      1,
      WorkflowAlertManager.sentEmailsCount,
      'Sent alert (consecutive count = 3, limit = 3)'
    );

    // Insert a completed one in between
    Workflow_Instance__c instComp = new Workflow_Instance__c(
      Workflow_Name__c = wfName,
      Status__c = 'Completed'
    );
    insert instComp;

    Workflow_Instance__c inst4 = new Workflow_Instance__c(
      Workflow_Name__c = wfName,
      Status__c = 'Failed'
    );
    insert inst4;
    inst4 = [
      SELECT Id, Name, Workflow_Name__c, Status__c, Correlation_Key__c
      FROM Workflow_Instance__c
      WHERE Id = :inst4.Id
    ];

    WorkflowAlertManager.sentEmailsCount = 0;
    WorkflowAlertManager.sendAlert(inst4, 'Err 4');
    System.assertEquals(
      0,
      WorkflowAlertManager.sentEmailsCount,
      'Not sent because consecutive was broken by Completed'
    );
  }

  @IsTest
  static void testSlidingWindowCountThreshold() {
    WorkflowAlertManager.mockConfigs.clear();
    WorkflowAlertManager.mockConfigs.put(
      'WorkflowEngineTest_HappyWorkflow',
      createMockConfig(
        'WorkflowEngineTest_HappyWorkflow',
        'test@example.com',
        true,
        null,
        2,
        10
      )
    );
    WorkflowAlertManager.sentEmailsCount = 0;

    String wfName = 'WorkflowEngineTest.HappyWorkflow';

    // Failure 1
    Workflow_Instance__c inst1 = new Workflow_Instance__c(
      Workflow_Name__c = wfName,
      Status__c = 'Failed'
    );
    insert inst1;
    inst1 = [
      SELECT Id, Name, Workflow_Name__c, Status__c, Correlation_Key__c
      FROM Workflow_Instance__c
      WHERE Id = :inst1.Id
    ];

    WorkflowAlertManager.sendAlert(inst1, 'Err 1');
    System.assertEquals(
      0,
      WorkflowAlertManager.sentEmailsCount,
      'Only 1 failure in window, need 2'
    );

    // Failure 2
    Workflow_Instance__c inst2 = new Workflow_Instance__c(
      Workflow_Name__c = wfName,
      Status__c = 'Cancelled'
    );
    insert inst2;
    inst2 = [
      SELECT Id, Name, Workflow_Name__c, Status__c, Correlation_Key__c
      FROM Workflow_Instance__c
      WHERE Id = :inst2.Id
    ];

    WorkflowAlertManager.sendAlert(inst2, 'Err 2');
    System.assertEquals(
      1,
      WorkflowAlertManager.sentEmailsCount,
      '2 failures in window met, alert sent'
    );
  }

  @IsTest
  static void testWorkflowEngineAlertIntegration() {
    // Enforce mock configs
    WorkflowAlertManager.mockConfigs.clear();
    WorkflowAlertManager.mockConfigs.put(
      'WorkflowEngineTest_HappyWorkflow',
      createMockConfig(
        'WorkflowEngineTest_HappyWorkflow',
        'test@example.com',
        true,
        null,
        null,
        null
      )
    );
    WorkflowAlertManager.sentEmailsCount = 0;

    // Create a workflow instance that starts directly
    WorkflowEngine.disableQueueableInTest = true;

    // Let's create an instance, set current step to something that will fail immediately
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
      Status__c = 'Running',
      Current_Step__c = 'WorkflowEngineTest.FailureStep'
    );
    insert inst;

    Workflow_Step_Execution__c stepExec = new Workflow_Step_Execution__c(
      Workflow_Instance__c = inst.Id,
      Step_Name__c = 'WorkflowEngineTest.FailureStep',
      Status__c = 'Running',
      Retry_Count__c = 0
    );
    insert stepExec;

    Test.startTest();
    // Running step which fails will run, exceed retry limits,
    // we call WorkflowEngine.failWorkflowInstance directly to test the engine's failure path
    WorkflowEngine.failWorkflowInstance(
      inst.Id,
      'WorkflowEngineTest.FailureStep',
      'Crashed and burned'
    );
    Test.stopTest();

    // The failWorkflowInstance should transition the instance status to Failed and send an alert
    Workflow_Instance__c updatedInst = [
      SELECT Status__c, Error_Message__c
      FROM Workflow_Instance__c
      WHERE Id = :inst.Id
    ];
    System.assertEquals('Failed', updatedInst.Status__c);
    System.assertEquals(
      1,
      WorkflowAlertManager.sentEmailsCount,
      'Alert should be triggered by WorkflowEngine failure'
    );
  }

  @IsTest
  static void testWorkflowWatchdogAlert() {
    WorkflowAlertManager.mockConfigs.clear();
    WorkflowAlertManager.mockConfigs.put(
      'WorkflowEngineTest_HappyWorkflow',
      createMockConfig(
        'WorkflowEngineTest_HappyWorkflow',
        'timeout@example.com',
        true,
        null,
        null,
        null
      )
    );
    WorkflowAlertManager.sentEmailsCount = 0;

    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
      Status__c = 'Running',
      Current_Step__c = 'SomeStep'
    );
    insert as system inst;

    Workflow_Step_Execution__c stepExec = new Workflow_Step_Execution__c(
      Workflow_Instance__c = inst.Id,
      Step_Name__c = 'SomeStep',
      Status__c = 'Running',
      Timeout_At__c = DateTime.now().addSeconds(-10)
    );
    insert as system stepExec;

    Test.startTest();
    WorkflowEngine.processWatchdogHeartbeat();
    Test.stopTest();

    Workflow_Instance__c updatedInst = [
      SELECT Status__c
      FROM Workflow_Instance__c
      WHERE Id = :inst.Id
    ];
    System.assertEquals('Failed', updatedInst.Status__c);
    System.assertEquals(
      1,
      WorkflowAlertManager.sentEmailsCount,
      'Alert should be sent on timeout'
    );
  }

  @IsTest
  static void testSendEmailExceptionIsolation() {
    WorkflowAlertManager.mockConfigs.clear();
    WorkflowAlertManager.mockConfigs.put(
      'WorkflowEngineTest_HappyWorkflow',
      createMockConfig(
        'WorkflowEngineTest_HappyWorkflow',
        'test@example.com',
        true,
        null,
        null,
        null
      )
    );
    WorkflowAlertManager.sentEmailsCount = 0;
    WorkflowAlertManager.throwTestException = true;

    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
      Status__c = 'Failed'
    );
    insert inst;
    inst = [
      SELECT Id, Name, Workflow_Name__c, Status__c, Correlation_Key__c
      FROM Workflow_Instance__c
      WHERE Id = :inst.Id
    ];

    Test.startTest();
    try {
      WorkflowAlertManager.sendAlert(inst, 'Some error');
      System.assert(true, 'Should not throw exception');
    } catch (Exception e) {
      System.assert(
        false,
        'Should have caught and isolated email exception, but got: ' +
        e.getMessage()
      );
    }
    Test.stopTest();

    System.assertEquals(1, WorkflowAlertManager.sentEmailsCount);
    WorkflowAlertManager.throwTestException = false;
  }

  @IsTest
  static void testHtmlEscapingAndErrorTruncation() {
    String xssWfName = 'WorkflowEngineTest.HappyWorkflow<script>';
    String devName = xssWfName.replaceAll('[^a-zA-Z0-9_]', '_');
    String truncatedDevName = devName.length() > 40
      ? devName.substring(0, 40)
      : devName;

    WorkflowAlertManager.mockConfigs.clear();
    WorkflowAlertManager.mockConfigs.put(
      truncatedDevName,
      createMockConfig(
        truncatedDevName,
        'test@example.com',
        true,
        null,
        null,
        null
      )
    );
    WorkflowAlertManager.sentEmailsCount = 0;

    String xssCorrelation = 'Key & Value > XSS';

    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = xssWfName,
      Status__c = 'Failed',
      Correlation_Key__c = xssCorrelation
    );
    insert inst;
    inst = [
      SELECT Id, Name, Workflow_Name__c, Status__c, Correlation_Key__c
      FROM Workflow_Instance__c
      WHERE Id = :inst.Id
    ];

    String longPart = 'A'.repeat(5010);

    Test.startTest();
    WorkflowAlertManager.sendAlert(inst, longPart + '<script>');
    Test.stopTest();

    String html = WorkflowAlertManager.lastHtmlBody;
    System.assertNotEquals(null, html);

    System.assert(
      !html.contains(xssWfName),
      'Workflow Name must be HTML-escaped'
    );
    System.assert(
      html.contains('WorkflowEngineTest.HappyWorkflow&lt;script&gt;'),
      'Escaped Workflow Name should be present'
    );

    System.assert(
      !html.contains(xssCorrelation),
      'Correlation Key must be HTML-escaped'
    );
    System.assert(
      html.contains('Key &amp; Value &gt; XSS'),
      'Escaped Correlation Key should be present'
    );

    System.assert(
      html.contains(inst.Name.escapeHtml4()),
      'Name should be escaped'
    );
    System.assert(
      html.contains(String.valueOf(inst.Id).escapeHtml4()),
      'Id should be escaped'
    );

    System.assert(
      html.contains('... (truncated)'),
      'Should contain the truncation suffix'
    );
    String expectedErrorDetails = 'A'.repeat(5000) + '... (truncated)';
    System.assert(
      html.contains(expectedErrorDetails),
      'Should contain exactly 5000 characters of error details plus the truncation indicator'
    );
  }

  @IsTest
  static void testSlidingWindowUsesTerminalAtDate() {
    WorkflowAlertManager.mockConfigs.clear();
    WorkflowAlertManager.mockConfigs.put(
      'WorkflowEngineTest_HappyWorkflow',
      createMockConfig(
        'WorkflowEngineTest_HappyWorkflow',
        'test@example.com',
        true,
        null,
        1,
        10
      )
    );
    WorkflowAlertManager.sentEmailsCount = 0;

    String wfName = 'WorkflowEngineTest.HappyWorkflow';

    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = wfName,
      Status__c = 'Running'
    );
    insert inst;

    Test.setCreatedDate(inst.Id, Datetime.now().addMinutes(-20));

    inst.Status__c = 'Failed';

    Test.startTest();
    update inst;

    Workflow_Instance__c queriedInst = [
      SELECT Id, Name, Workflow_Name__c, Status__c, Correlation_Key__c
      FROM Workflow_Instance__c
      WHERE Id = :inst.Id
    ];
    WorkflowAlertManager.sendAlert(queriedInst, 'Failed step');
    Test.stopTest();

    System.assertEquals(
      1,
      WorkflowAlertManager.sentEmailsCount,
      'Alert should be sent because Terminal_At__c is within the window'
    );
  }

  @IsTest
  static void testSlidingWindowExcludesStaleModifiedDates() {
    WorkflowAlertManager.mockConfigs.clear();
    WorkflowAlertManager.mockConfigs.put(
      'WorkflowEngineTest_HappyWorkflow',
      createMockConfig(
        'WorkflowEngineTest_HappyWorkflow',
        'test@example.com',
        true,
        null,
        1,
        10
      )
    );
    WorkflowAlertManager.sentEmailsCount = 0;

    String wfName = 'WorkflowEngineTest.HappyWorkflow';

    // Insert an already Failed instance
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = wfName,
      Status__c = 'Failed'
    );
    insert as system inst; // sets Terminal_At__c = System.now()

    // Manually push Terminal_At__c back by 20 minutes (outside the 10 minute window)
    inst.Terminal_At__c = Datetime.now().addMinutes(-20);
    update as system inst;

    // Verify it is not counted in the window now
    Workflow_Instance__c queriedInst = [
      SELECT
        Id,
        Name,
        Workflow_Name__c,
        Status__c,
        Correlation_Key__c,
        Terminal_At__c
      FROM Workflow_Instance__c
      WHERE Id = :inst.Id
      WITH SYSTEM_MODE
    ];

    Test.startTest();
    WorkflowAlertManager.sendAlert(
      queriedInst,
      'Alert triggered by a later update'
    );
    Test.stopTest();

    System.assertEquals(
      0,
      WorkflowAlertManager.sentEmailsCount,
      'No alert should be sent because the terminal failure timestamp is outside the window, despite the recent update'
    );
  }

  @IsTest
  static void testSendAlertBestEffortIsolation() {
    Test.startTest();
    try {
      WorkflowAlertManager.sendAlert(null, 'Some error');
      System.assert(
        true,
        'Null pointer exception should be caught inside sendAlert'
      );
    } catch (Exception ex) {
      System.assert(
        false,
        'Should have caught all exceptions in sendAlert, but got: ' +
        ex.getMessage()
      );
    }
    Test.stopTest();
  }

  @IsTest
  static void testSendAlertPublishEventConsecutive() {
    String wfName = 'WorkflowEngineTest.HappyWorkflow';
    WorkflowAlertManager.mockConfigs.clear();
    WorkflowAlertManager.mockConfigs.put(
      'WorkflowEngineTest_HappyWorkflow',
      createMockConfig(
        'WorkflowEngineTest_HappyWorkflow',
        'test@example.com',
        true,
        3,
        null,
        null,
        true
      )
    );
    WorkflowAlertManager.sentEmailsCount = 0;
    WorkflowAlertManager.publishedEvents.clear();

    // Insert first two failures
    Workflow_Instance__c inst1 = new Workflow_Instance__c(
      Workflow_Name__c = wfName,
      Status__c = 'Failed'
    );
    Workflow_Instance__c inst2 = new Workflow_Instance__c(
      Workflow_Name__c = wfName,
      Status__c = 'Failed'
    );
    insert new List<Workflow_Instance__c>{ inst1, inst2 };

    // Third failure
    Workflow_Instance__c inst3 = new Workflow_Instance__c(
      Workflow_Name__c = wfName,
      Status__c = 'Failed',
      Correlation_Key__c = 'Corr3'
    );
    insert inst3;
    inst3 = [
      SELECT Id, Name, Workflow_Name__c, Status__c, Correlation_Key__c
      FROM Workflow_Instance__c
      WHERE Id = :inst3.Id
    ];

    Test.startTest();
    WorkflowAlertManager.sendAlert(inst3, 'Error 3');
    Test.stopTest();

    System.assertEquals(
      1,
      WorkflowAlertManager.sentEmailsCount,
      'Should send email'
    );
    System.assertEquals(
      1,
      WorkflowAlertManager.publishedEvents.size(),
      'Should publish one event'
    );

    Workflow_Alert__e evt = WorkflowAlertManager.publishedEvents[0];
    System.assertEquals(wfName, evt.Workflow_Name__c);
    System.assertEquals(inst3.Id, evt.Workflow_Instance_Id__c);
    System.assertEquals('Corr3', evt.Correlation_Key__c);
    System.assertEquals('Error 3', evt.Error_Message__c);
    System.assertEquals('Consecutive Failures', evt.Alert_Reason__c);
    System.assertEquals(3, evt.Consecutive_Failures_Limit__c);
    System.assertEquals(null, evt.Failure_Count_Limit__c);
    System.assertEquals(null, evt.Time_Window_Minutes__c);
  }

  @IsTest
  static void testSendAlertPublishEventSlidingWindow() {
    String wfName = 'WorkflowEngineTest.HappyWorkflow';
    WorkflowAlertManager.mockConfigs.clear();
    WorkflowAlertManager.mockConfigs.put(
      'WorkflowEngineTest_HappyWorkflow',
      createMockConfig(
        'WorkflowEngineTest_HappyWorkflow',
        'test@example.com',
        true,
        null,
        2,
        10,
        true
      )
    );
    WorkflowAlertManager.sentEmailsCount = 0;
    WorkflowAlertManager.publishedEvents.clear();

    // First failure
    Workflow_Instance__c inst1 = new Workflow_Instance__c(
      Workflow_Name__c = wfName,
      Status__c = 'Failed'
    );
    insert inst1;

    // Second failure
    Workflow_Instance__c inst2 = new Workflow_Instance__c(
      Workflow_Name__c = wfName,
      Status__c = 'Failed',
      Correlation_Key__c = 'CorrSliding'
    );
    insert inst2;
    inst2 = [
      SELECT Id, Name, Workflow_Name__c, Status__c, Correlation_Key__c
      FROM Workflow_Instance__c
      WHERE Id = :inst2.Id
    ];

    Test.startTest();
    WorkflowAlertManager.sendAlert(inst2, 'Error Sliding');
    Test.stopTest();

    System.assertEquals(
      1,
      WorkflowAlertManager.sentEmailsCount,
      'Should send email'
    );
    System.assertEquals(
      1,
      WorkflowAlertManager.publishedEvents.size(),
      'Should publish event'
    );

    Workflow_Alert__e evt = WorkflowAlertManager.publishedEvents[0];
    System.assertEquals(wfName, evt.Workflow_Name__c);
    System.assertEquals(inst2.Id, evt.Workflow_Instance_Id__c);
    System.assertEquals('CorrSliding', evt.Correlation_Key__c);
    System.assertEquals('Error Sliding', evt.Error_Message__c);
    System.assertEquals('Sliding Window', evt.Alert_Reason__c);
    System.assertEquals(null, evt.Consecutive_Failures_Limit__c);
    System.assertEquals(2, evt.Failure_Count_Limit__c);
    System.assertEquals(10, evt.Time_Window_Minutes__c);
  }

  @IsTest
  static void testSendAlertPublishEventImmediate() {
    String wfName = 'WorkflowEngineTest.HappyWorkflow';
    WorkflowAlertManager.mockConfigs.clear();
    WorkflowAlertManager.mockConfigs.put(
      'WorkflowEngineTest_HappyWorkflow',
      createMockConfig(
        'WorkflowEngineTest_HappyWorkflow',
        'test@example.com',
        true,
        null,
        null,
        null,
        true
      )
    );
    WorkflowAlertManager.sentEmailsCount = 0;
    WorkflowAlertManager.publishedEvents.clear();

    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = wfName,
      Status__c = 'Failed',
      Correlation_Key__c = 'CorrImmediate'
    );
    insert inst;
    inst = [
      SELECT Id, Name, Workflow_Name__c, Status__c, Correlation_Key__c
      FROM Workflow_Instance__c
      WHERE Id = :inst.Id
    ];

    Test.startTest();
    WorkflowAlertManager.sendAlert(inst, 'Immediate error');
    Test.stopTest();

    System.assertEquals(
      1,
      WorkflowAlertManager.sentEmailsCount,
      'Should send email'
    );
    System.assertEquals(
      1,
      WorkflowAlertManager.publishedEvents.size(),
      'Should publish event'
    );

    Workflow_Alert__e evt = WorkflowAlertManager.publishedEvents[0];
    System.assertEquals(wfName, evt.Workflow_Name__c);
    System.assertEquals(inst.Id, evt.Workflow_Instance_Id__c);
    System.assertEquals('CorrImmediate', evt.Correlation_Key__c);
    System.assertEquals('Immediate error', evt.Error_Message__c);
    System.assertEquals('Immediate', evt.Alert_Reason__c);
    System.assertEquals(null, evt.Consecutive_Failures_Limit__c);
    System.assertEquals(null, evt.Failure_Count_Limit__c);
    System.assertEquals(null, evt.Time_Window_Minutes__c);
  }

  @IsTest
  static void testSendAlertEventOnlyNoEmail() {
    String wfName = 'WorkflowEngineTest.HappyWorkflow';
    WorkflowAlertManager.mockConfigs.clear();
    // Publish true, but recipients empty
    WorkflowAlertManager.mockConfigs.put(
      'WorkflowEngineTest_HappyWorkflow',
      createMockConfig(
        'WorkflowEngineTest_HappyWorkflow',
        '',
        true,
        null,
        null,
        null,
        true
      )
    );
    WorkflowAlertManager.sentEmailsCount = 0;
    WorkflowAlertManager.publishedEvents.clear();

    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = wfName,
      Status__c = 'Failed',
      Correlation_Key__c = 'CorrEventOnly'
    );
    insert inst;
    inst = [
      SELECT Id, Name, Workflow_Name__c, Status__c, Correlation_Key__c
      FROM Workflow_Instance__c
      WHERE Id = :inst.Id
    ];

    Test.startTest();
    WorkflowAlertManager.sendAlert(inst, 'Event only error');
    Test.stopTest();

    System.assertEquals(
      0,
      WorkflowAlertManager.sentEmailsCount,
      'Should NOT send email'
    );
    System.assertEquals(
      1,
      WorkflowAlertManager.publishedEvents.size(),
      'Should publish event'
    );

    Workflow_Alert__e evt = WorkflowAlertManager.publishedEvents[0];
    System.assertEquals(wfName, evt.Workflow_Name__c);
    System.assertEquals(inst.Id, evt.Workflow_Instance_Id__c);
    System.assertEquals('CorrEventOnly', evt.Correlation_Key__c);
    System.assertEquals('Event only error', evt.Error_Message__c);
    System.assertEquals('Immediate', evt.Alert_Reason__c);
  }

  @IsTest
  static void testSendAlertNoEventIfToggleDisabled() {
    String wfName = 'WorkflowEngineTest.HappyWorkflow';
    WorkflowAlertManager.mockConfigs.clear();
    // Publish false, recipients filled
    WorkflowAlertManager.mockConfigs.put(
      'WorkflowEngineTest_HappyWorkflow',
      createMockConfig(
        'WorkflowEngineTest_HappyWorkflow',
        'test@example.com',
        true,
        null,
        null,
        null,
        false
      )
    );
    WorkflowAlertManager.sentEmailsCount = 0;
    WorkflowAlertManager.publishedEvents.clear();

    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = wfName,
      Status__c = 'Failed',
      Correlation_Key__c = 'CorrNoEvent'
    );
    insert inst;
    inst = [
      SELECT Id, Name, Workflow_Name__c, Status__c, Correlation_Key__c
      FROM Workflow_Instance__c
      WHERE Id = :inst.Id
    ];

    Test.startTest();
    WorkflowAlertManager.sendAlert(inst, 'No event error');
    Test.stopTest();

    System.assertEquals(
      1,
      WorkflowAlertManager.sentEmailsCount,
      'Should send email'
    );
    System.assertEquals(
      0,
      WorkflowAlertManager.publishedEvents.size(),
      'Should NOT publish event'
    );
  }

  @IsTest
  static void testSendAlertEventSkippedIfDmlBudgetExhausted() {
    String wfName = 'WorkflowEngineTest.HappyWorkflow';
    WorkflowAlertManager.mockConfigs.clear();
    WorkflowAlertManager.mockConfigs.put(
      'WorkflowEngineTest_HappyWorkflow',
      createMockConfig(
        'WorkflowEngineTest_HappyWorkflow',
        '',
        true,
        null,
        null,
        null,
        true
      )
    );
    WorkflowAlertManager.sentEmailsCount = 0;
    WorkflowAlertManager.publishedEvents.clear();
    WorkflowAlertManager.forceDmlBudgetExhausted = true;

    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = wfName,
      Status__c = 'Failed',
      Correlation_Key__c = 'CorrDmlExhausted'
    );
    insert inst;
    inst = [
      SELECT Id, Name, Workflow_Name__c, Status__c, Correlation_Key__c
      FROM Workflow_Instance__c
      WHERE Id = :inst.Id
    ];

    Test.startTest();
    WorkflowAlertManager.sendAlert(inst, 'Skipped error');
    Test.stopTest();

    System.assertEquals(
      0,
      WorkflowAlertManager.sentEmailsCount,
      'Should NOT send email'
    );
    System.assertEquals(
      0,
      WorkflowAlertManager.publishedEvents.size(),
      'Should NOT publish event because DML budget is exhausted'
    );

    // Reset state
    WorkflowAlertManager.forceDmlBudgetExhausted = false;
  }
}
