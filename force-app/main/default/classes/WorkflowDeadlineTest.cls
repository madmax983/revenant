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

  public class TestContinueWorkflow implements WorkflowDefinition, ExecutionTimeoutConfigurable {
    public List<String> getSteps() {
      return new List<String>{'WorkflowDeadlineTest.TestContinueStep'};
    }
    public String getInitialStep() {
      return 'WorkflowDeadlineTest.TestContinueStep';
    }
    public String getNextStep(String currentStepName, StepResult stepResult) {
      return null;
    }
    public Integer getExecutionTimeoutSeconds() {
      return 120; // 2 minute deadline
    }
  }

  public class TestContinueStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      return StepResult.continueAsNew(null, null);
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

  @isTest
  static void testContinueAsNewStampsDeadline() {
    WorkflowEngine.disableQueueableInTest = true;

    Id instanceId = WorkflowEngine.start(
      'WorkflowDeadlineTest.TestContinueWorkflow',
      'Deadline-Continue-Key',
      null
    );

    Test.startTest();
    // Run the step which triggers continueAsNew
    WorkflowEngine.runStep(instanceId, 'WorkflowDeadlineTest.TestContinueStep');
    Test.stopTest();

    // Verify successor exists and has a deadline stamped
    List<Workflow_Instance__c> successors = [
      SELECT Id, Status__c, Deadline_At__c
      FROM Workflow_Instance__c
      WHERE Previous_Instance__c = :instanceId
    ];
    System.assertEquals(1, successors.size(), 'Successor should have been spawned');
    System.assertNotEquals(null, successors[0].Deadline_At__c, 'Successor Deadline_At__c should be stamped');
    
    Long diffSeconds = Math.abs(successors[0].Deadline_At__c.getTime() - DateTime.now().getTime()) / 1000;
    System.assert(diffSeconds <= 125, 'Successor deadline should be roughly 120 seconds from now: ' + diffSeconds);
  }
}
