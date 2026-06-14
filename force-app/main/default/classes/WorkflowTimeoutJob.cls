public inherited sharing class WorkflowTimeoutJob implements Schedulable {
  private Id instanceId;
  private String stepName;

  public WorkflowTimeoutJob(Id instanceId, String stepName) {
    this.instanceId = instanceId;
    this.stepName = stepName;
  }

  public void execute(SchedulableContext ctx) {
    try {
      // Query the step execution record and instance
      List<Workflow_Step_Execution__c> stepExecs = [
        SELECT Id
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :this.instanceId
          AND Step_Name__c = :this.stepName
          AND Status__c = 'Running'
        WITH SYSTEM_MODE
        ORDER BY CreatedDate DESC, Id DESC
        LIMIT 1
      ];

      if (!stepExecs.isEmpty()) {
        Workflow_Step_Execution__c stepExec = [
          SELECT Status__c, Error_Details__c
          FROM Workflow_Step_Execution__c
          WHERE Id = :stepExecs[0].Id
          WITH SYSTEM_MODE
          FOR UPDATE
        ];
        stepExec.Status__c = 'Failed';
        stepExec.Error_Details__c = 'Step execution timed out.';
        update as system stepExec;

        WorkflowEngine.failWorkflowInstance(
          this.instanceId,
          this.stepName,
          'Step execution timed out.'
        );
        return;
      }

      // Check if the workflow instance is still active and waiting on this step
      List<Workflow_Instance__c> instances = [
        SELECT Status__c, Current_Step__c
        FROM Workflow_Instance__c
        WHERE Id = :this.instanceId
        WITH SYSTEM_MODE
        FOR UPDATE
      ];
      if (instances.isEmpty()) {
        return;
      }

      Workflow_Instance__c instance = instances[0];
      if (instance.Status__c != 'Pending' && instance.Status__c != 'Running') {
        return;
      }

      Boolean isExpectedStep = false;
      if (instance.Current_Step__c == this.stepName) {
        isExpectedStep = true;
      } else if (
        String.isNotBlank(instance.Current_Step__c) &&
        instance.Current_Step__c.contains(',')
      ) {
        for (String pStep : instance.Current_Step__c.split(',')) {
          if (pStep.trim() == this.stepName) {
            isExpectedStep = true;
            break;
          }
        }
      }

      if (isExpectedStep) {
        WorkflowEngine.failWorkflowInstance(
          this.instanceId,
          this.stepName,
          'Step execution timed out before starting.'
        );
      }
    } finally {
      // Clean up this scheduled execution
      if (ctx != null) {
        System.abortJob(ctx.getTriggerId());
      }
    }
  }
}
