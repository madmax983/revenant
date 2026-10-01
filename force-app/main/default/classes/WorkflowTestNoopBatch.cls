/**
 * @description Test batch. It only adds a BatchApex AsyncApexJob row. It is top level, as a Batchable must be.
 */
@IsTest
public class WorkflowTestNoopBatch implements Database.Batchable<SObject> {
  /**
   * @description Starts the batch.
   * @param bc The batch context.
   * @return The records or items of the batch.
   */
  public Iterable<SObject> start(Database.BatchableContext bc) {
    return new List<SObject>();
  }

  /**
   * @description Does nothing.
   * @param bc The batch context.
   * @param scope The records of this chunk.
   */
  public void execute(Database.BatchableContext bc, List<SObject> scope) {
    return;
  }

  /**
   * @description Does nothing.
   * @param bc The batch context.
   */
  public void finish(Database.BatchableContext bc) {
    return;
  }
}
