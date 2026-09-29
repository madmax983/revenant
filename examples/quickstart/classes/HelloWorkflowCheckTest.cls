/**
 * @description Tests for HelloWorkflowCheck, the quickstart verify step.
 * Each test runs as a user with Revenant_Admin, because the check reads in user mode.
 */
@IsTest
private class HelloWorkflowCheckTest {
  @IsTest
  static void passesForACompletedRun() {
    System.runAs(QuickstartTestUser.revenantAdmin()) {
      Test.startTest();
      Id instanceId = WorkflowEngine.start(
        HelloWorkflow.NAME,
        'hello-check-1',
        new Map<String, Object>{ 'name' => 'Revenant' }
      );
      new WorkflowTestHarness(instanceId).drive();
      Test.stopTest();

      HelloWorkflowCheck.Result result = HelloWorkflowCheck.verifyLatest();

      System.assertEquals(instanceId, result.instanceId, 'Must read the run');
      System.assertEquals('Completed', result.status, 'Must be Completed');
      System.assert(result.elapsedMillis >= 0, 'Elapsed must not be negative');
      System.assert(
        result.summary().startsWith(instanceId + ' Completed in '),
        'Summary must give the Id and the status: ' + result.summary()
      );
    }
  }

  @IsTest
  static void failsWhenNoRunExists() {
    System.runAs(QuickstartTestUser.revenantAdmin()) {
      String message = verifyError();
      System.assert(
        message.contains('run-hello.apex'),
        'Must tell the user to run the start script: ' + message
      );
    }
  }

  @IsTest
  static void failsWithTheErrorOfAFailedRun() {
    System.runAs(QuickstartTestUser.revenantAdmin()) {
      insertRun('Failed', 'Step failed', Datetime.now());
      String message = verifyError();
      System.assert(message.contains('Failed'), 'Must give status: ' + message);
      System.assert(
        message.contains('Step failed'),
        'Must give the error: ' + message
      );
    }
  }

  @IsTest
  static void givesNoNullForAnEndedRunWithNoError() {
    System.runAs(QuickstartTestUser.revenantAdmin()) {
      insertRun('Cancelled', null, Datetime.now());
      String message = verifyError();
      System.assert(
        message.endsWith('ended Cancelled.'),
        'Must end with the status: ' + message
      );
      System.assert(!message.contains('null'), 'Must not say null: ' + message);
    }
  }

  @IsTest
  static void asksToRunAgainWhileTheRunIsActive() {
    System.runAs(QuickstartTestUser.revenantAdmin()) {
      Integer minutes = 0;
      for (String status : new List<String>{ 'Pending', 'Running' }) {
        // Each run is newer than the one before.
        insertRun(status, null, Datetime.now().addMinutes(minutes++));
        String message = verifyError();
        System.assert(
          message.contains(status) && message.contains('again'),
          'Must ask the user to run verify again: ' + message
        );
      }
    }
  }

  @IsTest
  static void doesNotAskToWaitForAHeldRun() {
    System.runAs(QuickstartTestUser.revenantAdmin()) {
      insertRun('Held', null, Datetime.now());
      String message = verifyError();
      System.assert(
        message.contains('Held') && message.contains('not Completed'),
        'Must give the status: ' + message
      );
      System.assert(!message.contains('again'), 'Must not wait: ' + message);
    }
  }

  @IsTest
  static void readsOnlyTheLatestRun() {
    System.runAs(QuickstartTestUser.revenantAdmin()) {
      insertRun('Failed', 'Old failure', Datetime.now().addDays(-1));
      Id latest = insertRun('Completed', null, Datetime.now());

      HelloWorkflowCheck.Result result = HelloWorkflowCheck.verifyLatest();

      System.assertEquals(
        latest,
        result.instanceId,
        'Must read the latest run'
      );
    }
  }

  @IsTest
  static void ignoresOtherWorkflows() {
    System.runAs(QuickstartTestUser.revenantAdmin()) {
      insert as system new Workflow_Instance__c(
        Workflow_Name__c = 'SomeOtherWorkflow',
        Correlation_Key__c = 'other-1',
        Status__c = 'Completed'
      );
      String message = verifyError();
      System.assert(
        message.contains('run-hello.apex'),
        'Must not read other workflows: ' + message
      );
    }
  }

  private static Integer runCount = 0;

  private static Id insertRun(
    String status,
    String error,
    Datetime createdDate
  ) {
    runCount++;
    Workflow_Instance__c run = new Workflow_Instance__c(
      Workflow_Name__c = HelloWorkflow.NAME,
      Correlation_Key__c = 'hello-check-run-' + runCount,
      Status__c = status,
      Error_Message__c = error
    );
    // WorkflowInstanceTrigger sets Terminal_At__c on insert for a terminal status.
    insert as system run;
    Test.setCreatedDate(run.Id, createdDate);
    return run.Id;
  }

  private static String verifyError() {
    try {
      HelloWorkflowCheck.verifyLatest();
    } catch (HelloWorkflowCheck.CheckException e) {
      return e.getMessage();
    }
    System.assert(false, 'verifyLatest must throw');
    return null;
  }
}
