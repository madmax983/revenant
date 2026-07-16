/**
 * @description Stateless helper routines shared by the timeout→fail sweep (§1)
 * and the deadline-expiry sweep (§1b): error-routing classification, latest
 * retry-count loading, actionability predicates, terminal-failure notification,
 * and bounded orchestrator enqueue. Extracted from WorkflowEngine as part of the
 * watchdog decomposition.
 *
 * All DML and SOQL run in system mode so the engine can drive workflows
 * regardless of the invoking user's object permissions.
 */
public inherited sharing class WorkflowTimeoutSupport {
  /**
   * @description Determine, per distinct workflow name, whether it is an
   * ErrorRoutingWorkflow.
   * @param parents the locked parent instances of the timed-out steps
   * @return whether each distinct workflow name is an ErrorRoutingWorkflow
   */
  public static Map<String, Boolean> classifyRoutingWorkflows(
    Map<Id, Workflow_Instance__c> parents
  ) {
    Map<String, Boolean> isRoutingWflow = new Map<String, Boolean>();
    for (Workflow_Instance__c parent : parents.values()) {
      if (String.isBlank(parent.Workflow_Name__c)) {
        continue;
      }
      String wfName = parent.Workflow_Name__c;
      if (isRoutingWflow.containsKey(wfName)) {
        continue;
      }
      Type wflowType = WorkflowTypeResolver.resolve(
        wfName,
        WorkflowTypeResolver.extractNamespace(wfName)
      );
      if (wflowType != null) {
        Object instObj = wflowType.newInstance();
        isRoutingWflow.put(wfName, instObj instanceof ErrorRoutingWorkflow);
      } else {
        isRoutingWflow.put(wfName, false);
      }
    }
    return isRoutingWflow;
  }

  /**
   * @description Fetch the latest retry count per (instance, step) for routing
   * instances only.
   * @param parents the locked parent instances of the timed-out steps
   * @param isRoutingWflow whether each workflow name is an ErrorRoutingWorkflow
   * @return the latest retry count per '{instanceId}:{stepName}' key
   */
  public static Map<String, Integer> loadLatestRetryCounts(
    Map<Id, Workflow_Instance__c> parents,
    Map<String, Boolean> isRoutingWflow
  ) {
    Set<Id> routingInstanceIds = new Set<Id>();
    for (Workflow_Instance__c parent : parents.values()) {
      if (
        String.isNotBlank(parent.Workflow_Name__c) &&
        isRoutingWflow.get(parent.Workflow_Name__c) == true
      ) {
        routingInstanceIds.add(parent.Id);
      }
    }

    Map<String, Integer> latestRetryCounts = new Map<String, Integer>();
    if (routingInstanceIds.isEmpty()) {
      return latestRetryCounts;
    }
    for (Workflow_Step_Execution__c exec : [
      SELECT Workflow_Instance__c, Step_Name__c, Retry_Count__c
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c IN :routingInstanceIds
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC, Id DESC
    ]) {
      String key = exec.Workflow_Instance__c + ':' + exec.Step_Name__c;
      if (!latestRetryCounts.containsKey(key)) {
        latestRetryCounts.put(
          key,
          exec.Retry_Count__c != null ? (Integer) exec.Retry_Count__c : 0
        );
      }
    }
    return latestRetryCounts;
  }

  /**
   * @description A parent is actionable for a timed-out step only in a
   * self-driving status.
   * @param parent the locked parent instance
   * @return true when the parent is in a self-driving status
   */
  public static Boolean isTimedOutParentActionable(
    Workflow_Instance__c parent
  ) {
    return parent.Status__c == 'Pending' ||
      parent.Status__c == 'Running' ||
      parent.Status__c == 'Compensating' ||
      parent.Status__c == 'Cancelling';
  }

  /**
   * @description A step is still enforceable while Running or Pending.
   * @param s the locked step execution
   * @return true when the step is Running or Pending
   */
  public static Boolean isRunnableStepStatus(Workflow_Step_Execution__c s) {
    return s.Status__c == 'Running' || s.Status__c == 'Pending';
  }

  /**
   * @description Notify parent-completion for exactly the instances that reached
   * a terminal Failed state (shared by the timed-out-step and deadline flush
   * paths).
   * @param updated the instances updated by the flushing section
   */
  public static void notifyTerminalFailures(
    List<Workflow_Instance__c> updated
  ) {
    List<Workflow_Instance__c> terminalUpdated = new List<Workflow_Instance__c>();
    for (Workflow_Instance__c inst : updated) {
      if (inst.Status__c == 'Failed') {
        terminalUpdated.add(inst);
      }
    }
    WorkflowParentNotifier.notifyParentCompletion(terminalUpdated);
  }

  /**
   * @description Enqueue orchestrators for the given instances unless nothing is
   * pending or the test opt-out is active.
   * @param ids the instance ids to enqueue orchestrators for
   */
  public static void enqueueOrchestratorsBounded(List<Id> ids) {
    if (ids.isEmpty()) {
      return;
    }
    if (Test.isRunningTest() && WorkflowEngine.disableQueueableInTest) {
      return;
    }
    WorkflowOrchestratorEnqueue.enqueueOrchestrators(ids);
  }
}
