@IsTest
private class ScheduleFireHistoryTest {
  private static final String TEST_WF = 'WorkflowEngineTest.HappyWorkflow';

  private static Workflow_Schedule__c insertSchedule(String name) {
    Workflow_Schedule__c sched = new Workflow_Schedule__c(
      Name = name,
      Workflow_Name__c = TEST_WF,
      Cron_Expression__c = '0 * * * *',
      Enabled__c = true,
      Dedicated_Slot__c = false
    );
    insert sched;
    return sched;
  }

  private static ScheduleHealth.Assessment failed(Workflow_Schedule__c sched) {
    ScheduleHealth.Assessment a = new ScheduleHealth.Assessment();
    a.schedule = sched;
    a.lastFireFailed = true;
    return a;
  }

  private static Map<Id, Datetime> lastGoodAfter(
    String logType,
    String outcome
  ) {
    Workflow_Schedule__c sched = insertSchedule('H' + logType + outcome);
    insert new Workflow_Log__c(
      Fire_Key__c = 'HistKey_' + logType + ':' + outcome,
      Log_Type__c = logType,
      Outcome__c = outcome,
      Schedule__c = sched.Id
    );
    Map<Id, Datetime> result = ScheduleFireHistory.lastGoodFireBySchedule(
      new List<ScheduleHealth.Assessment>{ failed(sched) }
    );
    Assert.isTrue(
      result.isEmpty() || result.containsKey(sched.Id),
      'Result holds only the failed schedule'
    );
    return result;
  }

  @IsTest
  static void startedSkippedAndDedupedAreGoodFires() {
    for (String outcome : new List<String>{ 'Started', 'Skipped', 'Deduped' }) {
      for (String logType : ScheduleFireHistory.SCHEDULED_FIRE_LOG_TYPES) {
        Assert.areEqual(
          1,
          lastGoodAfter(logType, outcome).size(),
          logType + ' ' + outcome
        );
      }
    }
  }

  @IsTest
  static void errorAndManualFiresAreNotGoodFires() {
    Assert.isTrue(
      lastGoodAfter('ScheduleFire', 'Error').isEmpty(),
      'An Error fire is not good'
    );
    Assert.isTrue(
      lastGoodAfter('ScheduleManualFire', 'Started').isEmpty(),
      'Run Now is not a scheduled fire'
    );
  }

  @IsTest
  static void noFailedScheduleRunsNoQuery() {
    Integer before = Limits.getQueries();

    Map<Id, Datetime> result = ScheduleFireHistory.lastGoodFireBySchedule(
      new List<ScheduleHealth.Assessment>()
    );

    Assert.isTrue(result.isEmpty());
    Assert.areEqual(before, Limits.getQueries());
  }
}
