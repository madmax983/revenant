/**
 * @description Reads the scheduled fire history (issue #126). A good
 * scheduled fire ends a failure streak. A manual Run Now does not.
 */
public inherited sharing class ScheduleFireHistory {
  /** @description Fire log outcomes that end a failure streak. */
  public static final Set<String> GOOD_OUTCOMES = new Set<String>{
    'Started',
    'Skipped'
  };

  /** @description Log types of scheduled fires (0-slot and dedicated). */
  public static final Set<String> SCHEDULED_FIRE_LOG_TYPES = new Set<String>{
    'ScheduleFire',
    'ScheduleDedicatedFire'
  };

  /**
   * @description Returns the time of the last Started or Skipped scheduled
   * fire log for each failed schedule. One aggregate query, only when a
   * failed schedule exists.
   * @param found The assessments.
   * @return Last good fire time by schedule Id.
   */
  public static Map<Id, Datetime> lastGoodFireBySchedule(
    List<ScheduleHealth.Assessment> found
  ) {
    Set<Id> failedIds = new Set<Id>();
    for (ScheduleHealth.Assessment a : found) {
      if (a.lastFireFailed) {
        failedIds.add(a.schedule.Id);
      }
    }
    Map<Id, Datetime> result = new Map<Id, Datetime>();
    if (failedIds.isEmpty()) {
      return result;
    }
    for (AggregateResult row : [
      SELECT Schedule__c sid, MAX(CreatedDate) lastGood
      FROM Workflow_Log__c
      WHERE
        Schedule__c IN :failedIds
        AND Outcome__c IN :GOOD_OUTCOMES
        AND Log_Type__c IN :SCHEDULED_FIRE_LOG_TYPES
      WITH SYSTEM_MODE
      GROUP BY Schedule__c
    ]) {
      result.put((Id) row.get('sid'), (Datetime) row.get('lastGood'));
    }
    return result;
  }
}
