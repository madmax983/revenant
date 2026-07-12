/**
 * These tests do NOT use WorkflowTestHarness because they exercise engine
 * internals rather than the workflow DAG:
 *
 *  - testCalloutSuccess / testCalloutFailureAndRetry use Test.stopTest() to fire
 *    the enqueued Queueable, which is the correct way to test the async-callout
 *    suspend/resume handshake with the platform scheduler.
 *  - testCalloutTimeoutWatchdog / testTimeoutTriggersSagaCompensation inject
 *    raw DB state (Running step with expired Timeout_At__c) and call
 *    processWatchdogHeartbeat() directly — they are unit tests of the watchdog
 *    sweep path, not the workflow DAG.
 *  - testCalloutAsyncRetryFlow exercises the future-method/resume handshake step
 *    by step; the harness cannot intercept future method execution.
 *
 * See docs/testing.md §"When not to use the harness" for the full rationale.
 */
@IsTest
public class CalloutTimeoutWorkflowExampleTest {
  private class SingleRequestMock implements HttpCalloutMock {
    private Integer code;
    private String body;

    /**
     * @description Builds a mock that always replies with the given status and body.
     * @param code The HTTP status code to return.
     * @param body The response body to return.
     */
    public SingleRequestMock(Integer code, String body) {
      this.code = code;
      this.body = body;
    }

    /**
     * @description Returns the pre-configured status code and body for any request.
     * @param req The outbound HTTP request being mocked.
     * @return The stubbed HTTP response.
     */
    public HttpResponse respond(HttpRequest req) {
      HttpResponse res = new HttpResponse();
      res.setStatusCode(this.code);
      res.setBody(this.body);
      return res;
    }
  }

  @IsTest
  static void testCalloutSuccess() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Enforce mock configs to prevent DB alerts dependency
      WorkflowAlertManager.mockConfigs.put(
        'CalloutTimeoutWorkflowExample_CalloutWorkflow',
        (Workflow_Alert_Config__mdt) JSON.deserialize(
          '{"DeveloperName":"CalloutTimeoutWorkflowExample_CalloutWorkflow", "Email_Recipients__c":"test@example.com", "Enable_Alerts__c":true}',
          Workflow_Alert_Config__mdt.class
        )
      );
      WorkflowAlertManager.sentEmailsCount = 0;

      // Set Http Callout Mock
      Test.setMock(
        HttpCalloutMock.class,
        new SingleRequestMock(200, '{"success": true}')
      );

      Test.startTest();
      // Pass a Map to prevent double serialization of input
      Id instanceId = WorkflowEngine.start(
        'CalloutTimeoutWorkflowExample.CalloutWorkflow',
        'CalloutSuccessKey',
        new Map<String, Object>{
          'endpoint' => 'https://httpbin.org/status/200'
        }
      );
      Test.stopTest(); // Executes the enqueued orchestrator queueable

