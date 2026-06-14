public inherited sharing class WorkflowSleepJob implements Schedulable {
  private Id instanceId;

  public WorkflowSleepJob(Id instanceId) {
    this.instanceId = instanceId;
  }

  public void execute(SchedulableContext ctx) {
    // Update instance status to Running to resume execution
    List<Workflow_Instance__c> instances = [
      SELECT Id, Status__c
      FROM Workflow_Instance__c
      WHERE Id = :this.instanceId AND Status__c = 'Suspended'
      WITH SYSTEM_MODE
      LIMIT 1
      FOR UPDATE
    ];
    if (!instances.isEmpty()) {
      instances[0].Status__c = 'Running';
      update as system instances[0];
    }

    // Enqueue the next step execution
    if (Test.isRunningTest()) {
      System.enqueueJob(new WorkflowOrchestrator(this.instanceId));
    } else {
      WorkflowEngine.enqueueOrchestrator(this.instanceId, null);
    }

    // Schedule watchdog for the step we just resumed
    WorkflowEngine.scheduleTimeoutJobForInstance(this.instanceId);

    // Clean up this scheduled execution from the schedule queue
    System.abortJob(ctx.getTriggerId());
  }
}
