/**
 * @description Single-target manual-resume surface for the Revenant engine.
 * Resumes one suspended workflow instance &mdash; matched by correlation key or by
 * instance Id &mdash; flipping it to Running, persisting the resume payload on its
 * active step, disarming any armed timed-wait deadline (issue #35) and re-arming
 * the step timeout before enqueuing the orchestrator. Extracted from
 * `WorkflowEngine`; the batch (`List<WorkflowEngine.ResumeRequest>`) path lives on
 * {@link WorkflowBulkResumeService}. The resident `WorkflowEngine.WorkflowException`
 * type is referenced fully qualified. All SOQL/DML executes in system mode and the
 * instance/step locking (FOR UPDATE) and statement order are preserved from the
 * pre-extraction engine.
 */
public inherited sharing class WorkflowResumeService {
  /**
   * @description Stores the resume payload on the instance's current active step
   * (if any), flipping it to Running and re-arming or clearing its watchdog
   * deadline.
   * @param instance the resumed instance (Running)
   * @param payload the resume payload to persist on the active step
   */
  private static void applyResumePayloadToActiveStep(
    Workflow_Instance__c instance,
    String payload
  ) {
    if (String.isBlank(instance.Current_Step__c)) {
      return;
    }
    List<Workflow_Step_Execution__c> activeSteps = [
      SELECT Id, Output__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :instance.Id
        AND Step_Name__c = :instance.Current_Step__c
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC, Id DESC
      LIMIT 1
    ];
    if (activeSteps.isEmpty()) {
      return;
    }
    Workflow_Step_Execution__c stepExec = activeSteps[0];
    stepExec.Status__c = 'Running';
    stepExec.Output__c = WorkflowPayloadOffload.savePayloadIfNeeded(
      instance.Id,
      payload,
      'Resume_' + stepExec.Id
    );
    Integer timeout = WorkflowStepTimeoutConfig.getStepTimeoutSeconds(
      instance.Current_Step__c,
      WorkflowTypeResolver.extractNamespace(instance.Workflow_Name__c)
    );
    stepExec.Timeout_At__c = (timeout != null &&
      timeout > 0)
      ? DateTime.now().addSeconds(timeout)
      : null;
    Database.update(stepExec, true, AccessLevel.SYSTEM_MODE);
  }

  /**
   * @description Resumes a suspended workflow matching the correlation key.
   * @param correlationKey correlation key of the suspended instance
   * @param payload resume payload delivered to the waiting step
   */
  public static void resume(String correlationKey, String payload) {
    List<Workflow_Instance__c> instances = [
      SELECT Id, Workflow_Name__c, Current_Step__c
      FROM Workflow_Instance__c
      WHERE Correlation_Key__c = :correlationKey AND Status__c = 'Suspended'
      WITH SYSTEM_MODE
      LIMIT 1
      FOR UPDATE
    ];

    if (instances.isEmpty()) {
      throw new WorkflowEngine.WorkflowException(
        'No suspended workflow found with correlation key: ' + correlationKey
      );
    }

    Workflow_Instance__c instance = instances[0];
    instance.Status__c = 'Running';
    // Disarm any armed timed-wait timeout so the watchdog does not mis-route to
    // the fallback step after a manual resume wins the race (issue #35).
    instance.Sleep_Until__c = null;
    Database.update(instance, true, AccessLevel.SYSTEM_MODE);

    // If there is an active step, we can store the resume payload in its step execution record
    applyResumePayloadToActiveStep(instance, payload);

    WorkflowTimeoutArming.scheduleTimeoutJobForInstance(instance.Id);

    if (Test.isRunningTest()) {
      System.enqueueJob(new WorkflowOrchestrator(instance.Id));
    } else {
      WorkflowOrchestratorEnqueue.enqueueOrchestrator(instance.Id, null);
    }
  }

  /**
   * @description Resumes a suspended workflow instance directly by its database ID.
   * @param instanceId Id of the suspended instance
   * @param payload resume payload delivered to the waiting step
   */
  public static void resumeInstance(Id instanceId, String payload) {
    List<Workflow_Instance__c> instances = [
      SELECT Id, Workflow_Name__c, Current_Step__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId AND Status__c = 'Suspended'
      WITH SYSTEM_MODE
      LIMIT 1
      FOR UPDATE
    ];

    if (instances.isEmpty()) {
      throw new WorkflowEngine.WorkflowException(
        'No suspended workflow found with ID: ' + instanceId
      );
    }

    Workflow_Instance__c instance = instances[0];
    instance.Status__c = 'Running';
    // Disarm any armed timed-wait timeout so the watchdog does not mis-route to
    // the fallback step after a manual resume wins the race (issue #35).
    instance.Sleep_Until__c = null;
    Database.update(instance, true, AccessLevel.SYSTEM_MODE);

    // If there is an active step, we can store the resume payload in its step execution record
    applyResumePayloadToActiveStep(instance, payload);

    WorkflowTimeoutArming.scheduleTimeoutJobForInstance(instance.Id);

    if (Test.isRunningTest()) {
      System.enqueueJob(new WorkflowOrchestrator(instance.Id));
    } else {
      WorkflowOrchestratorEnqueue.enqueueOrchestrator(instance.Id, null);
    }
  }

  /**
   * @description Resumes a suspended workflow instance by ID and step name.
   * @param instanceId Id of the suspended instance
   * @param stepName name of the waiting step to resume (advisory)
   * @param payload resume payload delivered to the waiting step
   */
  public static void resume(Id instanceId, String stepName, String payload) {
    resumeInstance(instanceId, payload);
  }
}
