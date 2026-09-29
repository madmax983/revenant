/**
 * @description Admit-only wake for the admission queue (issue #132). The gate
 * enqueues it for the rows that rank ahead of a candidate. It locks all rows
 * first, in Id order. For each row that
 * still waits, it runs the admission gate: the row gets a slot (and a normal
 * re-drive) or parks again. It never runs a step, so a late wake cannot
 * re-run the step of an admitted instance.
 */
public inherited sharing class ConcurrencyAdmissionWake implements Queueable {
  private final List<Id> instanceIds;

  /**
   * @description Makes a wake for the given rows.
   * @param instanceIds The waiting instances to admit, best first.
   */
  public ConcurrencyAdmissionWake(List<Id> instanceIds) {
    this.instanceIds = instanceIds == null ? new List<Id>() : instanceIds;
  }

  /**
   * @description Runs the admission gate for each row. An error on one row is
   * rolled back for that row only. The row keeps its retry timer.
   * @param ctx The Queueable context.
   */
  public void execute(QueueableContext ctx) {
    // Lock all rows first, in Id order. The gate then locks the counter. This
    // keeps the engine lock order (instance rows, then counter) for each row.
    List<Workflow_Instance__c> locked = [
      SELECT Id
      FROM Workflow_Instance__c
      WHERE Id IN :instanceIds
      WITH SYSTEM_MODE
      ORDER BY Id ASC
      FOR UPDATE
    ];
    for (Workflow_Instance__c row : locked) {
      admitOne(row.Id);
    }
  }

  // Each row gets its own savepoint. The finally block releases it, so that
  // the job never holds more than one active savepoint.
  private static void admitOne(Id instanceId) {
    Savepoint sp = Database.setSavepoint();
    try {
      WorkflowStepRunner.admitIfWaiting(instanceId);
    } catch (Exception e) {
      // Best effort. The row keeps its retry timer and the watchdog.
      Database.rollback(sp);
      WorkflowLog.warn(
        'AdmissionWake',
        'Admit-only wake failed: ' + e.getMessage(),
        instanceId
      );
    } finally {
      Database.releaseSavepoint(sp);
    }
  }
}
