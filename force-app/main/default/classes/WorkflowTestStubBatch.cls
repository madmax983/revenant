/**
 * @description A Batchable with no Revenant code. It selects the accounts with the tag as name. It is top level, as a Batchable must be.
 */
@IsTest
public class WorkflowTestStubBatch implements Database.Batchable<SObject> {
  /** @description The account name to select. */
  public String tag;

  /**
   * @description Starts the batch.
   * @param bc The batch context.
   * @return The records or items of the batch.
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
