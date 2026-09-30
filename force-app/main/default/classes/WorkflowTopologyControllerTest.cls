/**
 * Tests for WorkflowTopologyController (issue #141).
 */
@IsTest
private class WorkflowTopologyControllerTest {
  private static final String LINEAR = 'WorkflowTopologyTest.LinearWorkflow';

  private static User userWithNoGrant() {
    Profile stdProfile = [
      SELECT Id
      FROM Profile
      WHERE Name = 'Standard User'
      LIMIT 1
    ];
    User u = new User(
      Alias = 'topo',
      Email = 'topology@testorg.com',
      EmailEncodingKey = 'UTF-8',
      LastName = 'Topology',
      LanguageLocaleKey = 'en_US',
      LocaleSidKey = 'en_US',
      ProfileId = stdProfile.Id,
      TimeZoneSidKey = 'America/Los_Angeles',
      UserName = 'topology_' + DateTime.now().getTime() + '@testorg.com'
    );
    insert u;
    return u;
  }

  @IsTest
  static void definitionEndpointReturnsGraph() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowTopology.Graph graph = WorkflowTopologyController.getWorkflowTopology(
        LINEAR
      );
      System.assertEquals(3, graph.nodes.size());
      System.assertEquals(null, graph.overlay);
    }
  }

  @IsTest
  static void instanceEndpointReturnsGraphWithOverlay() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = LINEAR,
        Status__c = 'Running',
        Current_Step__c = 'WorkflowTopologyTest.MiddleStep',
        Correlation_Key__c = 'topology-endpoint'
      );
      insert inst;

      WorkflowTopology.Graph graph = WorkflowTopologyController.getInstanceTopology(
        inst.Id
      );
      System.assertEquals(3, graph.nodes.size());
      System.assertEquals(inst.Id, graph.overlay.instanceId);
      System.assertEquals(
        'WorkflowTopologyTest.MiddleStep',
        graph.overlay.currentStep
      );
    }
  }

  @IsTest
  static void userWithNoGrantIsRejected() {
    User noGrant;
    System.runAs(new User(Id = UserInfo.getUserId())) {
      noGrant = userWithNoGrant();
    }
    System.runAs(noGrant) {
      try {
        WorkflowTopologyController.getWorkflowTopology(LINEAR);
        System.assert(false, 'Expected AuraHandledException');
      } catch (AuraHandledException e) {
        System.assert(e.getMessage().contains('Unauthorized'), e.getMessage());
      }
      try {
        WorkflowTopologyController.getInstanceTopology(null);
        System.assert(false, 'Expected AuraHandledException');
      } catch (AuraHandledException e) {
        System.assert(e.getMessage().contains('Unauthorized'), e.getMessage());
      }
    }
  }
}
