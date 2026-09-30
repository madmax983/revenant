/**
 * @description Batch job access for WorkflowBatchStep and the watchdog
 * (issue #138). Launches a Batchable, reads the outcome of ended jobs, and
 * finds a parallel branch. The step and the sweep use the same outcome, so
 * they use the same rule for an ended job. All SOQL runs in system mode.
 */
public inherited sharing class WorkflowBatchJobs {
  /** @description Status of a job that has no AsyncApexJob row. */
  public static final String STATUS_NOT_FOUND = 'NotFound';

  // AsyncApexJob statuses that do not change again.
  private static final Set<String> TERMINAL = new Set<String>{
    'Completed',
    'Failed',
    'Aborted'
  };

  // Test seams. Tests cannot insert AsyncApexJob or make a real job fail.
  @TestVisible
  private static Id stubLaunchId;
  @TestVisible
  private static Map<Id, AsyncApexJob> stubJobs;
  @TestVisible
  private static Integer launchCount = 0;
  @TestVisible
  private static Object lastLaunched;
  @TestVisible
  private static Integer lastScopeSize;

  /**
   * @description Launches a batch job. The platform queues it at commit. A
   * rollback removes it.
   * @param batchable The Batchable instance.
   * @param scopeSize The number of records for each execute() call.
   * @return The AsyncApexJob Id.
   */
  public static Id launch(Object batchable, Integer scopeSize) {
    // Refuse a class that is not a Batchable before the launch.
    Boolean ofSObject = batchable instanceof Database.Batchable<SObject>;
    if (!ofSObject && !(batchable instanceof Database.Batchable<Object>)) {
      throw new IllegalArgumentException(
        'The class is not a Database.Batchable'
      );
    }
    launchCount++;
    lastLaunched = batchable;
    lastScopeSize = scopeSize;
    if (Test.isRunningTest() && stubLaunchId != null) {
      return stubLaunchId;
    }
    // The compiler needs a Batchable type, not Object.
    if (ofSObject) {
      return Database.executeBatch(
        (Database.Batchable<SObject>) batchable,
        scopeSize
      );
    }
    return Database.executeBatch(
      (Database.Batchable<Object>) batchable,
      scopeSize
    );
  }

  /**
   * @description Gives the outcome of one job if it ended.
   * @param jobId The AsyncApexJob Id.
   * @return The outcome, or null while the job runs.
   */
  public static Map<String, Object> terminalOutcome(Id jobId) {
    return terminalOutcomes(new Set<Id>{ jobId }).get(jobId);
  }

  /**
   * @description Gives the outcome of each job that ended. A job with no row
   * (the platform deleted it) ended with the status NotFound. 1 SOQL.
   * @param jobIds The AsyncApexJob Ids. Null or empty reads nothing.
   * @return The outcomes by job Id. A running job is not in the map.
   */
  public static Map<Id, Map<String, Object>> terminalOutcomes(Set<Id> jobIds) {
    Map<Id, Map<String, Object>> outcomes = new Map<Id, Map<String, Object>>();
    if (jobIds == null || jobIds.isEmpty()) {
      return outcomes;
    }
    Map<Id, AsyncApexJob> rows = readJobs(jobIds);
    for (Id jobId : jobIds) {
      AsyncApexJob row = rows.get(jobId);
      if (row == null) {
        outcomes.put(jobId, outcome(jobId, STATUS_NOT_FOUND, null));
      } else if (TERMINAL.contains(row.Status)) {
        outcomes.put(jobId, outcome(jobId, row.Status, row));
      }
    }
    return outcomes;
  }

  /**
   * @description Tells if the instance runs parallel branches now.
   * @param instanceId The instance Id. Null gives false.
   * @return True when Current_Step__c has more than one step.
   */
  public static Boolean inParallelBranch(Id instanceId) {
    if (instanceId == null) {
      return false;
    }
    for (Workflow_Instance__c inst : [
      SELECT Current_Step__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
      WITH SYSTEM_MODE
      LIMIT 1
    ]) {
      return inst.Current_Step__c != null && inst.Current_Step__c.contains(',');
    }
    return false;
  }

  private static Map<Id, AsyncApexJob> readJobs(Set<Id> jobIds) {
    if (Test.isRunningTest() && stubJobs != null) {
      return stubJobs;
    }
    return new Map<Id, AsyncApexJob>(
      [
        SELECT
          Id,
          Status,
          TotalJobItems,
          JobItemsProcessed,
          NumberOfErrors,
          ExtendedStatus
        FROM AsyncApexJob
        WHERE Id IN :jobIds
        WITH SYSTEM_MODE
      ]
    );
  }

  // The keys use the AsyncApexJob names. The counts are batches (execute()
  // calls), not records. The platform does not give record counts.
  private static Map<String, Object> outcome(
    Id jobId,
    String status,
    AsyncApexJob row
  ) {
    Integer errors = row?.NumberOfErrors;
    return new Map<String, Object>{
      'jobId' => String.valueOf(jobId),
      'status' => status,
      'succeeded' => status == 'Completed' && (errors == null || errors == 0),
      'totalJobItems' => row?.TotalJobItems,
      'jobItemsProcessed' => row?.JobItemsProcessed,
      'numberOfErrors' => errors,
      'firstError' => row?.ExtendedStatus
    };
  }
}
