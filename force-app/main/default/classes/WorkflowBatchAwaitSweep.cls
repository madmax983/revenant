/**
 * @description Batch-wait sweep for the watchdog heartbeat (section 1c, issue
 * #138). It finds each Suspended instance whose awaited batch job ended. It
 * clears Awaited_Batch_Job_Id__c and sets Sleep_Until__c to now. The
 * sleep-resume sweep (section 2) then resumes the instance in the same
 * heartbeat, and applies the pause, hold and park rules.
 *
 * Cost: 1 SOQL when no instance waits. When one waits: 1 more SOQL on
 * AsyncApexJob. When a job ended: 1 more SOQL (FOR UPDATE) and 1 DML.
 * All SOQL and DML run in system mode.
 */
public inherited sharing class WorkflowBatchAwaitSweep {
  // The platform runs not more than 5 batch jobs and holds 100 in the flex
  // queue, so few instances wait at the same time. The read has no lock.
  @TestVisible
  private static Integer candidateLimit = 2000;
  @TestVisible
  private static Boolean forceError = false;

  /**
   * @description Sets the wake time of each instance whose batch job ended.
   * @param now The heartbeat time. Section 2 resumes rows with
   * Sleep_Until__c at or before it.
   * @return The number of instances that the sweep woke.
   */
  public static Integer reconcile(Datetime now) {
    if (Test.isRunningTest() && forceError) {
      throw new WorkflowEngine.WorkflowException('Forced sweep error');
    }
    // Job Id to the stored text. The lock query matches the stored text.
    Map<Id, String> storedByJob = new Map<Id, String>();
    Set<String> wake = new Set<String>();
    for (Workflow_Instance__c inst : [
      SELECT Awaited_Batch_Job_Id__c
      FROM Workflow_Instance__c
      WHERE
        Awaited_Batch_Job_Id__c != NULL
        AND Status__c = 'Suspended'
        AND Sleep_Until__c = NULL
      WITH SYSTEM_MODE
      LIMIT :candidateLimit
    ]) {
      String value = inst.Awaited_Batch_Job_Id__c;
      try {
        storedByJob.put(Id.valueOf(value), value);
      } catch (StringException ex) {
        // The value is not an Id, so no job can end. Wake the instance. The
        // step reads the job Id from its capture.
        wake.add(value);
      }
    }
    for (
      Id jobId : WorkflowBatchJobs.terminalOutcomes(storedByJob.keySet())
        .keySet()
    ) {
      wake.add(storedByJob.get(jobId));
    }
    if (wake.isEmpty()) {
      return 0;
    }
    return wakeInstances(wake, now);
  }

  // Locks and re-checks the rows, so a resume that ran after the read wins.
  private static Integer wakeInstances(Set<String> jobIds, Datetime now) {
    List<Workflow_Instance__c> locked = [
      SELECT Id
      FROM Workflow_Instance__c
      WHERE
        Awaited_Batch_Job_Id__c IN :jobIds
        AND Status__c = 'Suspended'
        AND Sleep_Until__c = NULL
      WITH SYSTEM_MODE
      FOR UPDATE
    ];
    for (Workflow_Instance__c inst : locked) {
      inst.Awaited_Batch_Job_Id__c = null;
      inst.Sleep_Until__c = now;
    }
    if (!locked.isEmpty()) {
      Database.update(locked, true, AccessLevel.SYSTEM_MODE);
    }
    return locked.size();
  }
}
