/**
 * @description Read endpoints of the workflow topology graph (issue #141). It
 * is a separate controller because WorkflowDashboardController is at the PMD
 * ExcessivePublicCount limit. It uses the same view gate as the dashboard.
 */
public inherited sharing class WorkflowTopologyController {
  /**
   * @description Returns the topology graph of a definition: the steps and the
   * edges that the validator probe finds. Read-only. It is cacheable, so the
   * platform stops DML from author code in the probe.
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
   * with the path and the current step of the instance. Read-only. It is
   * cacheable, so the platform stops DML from author code in the probe. The
   * LWC sends a new cacheBuster on each read to get the live position.
   * @param instanceId The workflow instance.
   * @param cacheBuster A value that changes the client cache key. Not used.
   * @return The graph with its overlay.
   */
  @AuraEnabled(cacheable=true)
  public static WorkflowTopology.Graph getInstanceTopology(
    Id instanceId,
    String cacheBuster
  ) {
    WorkflowDashboardSupport.checkAuthorization();
    return WorkflowTopology.forInstance(instanceId);
  }
}
