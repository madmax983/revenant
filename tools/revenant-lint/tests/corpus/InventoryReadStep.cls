// A read of rows that other processes change. MEDIUM.
public class InventoryReadStep implements WorkflowStep {
  public StepResult execute(StepContext ctx) {
    List<Product2> items = [SELECT Id, Stock__c FROM Product2 WHERE Id = :ctx.inputJson]; // expect: SOQL_READ
    List<SObject> rows = Database.query('SELECT Id FROM Account'); // expect: SOQL_READ
    Database.QueryLocator loc = Database.getQueryLocator('SELECT Id FROM Account'); // expect: SOQL_READ
    List<List<SObject>> hits = Search.query('FIND \'x\''); // expect: SOQL_READ
    Database.Cursor cursor = Database.getCursor('SELECT Id FROM Account'); // expect: SOQL_READ
    List<List<SObject>> found = Search.find('FIND {x}'); // expect: SOQL_READ
    Integer find = 0;
    Object first = items[find];
    return StepResult.complete(null, items.size());
  }
}
