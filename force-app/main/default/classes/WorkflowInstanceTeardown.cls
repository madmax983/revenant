/**
 * @description The one delete routine for terminal instances (issue #142).
 * `WorkflowArchiveSweep` (for `CleanupWorkflow` and `ArchiveWorkflow`) and
 * {@link WorkflowInstancePurge} call it, so the purge paths cannot drift.
 *
 * It deletes, in this order:
 * 1. The engine files that {@link CleanupDocumentPurger} selected.
 * 2. Signals (`Workflow_Signal__c`, a SetNull lookup).
 * 3. Instance logs (`Workflow_Log__c`, a SetNull lookup).
 * 4. The instances. Step rows and search attributes cascade (MasterDetail).
 *
 * A log row with `Schedule__c` or `Schedule_Name__c` belongs to the schedule
 * fire history. It stays. The platform clears its instance lookup.
 *
 * The caller selects the instances. This class does not check their status.
 */
public inherited sharing class WorkflowInstanceTeardown {
  // Statuses that a purge can delete. No Queueable chain, replay or rollback
  // runs on a row in one of these statuses. An operator can still retry a
  // Failed row or compensate a Completed row. A purge ends that option.
  // Private, so no caller can add a status to the delete gate.
  private static final Set<String> PURGEABLE_STATUSES = new Set<String>{
    'Completed',
    'Failed',
    'Compensated',
    'Cancelled',
    'ContinuedAsNew'
  };

  /**
   * @description Tells if a purge can delete a row in this status.
   * @param status the `Status__c` value
   * @return true for `Completed`, `Failed`, `Compensated`, `Cancelled` and
   * `ContinuedAsNew`
   */
  public static Boolean isPurgeable(String status) {
    return PURGEABLE_STATUSES.contains(status);
  }

  /**
   * @description Returns a copy of the purgeable statuses, for a SOQL bind.
   * @return a new set. A change to it does not change the gate.
   */
  public static Set<String> purgeableStatuses() {
    return new Set<String>(PURGEABLE_STATUSES);
  }

  /**
   * @description Maximum signal and log rows that one run deletes. When more
   * remain, the run keeps the instances. The next run continues.
   */
  public static final Integer MAX_SATELLITE_ROWS = 5000;
  // Tests lower the cap to exercise the partial path with few rows.
  @TestVisible
  private static Integer maxSatelliteRows = MAX_SATELLITE_ROWS;

  /**
   * @description Numbers of deleted records.
   */
  public class Counts {
    /** @description Deleted instances. */
    public Integer instances = 0;
    /** @description Deleted signals. */
    public Integer signals = 0;
    /** @description Deleted instance logs. */
    public Integer logs = 0;
    /** @description Deleted engine files. */
    public Integer files = 0;
    /**
     * @description False when satellites remain. Then no instance is deleted.
     * Run the same chunk again.
     */
    public Boolean complete = true;
  }

  /**
   * @description Deletes a planned chunk and each satellite that does not
   * cascade. It deletes at most {@link #MAX_SATELLITE_ROWS} signal and log
   * rows. It deletes the instances only when no satellite remains. SOQL and
   * DML run in system mode.
   * @param chunk the chunk from {@link CleanupDocumentPurger#planChunk} or
   * {@link CleanupDocumentPurger#planGroups}
   * @return the numbers of deleted records
   */
  public static Counts run(CleanupDocumentPurger.PurgeChunk chunk) {
    Counts counts = new Counts();
    if (chunk == null || chunk.instancesToPurge.isEmpty()) {
      return counts;
    }
    Set<Id> ids = chunk.instanceIdsToPurge;
    counts.files = CleanupDocumentPurger.deleteDocuments(chunk);

    Integer budget = maxSatelliteRows;
    // Read one row more than the budget, to know if rows remain.
    Integer probe = budget + 1;
    List<SObject> signals = [
      SELECT Id
      FROM Workflow_Signal__c
      WHERE Workflow_Instance__c IN :ids
      WITH SYSTEM_MODE
      LIMIT :probe
    ];
    counts.signals = deleteUpTo(signals, budget);
    budget -= counts.signals;

    probe = budget + 1;
    List<SObject> logs = [
      SELECT Id
      FROM Workflow_Log__c
      WHERE
        Workflow_Instance__c IN :ids
        AND Schedule__c = NULL
        AND Schedule_Name__c = NULL
      WITH SYSTEM_MODE
      LIMIT :probe
    ];
    counts.logs = deleteUpTo(logs, budget);

    counts.complete =
      signals.size() == counts.signals &&
      logs.size() == counts.logs;
    if (!counts.complete) {
      return counts;
    }
    delete as system chunk.instancesToPurge;
    counts.instances = chunk.instancesToPurge.size();
    return counts;
  }

  // Deletes the first `max` rows. Returns the number deleted.
  private static Integer deleteUpTo(List<SObject> rows, Integer max) {
    List<SObject> page = new List<SObject>();
    for (Integer i = 0; i < rows.size() && i < max; i++) {
      page.add(rows[i]);
    }
    if (!page.isEmpty()) {
      delete as system page;
    }
    return page.size();
  }
}
