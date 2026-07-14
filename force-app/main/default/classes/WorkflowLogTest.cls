@IsTest
private class WorkflowLogTest {
  @IsTest
  static void persistsErrorLogs() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      WorkflowLog.error('UnitTest', 'boom');
      WorkflowLog.error(
        new WorkflowLog.ErrorEntry('UnitTest', 'boom again')
          .withInstanceId((Id) null)
          .withCorrelationKey(null)
          .withWorkflowName(null)
      );
      Test.stopTest();

      List<Workflow_Log__c> logs = [
        SELECT Id, Level__c, Log_Type__c, Message__c
        FROM Workflow_Log__c
        WHERE Log_Type__c = 'UnitTest'
      ];
      System.assertEquals(2, logs.size(), 'Expected two error logs persisted');
      for (Workflow_Log__c logRecord : logs) {
        System.assertEquals(
          'Error',
          logRecord.Level__c,
          'Level should be Error'
        );
        System.assertEquals(
          'UnitTest',
          logRecord.Log_Type__c,
          'Log_Type should match'
        );
        System.assert(
          logRecord.Message__c != null && logRecord.Message__c.contains('boom'),
          'Message should contain boom'
        );
      }
    }
  }
}
