public inherited sharing class WorkflowTimeoutJob implements Schedulable {
  private Id instanceId;
  private String stepName;

  public WorkflowTimeoutJob(Id instanceId, String stepName) {
    this.instanceId = instanceId;
    this.stepName = stepName;
  }

  public void execute(SchedulableContext ctx) {
    try {
      // Parent-first locking: query and lock the parent instance first
      List<Workflow_Instance__c> instances = [
        SELECT Status__c, Current_Step__c, Compensation_Stack__c
        FROM Workflow_Instance__c
        WHERE Id = :this.instanceId
        WITH SYSTEM_MODE
        FOR UPDATE
      ];

      if (instances.isEmpty()) {
        return;
      }

      Workflow_Instance__c instance = instances[0];
      if (
        instance.Status__c != 'Pending' &&
        instance.Status__c != 'Running' &&
        instance.Status__c != 'Compensating' &&
        instance.Status__c != 'Cancelling'
      ) {
        return;
      }

      // Query the step execution record with FOR UPDATE
      List<Workflow_Step_Execution__c> stepExecs = [
        SELECT Status__c, Error_Details__c
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :this.instanceId
          AND Step_Name__c = :this.stepName
          AND Status__c IN ('Running', 'Pending')
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

        // Re-validate status after lock
        if (
          stepExec.Status__c != 'Running' &&
          stepExec.Status__c != 'Pending'
        ) {
          return;
        }

        String errorMsg;
        if (stepExec.Status__c == 'Running') {
          errorMsg = 'Step execution timed out.';
        } else {
          errorMsg = 'Step execution timed out before starting.';
        }

        stepExec.Status__c = 'Failed';
        stepExec.Error_Details__c = errorMsg;
        update as system stepExec;

        WorkflowEngine.failWorkflowInstance(
          this.instanceId,
          this.stepName,
          errorMsg
        );
        return;
      }

      // Check if the workflow instance is still active and waiting on this step (pre-start check)
      Boolean isExpectedStep = false;
      if (
        instance.Status__c == 'Compensating' ||
        instance.Status__c == 'Cancelling'
      ) {
        if (String.isNotBlank(instance.Compensation_Stack__c)) {
          List<String> stack = (List<String>) JSON.deserialize(
            instance.Compensation_Stack__c,
            List<String>.class
          );
          if (
            !stack.isEmpty() &&
            (stack[stack.size() - 1] + '_Compensate') == this.stepName
          ) {
            isExpectedStep = true;
          }
        }
      } else {
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
