/** @description A Batchable with no Revenant code. */
@IsTest
public class WorkflowBatchJobsCountBatch implements Database.Batchable<SObject> {
  /**
   * @description Selects the test accounts.
   * @param bc The batch context.
   * @return The query locator.
   */
  public Database.QueryLocator start(Database.BatchableContext bc) {
    return Database.getQueryLocator(
      [
        SELECT Id
        FROM Account
        WHERE Name LIKE 'BatchJobsTest%'
        WITH SYSTEM_MODE
      ]
    );
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
