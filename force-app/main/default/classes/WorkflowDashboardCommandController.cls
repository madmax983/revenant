/**
 * @description Apex controller backing the operator ACTION endpoints of the Revenant
 * workflow dashboard LWC (start, retry, resume, cancel, compensate, approve, signal
 * inject/redeliver, pause/resume definitions, watchdog bootstrap). Split out of
 * WorkflowDashboardController so each controller stays under the public-surface limit;
 * every endpoint is a thin delegator to a focused command service, preserving the original
 * @AuraEnabled names, signatures, authorization ordering, and AuraHandledException
 * mapping exactly. The read endpoints remain on WorkflowDashboardController.
 */
public inherited sharing class WorkflowDashboardCommandController {
  /**
   * @description Starts a workflow from the dashboard, parsing the optional input JSON and
   * surfacing a friendly error if it is malformed.
   * @param workflowName The WorkflowDefinition class name to start.
   * @param correlationKey The correlation key for the new instance.
   * @param inputJson The optional input payload as JSON, or blank.
   * @return The Id of the started workflow instance.
   */
  @AuraEnabled
  public static Id startWorkflow(
    String workflowName,
    String correlationKey,
    String inputJson
  ) {
    return WorkflowInstanceCommandService.launch(
      workflowName,
      correlationKey,
      inputJson
    );
  }

  /**
   * @description Retries a single failed workflow instance, replaying it on its original
   * definition version.
   * @param instanceId The failed instance to retry.
   */
  @AuraEnabled
  public static void retryWorkflowInstance(Id instanceId) {
    WorkflowInstanceCommandService.retryInstance(instanceId);
  }

  /**
   * @description Re-drives every failed instance matching the operator's current filter in
   * a single bounded action, asynchronously.
   * @param workflowName The workflow name filter, or null for all.
   * @param status The status filter, or null for all.
   * @param searchTerm The free-text search term, or null for none.
   * @return A map describing the launched re-driver.
   */
  @AuraEnabled
  public static Map<String, Object> redriveMatchingInstances(
    String workflowName,
    String status,
    String searchTerm
  ) {
    return WorkflowBulkCommandService.redriveMatching(
      workflowName,
      status,
      searchTerm
    );
  }

  /**
   * @description Cancels every active or stalled instance matching the operator's current
   * filter in a single bounded action, WITHOUT running compensations.
   * @param workflowName The workflow name filter, or null for all.
   * @param status The status filter, or null for all.
   * @param searchTerm The free-text search term, or null for none.
   * @return A map describing the launched bulk-cancel job.
   */
  @AuraEnabled
  public static Map<String, Object> cancelMatchingInstances(
    String workflowName,
    String status,
    String searchTerm
  ) {
    return WorkflowBulkCommandService.cancelMatching(
      workflowName,
      status,
      searchTerm
    );
  }

  /**
   * @description Cancels every active or stalled instance matching the operator's current
   * filter in a single bounded action, running each instance's compensations.
   * @param workflowName The workflow name filter, or null for all.
   * @param status The status filter, or null for all.
   * @param searchTerm The free-text search term, or null for none.
   * @return A map describing the launched bulk-cancel job.
   */
  @AuraEnabled
  public static Map<String, Object> cancelMatchingInstancesWithCompensations(
    String workflowName,
    String status,
    String searchTerm
  ) {
    return WorkflowBulkCommandService.cancelMatchingWithCompensations(
      workflowName,
      status,
      searchTerm
    );
  }

  /**
   * @description Manually resumes a Suspended instance, flipping it back to Running,
   * clearing its sleep/async markers, and re-enqueuing its orchestrator.
   * @param instanceId The suspended instance to resume.
   */
  @AuraEnabled
  public static void resumeWorkflowInstance(Id instanceId) {
    WorkflowInstanceCommandService.resumeInstance(instanceId);
  }

  /**
   * @description Operator action to resume a stalled saga rollback (status
   * CompensationFailed) from exactly the failed compensation point.
   * @param instanceId The CompensationFailed instance whose rollback to resume.
   */
  @AuraEnabled
  public static void resumeCompensationInstance(Id instanceId) {
    WorkflowInstanceCommandService.resumeCompensationRollback(instanceId);
  }

  /**
   * @description Operator action to resume a failed instance past a failed step by
   * supplying that step's resolved output and resuming forward execution.
   * @param instanceId The failed instance to resume.
   * @param stepName The failed step to skip past.
   * @param suppliedOutputJson The operator-supplied output for the skipped step, JSON.
   */
  @AuraEnabled
  public static void resumePastStepInstance(
    Id instanceId,
    String stepName,
    String suppliedOutputJson
  ) {
    WorkflowInstanceCommandService.resumePastStep(
      instanceId,
      stepName,
      suppliedOutputJson
    );
  }

  /**
   * @description Operator action to trigger saga compensation (rollback) of an instance
   * from the dashboard.
   * @param instanceId The instance to compensate.
   * @return The Id of the instance whose compensation was initiated.
   */
  @AuraEnabled
  public static Id compensateWorkflow(Id instanceId) {
    return WorkflowInstanceCommandService.compensate(instanceId);
  }

  // Request wrapper for cancelWorkflow so the runCompensations flag is an @AuraEnabled
  // property rather than a Boolean method parameter (the LWC populates it from the cancel
  // modal's dataset).
  /**
   * @description Request wrapper for cancelWorkflow that carries the target instance and
   * the runCompensations flag as @AuraEnabled properties.
   */
  public class CancelRequest {
    @AuraEnabled
    public Id instanceId;
    @AuraEnabled
    public Boolean runCompensations;
  }

  /**
   * @description Cancels a single instance, optionally running its compensations.
   * @param req The cancel request naming the instance and compensation choice.
   */
  @AuraEnabled
  public static void cancelWorkflow(CancelRequest req) {
    WorkflowInstanceCommandService.cancelSingle(req);
  }

  // Request wrapper for submitApproval: keeps the single @AuraEnabled endpoint (the LWC
  // wraps its existing fields) while moving the approved flag off the parameter list.
  /**
   * @description Request wrapper for submitApproval carrying the instance, approval key,
   * decision, and comments as @AuraEnabled properties.
   */
  public class ApprovalRequest {
    @AuraEnabled
    public Id instanceId;
    @AuraEnabled
    public String approvalKey;
    @AuraEnabled
    public Boolean approved;
    @AuraEnabled
    public String comments;
  }

  /**
   * @description Records an approval decision by delivering an Approve signal, after
   * enforcing the gate's designated approval role and stamping the approver identity.
   * @param req The approval request naming the instance, gate key, and decision.
   */
  @AuraEnabled
  public static void submitApproval(ApprovalRequest req) {
    WorkflowApprovalCommandService.recordApproval(req);
  }

  /**
   * @description Manually bootstraps the watchdog from the dashboard, kicking off a fresh
   * sweep/heartbeat cycle.
   */
  @AuraEnabled
  public static void enqueueWatchdog() {
    WorkflowMaintenanceCommandService.bootstrapWatchdog();
  }

  /**
   * @description Pause a workflow definition (or * for org-wide maintenance mode).
   * @param workflowName The definition name to pause, or * for org-wide.
   * @param reason The operator-supplied reason recorded on the pause record.
   */
  @AuraEnabled
  public static void pauseDefinition(String workflowName, String reason) {
    WorkflowMaintenanceCommandService.pauseDef(workflowName, reason);
  }

  /**
   * @description Resume a paused workflow definition (or * for all).
   * @param workflowName The definition name to resume, or * for all.
   */
  @AuraEnabled
  public static void resumeDefinition(String workflowName) {
    WorkflowMaintenanceCommandService.resumeDef(workflowName);
  }

  /**
   * @description Re-attempts routing of a captured unrouted signal to a matching instance
   * (held as Received for a paused target, without waking it).
   * @param signalId The captured Workflow_Signal__c to redeliver.
   * @return A map with a matched flag indicating whether an instance was found.
   */
  @AuraEnabled
  public static Map<String, Object> redeliverSignal(Id signalId) {
    return WorkflowSignalCommandService.redeliver(signalId);
  }

  /**
   * @description Operator action to manually inject a signal into an instance from the
   * dashboard, gated on the signal-injection permission.
   * @param instanceId The target workflow instance.
   * @param signalName The name of the signal to deliver.
   * @param payloadJson The signal payload as JSON, or blank.
   */
  @AuraEnabled
  public static void injectSignal(
    Id instanceId,
    String signalName,
    String payloadJson
  ) {
    WorkflowSignalCommandService.inject(instanceId, signalName, payloadJson);
  }
}
