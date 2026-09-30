/**
 * @description Read endpoints of the workflow topology graph (issue #141). It
 * is a separate controller because WorkflowDashboardController is at the PMD
 * ExcessivePublicCount limit. It uses the same view gate as the dashboard.
 */
public inherited sharing class WorkflowTopologyController {
  /**
   * @description Returns the topology graph of a definition: the steps and the
   * edges that the validator probe finds. Read-only.
   * @param workflowName The workflow definition name.
   * @return The graph. It has no overlay.
   */
  @AuraEnabled(cacheable=true)
  public static WorkflowTopology.Graph getWorkflowTopology(
    String workflowName
  ) {
    WorkflowDashboardSupport.checkAuthorization();
    return WorkflowTopology.build(workflowName);
  }

  /**
   * @description Returns the topology graph of the definition of an instance,
   * with the path and the current step of the instance. Read-only. Not
   * cacheable: the position changes as the instance runs.
   * @param instanceId The workflow instance.
   * @return The graph with its overlay.
   */
  @AuraEnabled
  public static WorkflowTopology.Graph getInstanceTopology(Id instanceId) {
    WorkflowDashboardSupport.checkAuthorization();
    return WorkflowTopology.forInstance(instanceId);
  }
}
