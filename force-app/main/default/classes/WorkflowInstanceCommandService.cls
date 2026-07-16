/**
 * @description Per-instance operator lifecycle actions for the workflow dashboard: start,
 * retry, resume (suspended / compensation / past-step), compensate, and single-instance
 * cancel. Extracted from WorkflowDashboardController so the command endpoints stay thin.
 * Preserves the exact authorization ordering, FOR UPDATE lock, system-mode DML, and
 * AuraHandledException messages of the original controller.
 */
public inherited sharing class WorkflowInstanceCommandService {
  /**
   * @description Starts a workflow from the dashboard, parsing the optional input JSON and
   * surfacing a friendly error if it is malformed.
   * @param workflowName The WorkflowDefinition class name to start.
   * @param correlationKey The correlation key for the new instance.
   * @param inputJson The optional input payload as JSON, or blank.
   * @return The Id of the started workflow instance.
   */
  public static Id launch(
    String workflowName,
    String correlationKey,
    String inputJson
  ) {
    WorkflowDashboardSupport.checkAuthorization();
    try {
      Object input = null;
      if (String.isNotBlank(inputJson)) {
        try {
          input = JSON.deserializeUntyped(inputJson);
        } catch (System.JSONException je) {
          AuraHandledException ex = new AuraHandledException(
            'Input Payload is not valid JSON: ' + je.getMessage()
          );
          ex.setMessage('Input Payload is not valid JSON: ' + je.getMessage());
          throw ex;
        }
      }
      return WorkflowEngine.start(workflowName, correlationKey, input);
    } catch (AuraHandledException ahe) {
      throw ahe;
    } catch (Exception ex) {
      AuraHandledException ahe = new AuraHandledException(ex.getMessage());
      ahe.setMessage(ex.getMessage());
      throw ahe;
    }
  }

  /**
   * @description Retries a single failed workflow instance, replaying it on its original
   * definition version.
   * @param instanceId The failed instance to retry.
   */
  public static void retryInstance(Id instanceId) {
    WorkflowDashboardSupport.checkAuthorization();
    try {
      WorkflowRetryService.retryWorkflow(instanceId);
    } catch (Exception ex) {
      throw new AuraHandledException(ex.getMessage());
    }
  }

  /**
   * @description Manually resumes a Suspended instance, flipping it back to Running,
   * clearing its sleep/async markers, and re-enqueuing its orchestrator.
   * @param instanceId The suspended instance to resume.
   */
  public static void resumeInstance(Id instanceId) {
    WorkflowDashboardSupport.checkAuthorization();
    try {
      List<Workflow_Instance__c> instances = [
        SELECT Id, Status__c, Sleep_Until__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId AND Status__c = 'Suspended'
        WITH SYSTEM_MODE
        LIMIT 1
        FOR UPDATE
      ];
      if (!instances.isEmpty()) {
        Workflow_Instance__c inst = instances[0];
        inst.Status__c = 'Running';
        inst.Sleep_Until__c = null;
        inst.Async_Job_Id__c = null;
        update as system inst;
        WorkflowOrchestratorEnqueue.enqueueOrchestrators(
          new List<Id>{ inst.Id }
        );
      }
    } catch (Exception ex) {
      throw new AuraHandledException(ex.getMessage());
    }
  }

  /**
   * @description Operator action to resume a stalled saga rollback (status
   * CompensationFailed) from exactly the failed compensation point. Idempotent: a
   * repeated/overlapping call after the rollback has already resumed is a safe no-op.
   * @param instanceId The CompensationFailed instance whose rollback to resume.
   */
  public static void resumeCompensationRollback(Id instanceId) {
    WorkflowDashboardSupport.checkAuthorization();
    try {
      WorkflowCompensation.resumeCompensation(instanceId);
    } catch (Exception ex) {
      throw new AuraHandledException(ex.getMessage());
    }
  }

  /**
   * @description Operator action to resume a failed instance past a failed step by
   * supplying that step's resolved output and resuming forward execution. Gated on the
   * Workflow_Step_Skip permission (or Modify All Data).
   * @param instanceId The failed instance to resume.
   * @param stepName The failed step to skip past.
   * @param suppliedOutputJson The operator-supplied output for the skipped step, JSON.
   */
  public static void resumePastStep(
    Id instanceId,
    String stepName,
    String suppliedOutputJson
  ) {
    WorkflowDashboardSupport.checkAuthorization();
    if (
      !FeatureManagement.checkPermission('Workflow_Step_Skip') &&
      !WorkflowDashboardSupport.currentUserHasModifyAllData()
    ) {
      AuraHandledException ex = new AuraHandledException(
        'Unauthorized: skipping a step requires the "Workflow_Step_Skip" permission.'
      );
      ex.setMessage(
        'Unauthorized: skipping a step requires the "Workflow_Step_Skip" permission.'
      );
      throw ex;
    }
    try {
      WorkflowOperatorSkip.resumePastStep(
        instanceId,
        stepName,
        suppliedOutputJson
      );
    } catch (Exception ex) {
      AuraHandledException aex = new AuraHandledException(ex.getMessage());
      aex.setMessage(ex.getMessage());
      throw aex;
    }
  }

  /**
   * @description Operator action to trigger saga compensation (rollback) of an instance
   * from the dashboard.
   * @param instanceId The instance to compensate.
   * @return The Id of the instance whose compensation was initiated.
   */
  public static Id compensate(Id instanceId) {
    WorkflowDashboardSupport.checkAuthorization();
    try {
      return WorkflowCompensation.compensate(instanceId);
    } catch (Exception ex) {
      throw new AuraHandledException(ex.getMessage());
    }
  }

  /**
   * @description Cancels a single instance, optionally running its compensations.
   * @param req The cancel request naming the instance and compensation choice.
   */
  public static void cancelSingle(
    WorkflowDashboardCommandController.CancelRequest req
  ) {
    WorkflowDashboardSupport.checkAuthorization();
    try {
      if (req.runCompensations) {
        WorkflowCancellation.cancelWithCompensations(req.instanceId);
      } else {
        WorkflowEngine.cancel(req.instanceId);
      }
    } catch (Exception ex) {
      throw new AuraHandledException(ex.getMessage());
    }
  }
}
