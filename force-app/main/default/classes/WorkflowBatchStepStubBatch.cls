/** @description A Batchable with no Revenant code. */
@IsTest
public class WorkflowBatchStepStubBatch implements Database.Batchable<SObject> {
  public String tag;

  /**
   * @description Selects the accounts with the tag as name.
   * @param bc The batch context.
   * @return The query locator.
   */
  public Database.QueryLocator start(Database.BatchableContext bc) {
    return Database.getQueryLocator(
      [SELECT Id FROM Account WHERE Name = :tag WITH SYSTEM_MODE]
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