      Workflow_Instance__c inst = [
        SELECT Status__c, Error_Message__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      System.assertEquals('Completed', inst.Status__c, 'Should be Completed');
      System.assertEquals(
        0,
        WorkflowAlertManager.sentEmailsCount,
        'No alert should be sent'
      );
    }
  }

  @IsTest
  static void testCalloutFailureAndRetry() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowAlertManager.mockConfigs.put(
        'CalloutTimeoutWorkflowExample_CalloutWorkflow',
        (Workflow_Alert_Config__mdt) JSON.deserialize(
          '{"DeveloperName":"CalloutTimeoutWorkflowExample_CalloutWorkflow", "Email_Recipients__c":"test@example.com", "Enable_Alerts__c":true}',
          Workflow_Alert_Config__mdt.class
        )
      );
      WorkflowAlertManager.sentEmailsCount = 0;

      // Mock 500 error
      Test.setMock(HttpCalloutMock.class, new SingleRequestMock(500, 'Error'));

      Test.startTest();
      Id instanceId = WorkflowEngine.start(
        'CalloutTimeoutWorkflowExample.CalloutWorkflow',
        'CalloutRetryKey',
        null
      );
      Test.stopTest(); // Executes the enqueued orchestrator queueable

      List<Workflow_Step_Execution__c> stepExecs = [
        SELECT Status__c, Retry_Count__c
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Step_Name__c = 'CalloutTimeoutWorkflowExample.MakeHttpCalloutStep'
        ORDER BY CreatedDate DESC, Id DESC
      ];
      System.assert(!stepExecs.isEmpty());
      System.assertEquals(
        'Retrying',
        stepExecs[0].Status__c,
        'Step status should be Retrying'
      );
      System.assertEquals(
        1,
        stepExecs[0].Retry_Count__c,
        'Retry count should be 1'
      );
    }
  }

  @IsTest
  static void testCalloutTimeoutWatchdog() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowAlertManager.mockConfigs.put(
        'CalloutTimeoutWorkflowExample_CalloutWorkflow',
        (Workflow_Alert_Config__mdt) JSON.deserialize(
          '{"DeveloperName":"CalloutTimeoutWorkflowExample_CalloutWorkflow", "Email_Recipients__c":"test@example.com", "Enable_Alerts__c":true}',
          Workflow_Alert_Config__mdt.class
        )
      );
      WorkflowAlertManager.sentEmailsCount = 0;

      // Start workflow instance and let the initial queueable run
      Id instanceId = WorkflowEngine.start(
        'CalloutTimeoutWorkflowExample.CalloutWorkflow',
        'CalloutTimeoutKey',
        null
      );

      Test.startTest();
      // Test.stopTest() executes the enqueued queueable to process the initial step run (which fails & schedules retry)
      Test.stopTest();

      Workflow_Instance__c inst = [
        SELECT Status__c, Current_Step__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];

      // Simulate step hanging in Running status
      inst.Status__c = 'Running';
      inst.Current_Step__c = 'CalloutTimeoutWorkflowExample.MakeHttpCalloutStep';
      update inst;

      List<Workflow_Step_Execution__c> stepExecs = [
        SELECT Id, Status__c
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Step_Name__c = 'CalloutTimeoutWorkflowExample.MakeHttpCalloutStep'
        LIMIT 1
      ];
      System.assert(!stepExecs.isEmpty());
      Workflow_Step_Execution__c stepExec = stepExecs[0];
      stepExec.Status__c = 'Running';
      stepExec.Timeout_At__c = DateTime.now().addSeconds(-10);
      update as system stepExec;

      // Execute watchdog heartbeat
      WorkflowEngine.processWatchdogHeartbeat();

      // Verify status transitioned to Failed and email alert sent
      Workflow_Instance__c updatedInst = [
        SELECT Status__c, Error_Message__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      System.assertEquals(
        'Failed',
        updatedInst.Status__c,
        'Instance should fail due to timeout'
      );
      System.assert(
        updatedInst.Error_Message__c.contains('timed out'),
        'Error message should contain timeout details'
      );
      System.assertEquals(
        1,
        WorkflowAlertManager.sentEmailsCount,
        'Email alert should be dispatched on watchdog timeout'
      );
    }
  }

  @IsTest
  static void testCalloutAsyncRetryFlow() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowAlertManager.mockConfigs.put(
        'CalloutTimeoutWorkflowExample_CalloutWorkflow',
        (Workflow_Alert_Config__mdt) JSON.deserialize(
          '{"DeveloperName":"CalloutTimeoutWorkflowExample_CalloutWorkflow", "Email_Recipients__c":"test@example.com", "Enable_Alerts__c":true}',
          Workflow_Alert_Config__mdt.class
        )
      );
      WorkflowAlertManager.sentEmailsCount = 0;

      // Force async callout path in tests
      CalloutTimeoutWorkflowExample.forceAsyncInTest = true;

      // Mock a 500 error response from the HTTP callout
      Test.setMock(
        HttpCalloutMock.class,
        new SingleRequestMock(500, 'Internal Server Error')
      );

      Test.startTest();
      // 1. Start workflow - executes MakeHttpCalloutStep for the first time
      // This enqueues the AsyncCalloutJob queueable and returns StepResult.suspend()
      Id instanceId = WorkflowEngine.start(
        'CalloutTimeoutWorkflowExample.CalloutWorkflow',
        'CalloutAsyncRetryKey',
        new Map<String, Object>{
          'endpoint' => 'https://httpbin.org/status/500'
        }
      );
      Test.stopTest(); // Executes the queueable to run the first step and suspend

      // In unit tests, nested asynchronous operations (queueable enqueued inside queueable)
      // are not executed automatically. We call the synchronous helper directly to simulate completion.
      CalloutTimeoutWorkflowExample.doCalloutAndResume(
        instanceId,
        'https://httpbin.org/status/500'
      );

      // Verify that the instance status became Running (since resumeInstance sets it to Running)
      Workflow_Instance__c inst = [
        SELECT Status__c, Current_Step__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      System.assertEquals('Running', inst.Status__c);
      System.assertEquals(
        'CalloutTimeoutWorkflowExample.MakeHttpCalloutStep',
        inst.Current_Step__c
      );

      // Verify the step execution has status 'Running' and Output__c contains the 500 response payload
      List<Workflow_Step_Execution__c> stepExecs = [
        SELECT Status__c, Output__c, Retry_Count__c
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Step_Name__c = 'CalloutTimeoutWorkflowExample.MakeHttpCalloutStep'
        ORDER BY CreatedDate DESC, Id DESC
      ];
      System.assertEquals(1, stepExecs.size());
      System.assertEquals('Running', stepExecs[0].Status__c);
      System.assert(String.isNotBlank(stepExecs[0].Output__c));
      System.assert(stepExecs[0].Output__c.contains('status'));
      System.assert(stepExecs[0].Output__c.contains('500'));

      // 2. Manually run the orchestrator to process the resumed step
      // The step will see the 500 response, return StepResult.retry(), and clear its Output__c
      new WorkflowOrchestrator(instanceId).execute(null);

      // Verify the step is now in 'Retrying' status, Retry_Count__c is 1, and Output__c is cleared (null)
      stepExecs = [
        SELECT Status__c, Output__c, Retry_Count__c
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Step_Name__c = 'CalloutTimeoutWorkflowExample.MakeHttpCalloutStep'
        ORDER BY CreatedDate DESC, Id DESC
      ];
      System.assertEquals(1, stepExecs.size());
      System.assertEquals('Retrying', stepExecs[0].Status__c);
      System.assertEquals(1, stepExecs[0].Retry_Count__c);
      System.assertEquals(
        null,
        stepExecs[0].Output__c,
        'Cached output should be cleared on retry transition'
      );

      // 3. Manually run the orchestrator again to execute the retry attempt
      // Since Output__c is cleared, execute() sees a blank stepStateJson and will enqueue AsyncCalloutJob again
      new WorkflowOrchestrator(instanceId).execute(null);

      // Verify step execution returned back to 'Pending' (because of StepResult.suspend() waiting for the second callout)
      stepExecs = [
        SELECT Status__c, Output__c, Retry_Count__c
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Step_Name__c = 'CalloutTimeoutWorkflowExample.MakeHttpCalloutStep'
        ORDER BY CreatedDate DESC, Id DESC
      ];
      System.assertEquals(1, stepExecs.size());
      System.assertEquals(
        'Pending',
        stepExecs[0].Status__c,
        'Step should suspend and wait for the new callout'
      );
    }
  }

  @IsTest
  static void testTimeoutTriggersSagaCompensation() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      // Start workflow instance and let the initial queueable run
      Id instanceId = WorkflowEngine.start(
        'CalloutTimeoutWorkflowExample.CalloutWorkflow',
        'TimeoutSagaKey',
        null
      );

      Test.startTest();
      Test.stopTest(); // executes the starting queueable

      Workflow_Instance__c inst = [
        SELECT Status__c, Current_Step__c, Compensation_Stack__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];

      // Populate Compensation Stack and simulate running step
      inst.Status__c = 'Running';
      inst.Current_Step__c = 'CalloutTimeoutWorkflowExample.MakeHttpCalloutStep';
      inst.Compensation_Stack__c = JSON.serialize(
        new List<String>{ 'SagaWorkflowExample.ChargeCreditCardStep' }
      );
      update inst;

      List<Workflow_Step_Execution__c> stepExecs = [
        SELECT Id, Status__c
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Step_Name__c = 'CalloutTimeoutWorkflowExample.MakeHttpCalloutStep'
        LIMIT 1
      ];
      if (stepExecs.isEmpty()) {
        Workflow_Step_Execution__c newStepExec = new Workflow_Step_Execution__c(
          Workflow_Instance__c = instanceId,
          Step_Name__c = 'CalloutTimeoutWorkflowExample.MakeHttpCalloutStep',
          Status__c = 'Running',
          Retry_Count__c = 0,
          Timeout_At__c = DateTime.now().addSeconds(-10)
        );
        insert as system newStepExec;
      } else {
        Workflow_Step_Execution__c stepExec = stepExecs[0];
        stepExec.Status__c = 'Running';
        stepExec.Timeout_At__c = DateTime.now().addSeconds(-10);
        update as system stepExec;
      }

      // Execute watchdog heartbeat
      WorkflowEngine.processWatchdogHeartbeat();

      // Verify status transitioned to Compensating instead of Failed due to populated compensation stack
      Workflow_Instance__c updatedInst = [
        SELECT Status__c, Error_Message__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      System.assertEquals(
        'Compensating',
        updatedInst.Status__c,
        'Instance should transition to Compensating on timeout'
      );
      System.assert(
        updatedInst.Error_Message__c.contains('timed out'),
        'Error message should contain timeout details'
      );
    }
  }
}
