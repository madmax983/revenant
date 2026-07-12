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

  private class FinalizerTestException extends Exception {
  }

  @IsTest
  static void testAsyncCalloutJobAndFinalizerDirectly() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowAlertManager.mockConfigs.put(
        'CalloutTimeoutWorkflowExample_CalloutWorkflow',
        (Workflow_Alert_Config__mdt) JSON.deserialize(
          '{"DeveloperName":"CalloutTimeoutWorkflowExample_CalloutWorkflow", "Email_Recipients__c":"test@example.com", "Enable_Alerts__c":true}',
          Workflow_Alert_Config__mdt.class
        )
      );
      WorkflowAlertManager.sentEmailsCount = 0;

      // Drive the async suspend/resume path deterministically: forceAsyncInTest
      // makes the step suspend, and disableQueueableInTest stops WorkflowEngine
      // from auto-enqueuing the orchestrator so we can drive it by hand.
      CalloutTimeoutWorkflowExample.forceAsyncInTest = true;
      WorkflowEngine.disableQueueableInTest = true;
      Test.setMock(
        HttpCalloutMock.class,
        new SingleRequestMock(200, '{"success": true}')
      );

      Test.startTest();
      // Build an instance suspended at the MakeHttpCallout step so the async job
      // has a valid instance to resume.
      Id instanceId = WorkflowEngine.start(
        'CalloutTimeoutWorkflowExample.CalloutWorkflow',
        'DirectAsyncCalloutKey',
        new Map<String, Object>{
          'endpoint' => 'https://httpbin.org/status/200'
        }
      );
      new WorkflowOrchestrator(instanceId).execute(null); // runs step -> suspend()

      // AsyncCalloutJob.execute() calls System.attachFinalizer unconditionally,
      // which is only legal inside a real Queueable transaction. Enqueue it so
      // Test.stopTest() runs execute() (ctor + attachFinalizer + doCalloutAndResume)
      // in a valid async context rather than throwing on a direct execute(null).
      System.enqueueJob(
        new CalloutTimeoutWorkflowExample.AsyncCalloutJob(
          instanceId,
          'https://httpbin.org/status/200'
        )
      );
      Test.stopTest(); // executes AsyncCalloutJob and resumes the instance

      // The job's callout + resume moved the instance to Running with the mocked
      // 200 payload cached on the step execution.
      Workflow_Instance__c inst = [
        SELECT Status__c, Current_Step__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      System.assertEquals(
        'Running',
        inst.Status__c,
        'AsyncCalloutJob should resume the suspended instance to Running'
      );
      System.assertEquals(
        'CalloutTimeoutWorkflowExample.MakeHttpCalloutStep',
        inst.Current_Step__c
      );

      List<Workflow_Step_Execution__c> asyncExecs = [
        SELECT Output__c
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Step_Name__c = 'CalloutTimeoutWorkflowExample.MakeHttpCalloutStep'
        ORDER BY CreatedDate DESC, Id DESC
      ];
      System.assert(!asyncExecs.isEmpty());
      System.assert(
        String.isNotBlank(asyncExecs[0].Output__c),
        'Resume payload should be cached on the step execution'
      );
      System.assert(asyncExecs[0].Output__c.contains('status'));
      System.assert(
        asyncExecs[0].Output__c.contains('200'),
        'Cached payload should carry the mocked 200 status'
      );

      // ResumeFinalizer coverage. System.FinalizerContext cannot be instantiated
      // in a test, so exercise its extracted decision logic directly on a fresh
      // suspended fixture instance.
      Id finalizerInstanceId = WorkflowEngine.start(
        'CalloutTimeoutWorkflowExample.CalloutWorkflow',
        'FinalizerRecoveryKey',
        new Map<String, Object>{
          'endpoint' => 'https://httpbin.org/status/500'
        }
      );
      new WorkflowOrchestrator(finalizerInstanceId).execute(null); // suspend
      Workflow_Instance__c suspended = [
        SELECT Status__c
        FROM Workflow_Instance__c
        WHERE Id = :finalizerInstanceId
      ];
      System.assertEquals(
        'Suspended',
        suspended.Status__c,
        'Fixture instance should be suspended before the finalizer runs'
      );

      CalloutTimeoutWorkflowExample.ResumeFinalizer finalizer = new CalloutTimeoutWorkflowExample.ResumeFinalizer(
        finalizerInstanceId
      );

      // Happy path: the job's own resume already ran, so the finalizer no-ops.
      finalizer.handleResult(System.ParentJobResult.SUCCESS, null);
      Workflow_Instance__c afterSuccess = [
        SELECT Status__c
        FROM Workflow_Instance__c
        WHERE Id = :finalizerInstanceId
      ];
      System.assertEquals(
        'Suspended',
        afterSuccess.Status__c,
        'A SUCCESS result must not resume the instance'
      );

      // Failure path: the job died, so the finalizer resumes with an error payload.
      finalizer.handleResult(
        System.ParentJobResult.UNHANDLED_EXCEPTION,
        new FinalizerTestException('async job died')
      );
      Workflow_Instance__c afterFailure = [
        SELECT Status__c
        FROM Workflow_Instance__c
        WHERE Id = :finalizerInstanceId
      ];
      System.assertEquals(
        'Running',
        afterFailure.Status__c,
        'An UNHANDLED_EXCEPTION result should resume the instance for recovery'
      );

      List<Workflow_Step_Execution__c> finalizerExecs = [
        SELECT Output__c
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :finalizerInstanceId
          AND Step_Name__c = 'CalloutTimeoutWorkflowExample.MakeHttpCalloutStep'
        ORDER BY CreatedDate DESC, Id DESC
      ];
      System.assert(!finalizerExecs.isEmpty());
      System.assert(
        String.isNotBlank(finalizerExecs[0].Output__c),
        'Finalizer recovery should cache an error payload'
      );
      System.assert(
        finalizerExecs[0].Output__c.contains('Async callout job failed'),
        'Recovery payload should describe the job failure'
      );
      System.assert(
        finalizerExecs[0].Output__c.contains('async job died'),
        'Recovery payload should carry the job exception message'
      );
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
