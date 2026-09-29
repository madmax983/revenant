/**
 * @description A plain Batchable with no Revenant code (issue #138). It writes
 * a tag to the Description of each Account whose name starts with a prefix.
 * BatchStepWorkflowExample runs it as a durable step.
 */
public inherited sharing class ExampleAccountTagBatch implements Database.Batchable<SObject> {
  /** @description The start of the Account names to tag. */
  public String namePrefix;
  /** @description The text to write to Description. */
  public String tag;

  /**
   * @description Selects the Accounts to tag.
   * @param bc The batch context.
   * @return The query locator.
   */
  public Database.QueryLocator start(Database.BatchableContext bc) {
    String pattern = namePrefix + '%';
    return Database.getQueryLocator(
      [SELECT Id FROM Account WHERE Name LIKE :pattern WITH USER_MODE]
    );
  }

  /**
   * @description Writes the tag to each Account in the chunk.
   * @param bc The batch context.
   * @param scope The Accounts of this chunk.
   */
  public void execute(Database.BatchableContext bc, List<Account> scope) {
    for (Account acc : scope) {
      acc.Description = tag;
    }
    Database.update(scope, true, AccessLevel.USER_MODE);
  }

  /**
   * @description Does nothing. The workflow reads the job outcome.
   * @param bc The batch context.
   */
  public void finish(Database.BatchableContext bc) {
    return;
  }
}
