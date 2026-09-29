/**
 * @description Tests for HelloWorkflowCheck, the quickstart verify step.
 */
@IsTest
private class HelloWorkflowCheckTest {
  @IsTest
  static void passesForACompletedRun() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
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
        result.summary().contains(String.valueOf(instanceId)),
        'Summary must name the instance'
      );
      System.assert(
        result.summary().contains('Completed'),
        'Summary must give the status'
      );
    }
  }

  @IsTest
  static void failsWhenNoRunExists() {
    String message = verifyError();
    System.assert(
      message.contains('run-hello.apex'),
      'Must tell the user to run the start script: ' + message
    );
  }

  @IsTest
  static void failsWithTheErrorOfAFailedRun() {
    insertRun('Failed', 'Step blew up', Datetime.now());
    String message = verifyError();
    System.assert(message.contains('Failed'), 'Must give status: ' + message);
    System.assert(
      message.contains('Step blew up'),
      'Must give the error: ' + message
    );
  }

  @IsTest
  static void asksToRunAgainWhileTheRunIsActive() {
    insertRun('Running', null, Datetime.now());
    String message = verifyError();
    System.assert(
      message.contains('Running') && message.contains('again'),
      'Must ask the user to run verify again: ' + message
    );
  }

  @IsTest
  static void readsOnlyTheLatestRun() {
    insertRun('Failed', 'Old failure', Datetime.now().addDays(-1));
    Id latest = insertRun('Completed', null, Datetime.now());

    HelloWorkflowCheck.Result result = HelloWorkflowCheck.verifyLatest();

    System.assertEquals(latest, result.instanceId, 'Must read the latest run');
  }

  @IsTest
  static void ignoresOtherWorkflows() {
    Workflow_Instance__c other = new Workflow_Instance__c(
      Workflow_Name__c = 'SomeOtherWorkflow',
      Correlation_Key__c = 'other-1',
      Status__c = 'Completed'
    );
    insert as system other;
    String message = verifyError();
    System.assert(
      message.contains('run-hello.apex'),
      'Must not read other workflows: ' + message
    );
  }

  private static Id insertRun(
    String status,
    String error,
    Datetime createdDate
  ) {
    Workflow_Instance__c run = new Workflow_Instance__c(
      Workflow_Name__c = HelloWorkflow.NAME,
      Correlation_Key__c = 'hello-' + status + '-' + createdDate.getTime(),
      Status__c = status,
      Error_Message__c = error
    );
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
