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
 * A log row with `Schedule__c` belongs to the schedule fire history. It
 * stays. The platform clears its instance lookup.
 *
 * The caller selects the instances. This class does not check their status.
 */
public inherited sharing class WorkflowInstanceTeardown {
  /**
   * @description Statuses that a purge can delete. A row in one of these
   * statuses never runs, replays or rolls back again.
   */
  public static final Set<String> PURGEABLE_STATUSES = new Set<String>{
    'Completed',
    'Failed',
    'Compensated',
    'Cancelled',
    'ContinuedAsNew'
  };

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
  }

  /**
   * @description Deletes a planned chunk and each satellite that does not
   * cascade. SOQL and DML run in system mode.
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

    List<Workflow_Signal__c> signals = [
      SELECT Id
      FROM Workflow_Signal__c
      WHERE Workflow_Instance__c IN :ids
      WITH SYSTEM_MODE
    ];
    if (!signals.isEmpty()) {
      delete as system signals;
    }
    counts.signals = signals.size();

    List<Workflow_Log__c> logs = [
      SELECT Id
      FROM Workflow_Log__c
      WHERE Workflow_Instance__c IN :ids AND Schedule__c = NULL
      WITH SYSTEM_MODE
    ];
    if (!logs.isEmpty()) {
      delete as system logs;
    }
    counts.logs = logs.size();

    delete as system chunk.instancesToPurge;
    counts.instances = chunk.instancesToPurge.size();
    return counts;
  }
}
