/**
 * @description Failure-transition surface for the Revenant engine. Resolves a
 * failing workflow instance to Failed, routes it to a defined error step, or opens
 * compensation when a compensable saga has completed steps to unwind, recording the
 * error/category/attempt count and publishing lifecycle/alert side effects.
 * Extracted from `WorkflowEngine`; the public `failWorkflowInstance` entry points
 * stay resident on the engine and delegate to `failInstance` here. The resident
 * `WorkflowEngine.FailInstanceRequest` DTO, the `WorkflowEngine.CAT_*` failure
 * categories and the resident shared helpers `WorkflowEngine.enqueueOrchestratorForInstance`
 * and `WorkflowCompensation.preCreateFirstCompensationStep` are referenced fully qualified.
 * Parent-completion notification is delegated to `WorkflowChildService`. All
 * SOQL/DML executes in system mode.
 */
public inherited sharing class WorkflowFailureService {
  /**
   * @description Fails an instance with an explicit failure category, resolving
   * the current attempt count from the step's latest execution before delegating
   * to the record-level path.
   * @param req the fail request (instanceId, stepName, errorMessage, failureCategory)
   */
  public static void failInstance(WorkflowEngine.FailInstanceRequest req) {
    Id instanceId = req.instanceId;
    String stepName = req.stepName;
    String failureCategory = req.failureCategory;
    List<Workflow_Instance__c> instances = [
      SELECT
        Id,
        Name,
        Status__c,
        Current_Step__c,
        Error_Message__c,
        Compensation_Stack__c,
        Workflow_Name__c,
        Correlation_Key__c,
        Root_Correlation_Key__c,
        Failure_Category__c,
        Concurrency_Parked__c,
        Concurrency_Slot_Held__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
      WITH SYSTEM_MODE
      LIMIT 1
      FOR UPDATE
    ];
    if (instances.isEmpty()) {
      return;
    }
    Workflow_Instance__c instance = instances[0];

    // Determine attempt count
    Integer attemptCount = 1;
    List<Workflow_Step_Execution__c> stepExecs = [
      SELECT Retry_Count__c
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c = :instanceId AND Step_Name__c = :stepName
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC, Id DESC
      LIMIT 1
    ];
    if (!stepExecs.isEmpty() && stepExecs[0].Retry_Count__c != null) {
      attemptCount = (Integer) stepExecs[0].Retry_Count__c;
      if (failureCategory != WorkflowEngine.CAT_RETRIES_EXHAUSTED) {
        attemptCount += 1;
      }
    }

    req.instance = instance;
    req.attemptCount = attemptCount;
    failResolvedInstance(req);
  }

  /**
   * @description Record-level fail transition: routes the instance to Failed, or
   * to Compensating when a compensable saga has completed steps to unwind, records
   * the error/category/attempt count, and publishes lifecycle/alert side effects.
   * @param req the fail request with a pre-queried instance record and attempt count
   */
  public static void failResolvedInstance(
    WorkflowEngine.FailInstanceRequest req
  ) {
    Workflow_Instance__c instance = req.instance;
    Boolean isCompFailure = isCompensationContext(instance, req.stepName);

    if (tryErrorRouting(req, isCompFailure)) {
      return;
    }

    // Check if there are compensations to run
    if (!hasPendingCompensations(instance)) {
      failInstanceTerminally(req);
      return;
    }

    if (isCompensationContext(instance, req.stepName)) {
      failCompensationTerminally(req);
      return;
    }

    beginCompensation(req);
  }

  private static Boolean isCompensationContext(
    Workflow_Instance__c instance,
    String stepName
  ) {
    return instance.Status__c == 'Compensating' ||
      instance.Status__c == 'Cancelling' ||
      (String.isNotBlank(stepName) && stepName.endsWith('_Compensate'));
  }

  private static Boolean hasPendingCompensations(
    Workflow_Instance__c instance
  ) {
    if (String.isBlank(instance.Compensation_Stack__c)) {
      return false;
    }
    List<String> stack = (List<String>) JSON.deserialize(
      instance.Compensation_Stack__c,
      List<String>.class
    );
    return !stack.isEmpty();
  }

  // Best-effort error routing: if the workflow defines an error step, cancel
  // siblings, insert the error step, and re-run. Returns true when routing
  // consumed the failure (caller returns), false to fall through to the
  // compensation/terminal-fail path. Never lets a routing failure mask the
  // original error.
  private static Boolean tryErrorRouting(
    WorkflowEngine.FailInstanceRequest req,
    Boolean isCompFailure
  ) {
    if (isCompFailure) {
      return false;
    }
    Workflow_Instance__c instance = req.instance;
    try {
      Type wfType = WorkflowTypeResolver.resolve(
        instance.Workflow_Name__c,
        WorkflowTypeResolver.extractNamespace(instance.Workflow_Name__c)
      );
      if (wfType == null) {
        return false;
      }
      WorkflowDefinition def = (WorkflowDefinition) wfType.newInstance();
      if (!(def instanceof ErrorRoutingWorkflow)) {
        return false;
      }
      String truncatedError = req.errorMessage != null
        ? req.errorMessage.left(20000)
        : null;
      StepError err = new StepError(
        req.stepName,
        truncatedError,
        req.attemptCount
      );
      String errorStepName = ((ErrorRoutingWorkflow) def)
        .getErrorStep(req.stepName, err);
      if (String.isBlank(errorStepName)) {
        return false;
      }
      routeToErrorStep(req, errorStepName, truncatedError);
      return true;
    } catch (Exception ignored) {
      // Error-routing is best-effort; a routing failure must not mask the original error.
      return false;
    }
  }

  private static void routeToErrorStep(
    WorkflowEngine.FailInstanceRequest req,
    String errorStepName,
    String truncatedError
  ) {
    Workflow_Instance__c instance = req.instance;
    cancelSiblingStepsForErrorRouting(instance, req.stepName);

    WorkflowOrchestratorEnqueue.abortScheduledJobs(instance.Id);

    Workflow_Step_Execution__c nextStepExec = new Workflow_Step_Execution__c();
    nextStepExec.Workflow_Instance__c = instance.Id;
    nextStepExec.Step_Name__c = errorStepName;
    nextStepExec.Status__c = 'Pending';
    nextStepExec.Retry_Count__c = 0;

    Map<String, Object> errorCaptures = new Map<String, Object>{
      '__failedStepName' => req.stepName,
      '__errorMessage' => truncatedError,
      '__attemptCount' => req.attemptCount
    };
    nextStepExec.Captured_Values__c = WorkflowPayloadOffload.savePayloadIfNeeded(
      instance.Id,
      JSON.serialize(errorCaptures),
      'Captures_' + errorStepName.replaceAll('[^a-zA-Z0-9]', '_')
    );
    Database.insert(nextStepExec, true, AccessLevel.SYSTEM_MODE);

    instance.Current_Step__c = errorStepName;
    instance.Status__c = 'Running';
    instance.Sleep_Until__c = null;
    instance.Async_Job_Id__c = null;
    Database.update(instance, true, AccessLevel.SYSTEM_MODE);

    WorkflowTimeoutArming.scheduleTimeoutJobForInstance(instance);
    WorkflowEngine.enqueueOrchestratorForInstance(instance.Id);
  }

  private static void cancelSiblingStepsForErrorRouting(
    Workflow_Instance__c instance,
    String stepName
  ) {
    if (
      String.isBlank(instance.Current_Step__c) ||
      !instance.Current_Step__c.contains(',')
    ) {
      return;
    }
    List<String> activeSteps = instance.Current_Step__c.split(',');
    List<Workflow_Step_Execution__c> siblingExecs = [
      SELECT Id, Status__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :instance.Id
        AND Step_Name__c IN :activeSteps
        AND Step_Name__c != :stepName
        AND Status__c IN ('Pending', 'Retrying')
      WITH SYSTEM_MODE
      FOR UPDATE
    ];
    for (Workflow_Step_Execution__c sibling : siblingExecs) {
      sibling.Status__c = 'Cancelled';
    }
    if (!siblingExecs.isEmpty()) {
      Database.update(siblingExecs, true, AccessLevel.SYSTEM_MODE);
    }
  }

  private static void failInstanceTerminally(
    WorkflowEngine.FailInstanceRequest req
  ) {
    Workflow_Instance__c instance = req.instance;
    instance.Status__c = 'Failed';
    instance.Failure_Category__c = req.failureCategory;
    instance.Error_Message__c = ('Failed at step ' +
      req.stepName +
      ': ' +
      req.errorMessage)
      .left(255);
    Database.update(instance, true, AccessLevel.SYSTEM_MODE);
    WorkflowParentNotifier.notifyParentCompletion(instance);
    WorkflowAlertManager.sendAlert(instance, instance.Error_Message__c);
    WorkflowLifecyclePublisher.publish(instance);
  }

  private static void failCompensationTerminally(
    WorkflowEngine.FailInstanceRequest req
  ) {
    Workflow_Instance__c instance = req.instance;
    Boolean wasCancelling =
      instance.Status__c == 'Cancelling' ||
      (instance.Error_Message__c != null &&
      instance.Error_Message__c.contains('Cancelled by user'));
    instance.Status__c = 'CompensationFailed';
    instance.Failure_Category__c = WorkflowEngine.CAT_COMPENSATION_FAILED;
    instance.Error_Message__c = buildRollbackIncompleteMessage(
        wasCancelling,
        'Rollback incomplete at compensation step ' +
          req.stepName +
          ': ' +
          req.errorMessage
      )
      .left(255);
    instance.Sleep_Until__c = null;
    instance.Async_Job_Id__c = null;
    Database.update(instance, true, AccessLevel.SYSTEM_MODE);
    WorkflowParentNotifier.notifyParentCompletion(instance);
    WorkflowAlertManager.sendAlert(instance, instance.Error_Message__c);
    WorkflowLifecyclePublisher.publish(instance);
  }

  private static void beginCompensation(
    WorkflowEngine.FailInstanceRequest req
  ) {
    Workflow_Instance__c instance = req.instance;
    instance.Status__c = 'Compensating';
    instance.Error_Message__c = ('Failed at step ' +
      req.stepName +
      ': ' +
      req.errorMessage)
      .left(255);
    WorkflowCompensation.preCreateFirstCompensationStep(instance);
    Database.update(instance, true, AccessLevel.SYSTEM_MODE);

    WorkflowEngine.enqueueOrchestratorForInstance(instance.Id);
  }

  // Prepends the cancel-phase marker to a stalled-rollback detail message when the
  // rollback was cancel-driven. Mirrors the resident engine helper of the same name
  // so the failure path keeps its message text byte-identical.
  private static String buildRollbackIncompleteMessage(
    Boolean wasCancelling,
    String detail
  ) {
    return (wasCancelling ? 'Cancelled by user. ' : '') + detail;
  }
}
