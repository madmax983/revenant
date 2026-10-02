/**
 * @description Test batch. It only adds a BatchApex AsyncApexJob row.
 */
@IsTest
public class WorkflowAsyncCapacityNoopBatch implements Database.Batchable<SObject> {
  /**
   * @description Returns no rows.
   * @param bc The batch context.
   * @return An empty scope.
   */
  public Iterable<SObject> start(Database.BatchableContext bc) {
    return new List<SObject>();
  }

  /**
   * @description Does nothing.
   * @param bc The batch context.
   * @param scope The records.
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
