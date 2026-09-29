/**
 * @description The quickstart verify step. It reads the latest HelloWorkflow run
 * and throws if that run is not Completed. It only reads. See docs/quickstart.md.
 */
public inherited sharing class HelloWorkflowCheck {
  // The engine moves these statuses on without help.
  private static final Set<String> ACTIVE = new Set<String>{
    'Pending',
    'Running'
  };

  /**
   * @description The latest run is missing, still active, or not Completed.
   */
  public class CheckException extends Exception {
  }

  /**
   * @description A Completed run and its elapsed time, start to terminal.
   */
  public class Result {
    /** @description The Workflow_Instance__c Id. */
    public Id instanceId { get; private set; }
    /** @description The status. Always Completed. */
    public String status { get; private set; }
    /** @description Terminal_At__c minus CreatedDate, in milliseconds. */
    public Long elapsedMillis { get; private set; }

    private Result(Workflow_Instance__c run) {
      instanceId = run.Id;
      status = run.Status__c;
      // If the clocks differ, use 0, not a negative time.
      elapsedMillis = Math.max(
        0L,
        run.Terminal_At__c.getTime() - run.CreatedDate.getTime()
      );
    }

    /**
     * @description One line for the debug log.
     * @return For example "a01... Completed in 4.2 s".
     */
    public String summary() {
      return instanceId +
        ' ' +
        status +
        ' in ' +
        Decimal.valueOf(elapsedMillis).divide(1000, 1) +
        ' s';
    }
  }

  /**
   * @description Reads the latest HelloWorkflow run. Makes no change.
   * @return The Completed run.
   * @throws CheckException No run, a run that is still Pending or Running, or a
   * run with a different status.
   */
  public static Result verifyLatest() {
    List<Workflow_Instance__c> runs = [
      SELECT Id, Status__c, Error_Message__c, CreatedDate, Terminal_At__c
      FROM Workflow_Instance__c
      WHERE Workflow_Name__c = :HelloWorkflow.NAME
      WITH USER_MODE
      ORDER BY CreatedDate DESC, Id DESC
      LIMIT 1
    ];
    if (runs.isEmpty()) {
      throw new CheckException(
        'No HelloWorkflow run. Run scripts/apex/run-hello.apex first.'
      );
    }
    Workflow_Instance__c run = runs[0];
    String prefix = 'HelloWorkflow ' + run.Id + ' ';
    if (ACTIVE.contains(run.Status__c)) {
      throw new CheckException(
        prefix +
          'is still ' +
          run.Status__c +
          '. Wait a few seconds, then run this script again.'
      );
    }
    if (run.Terminal_At__c == null) {
      // For example Held or Paused: waiting does not help.
      throw new CheckException(
        prefix + 'is ' + run.Status__c + '. It is not Completed.'
      );
    }
    if (run.Status__c != 'Completed') {
      String error = String.isBlank(run.Error_Message__c)
        ? '.'
        : ': ' + run.Error_Message__c;
      throw new CheckException(prefix + 'ended ' + run.Status__c + error);
    }
    return new Result(run);
  }
}
