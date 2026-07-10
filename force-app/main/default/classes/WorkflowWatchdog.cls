public inherited sharing class WorkflowWatchdog implements Schedulable {
  @TestVisible
  private static Boolean bootstrapped = false;

  @TestVisible
  private static Boolean forceBootstrapInTest = false;

  @TestVisible
  private Integer delayMinutes;

  public WorkflowWatchdog() {
    this(WorkflowEngine.watchdogDelayMinutes);
  }

  public WorkflowWatchdog(Integer delayMinutes) {
    this.delayMinutes = (delayMinutes == null ||
      delayMinutes < 1 ||
      delayMinutes > 10)
      ? 10
      : delayMinutes;
  }

  /**
   * Schedulable interface.
   */
  public void execute(SchedulableContext ctx) {
    bootstrap();
  }

  /**
   * Bootstraps the self-chaining watchdog if it is not already running.
   */
  public static void bootstrap() {
    if ((Test.isRunningTest() && !forceBootstrapInTest) || bootstrapped) {
      return;
    }
    bootstrapped = true;

    try {
      List<Workflow_Instance__c> latestWatchdogs = [
        SELECT Id
        FROM Workflow_Instance__c
        WHERE
          (Correlation_Key__c = 'SystemWatchdog'
          OR Correlation_Key__c LIKE 'SystemWatchdog_run%')
          AND Status__c IN ('Pending', 'Running', 'Suspended')
        WITH SYSTEM_MODE
        ORDER BY CreatedDate DESC
        LIMIT 1
      ];

      if (latestWatchdogs.isEmpty()) {
        // Active-only start: the watchdog is a self-perpetuating singleton, so a
        // recent terminal (Failed/Cancelled/ContinuedAsNew) run must never
        // satisfy the start via the dedup window — otherwise polling stays
        // offline until the window expires.
        WorkflowEngine.startSingleton(
          'WatchdogWorkflow',
          'SystemWatchdog',
          null
        );
      } else {
        Id watchdogId = latestWatchdogs[0].Id;
        Workflow_Instance__c inst = [
          SELECT Id, Status__c, Sleep_Until__c
          FROM Workflow_Instance__c
          WHERE Id = :watchdogId
          WITH SYSTEM_MODE
          FOR UPDATE
        ];
        if (
          inst.Status__c == 'Suspended' &&
          inst.Sleep_Until__c != null &&
          inst.Sleep_Until__c <= DateTime.now()
        ) {
          inst.Status__c = 'Running';
          inst.Sleep_Until__c = null;
          update as system inst;
          WorkflowEngine.enqueueOrchestrators(new List<Id>{ inst.Id });
        }
      }
    } catch (Exception ignored) {
    }
  }
}
