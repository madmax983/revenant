@isTest
public class WorkflowDeadlineTest {

  public class TestDeadlineWorkflow implements WorkflowDefinition, ExecutionTimeoutConfigurable {
    public List<String> getSteps() {
      return new List<String>{'WorkflowDeadlineTest.TestStep'};
    }
    public String getInitialStep() {
      return 'WorkflowDeadlineTest.TestStep';
    }
    public String getNextStep(String currentStepName, StepResult stepResult) {
      return null;
    }
    public Integer getExecutionTimeoutSeconds() {
      return 60; // 1 minute deadline
    }
  }

  public class TestStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, 'Done');
    }
  }

  @isTest
  static void testStartStampsDeadline() {
    WorkflowEngine.disableQueueableInTest = true;

    Test.startTest();
    Id instanceId = WorkflowEngine.start(
      'WorkflowDeadlineTest.TestDeadlineWorkflow',
      'Deadline-Start-Key',
      null
    );
    Test.stopTest();

    Workflow_Instance__c inst = [
      SELECT Id, Status__c, Deadline_At__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];

    System.assertNotEquals(null, inst.Deadline_At__c, 'Deadline_At__c should be stamped');
    // Ensure deadline is roughly now + 60s
    Long diffSeconds = Math.abs(inst.Deadline_At__c.getTime() - DateTime.now().getTime()) / 1000;
    System.assert(diffSeconds <= 65, 'Deadline should be stamped roughly 60 seconds from now: ' + diffSeconds);
  }
}
