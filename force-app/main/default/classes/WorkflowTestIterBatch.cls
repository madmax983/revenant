/**
 * @description An Iterable Batchable with no Revenant code. It gives two items. It is top level, as a Batchable must be.
 */
@IsTest
public class WorkflowTestIterBatch implements Database.Batchable<Object> {
  /**
   * @description Starts the batch.
   * @param bc The batch context.
   * @return The records or items of the batch.
   */
  public Iterable<Object> start(Database.BatchableContext bc) {
    return new List<Object>{ 'a', 'b' };
  }

  /**
   * @description Does nothing.
   * @param bc The batch context.
   * @param scope The records of this chunk.
   */
  public void execute(Database.BatchableContext bc, List<Object> scope) {
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
