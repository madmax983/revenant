/** @description An Iterable Batchable with no Revenant code. */
@IsTest
public class WorkflowBatchStepIterBatch implements Database.Batchable<Object> {
  /**
   * @description Gives two items.
   * @param bc The batch context.
   * @return The items.
   */
  public Iterable<Object> start(Database.BatchableContext bc) {
    return new List<Object>{ 'a', 'b' };
  }

  /**
   * @description Does nothing.
   * @param bc The batch context.
   * @param scope The items of this chunk.
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
