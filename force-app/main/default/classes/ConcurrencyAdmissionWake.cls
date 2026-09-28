/**
 * @description Admit-only wake for the admission queue (issue #132). The gate
 * enqueues it for the rows that rank ahead of a candidate. For each row that
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
    for (Id instanceId : instanceIds) {
      admitOne(instanceId);
    }
  }

  private static void admitOne(Id instanceId) {
    Savepoint sp = Database.setSavepoint();
    try {
      WorkflowStepRunner.admitIfWaiting(instanceId);
    } catch (Exception ignored) {
      // Best effort. The row keeps its retry timer and the watchdog.
      Database.rollback(sp);
    }
  }
}
