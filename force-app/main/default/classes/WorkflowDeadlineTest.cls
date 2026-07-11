@IsTest
public class WorkflowDeadlineTest {
  // Query-wrapper builders: assemble the WorkflowDashboardController read-method request
  // objects by field assignment (a 1:1 repackaging of the former positional arguments).
  private static WorkflowDashboardController.InstanceQuery iqOf(
    String workflowName,
    String status,
    String searchTerm,
    Integer limitSize,
    Integer offsetSize,
    String cacheBuster
  ) {
    WorkflowDashboardController.InstanceQuery q = new WorkflowDashboardController.InstanceQuery();
    q.workflowName = workflowName;
    q.status = status;
    q.searchTerm = searchTerm;
    q.limitSize = limitSize;
    q.offsetSize = offsetSize;
    q.cacheBuster = cacheBuster;
    return q;
  }

  private static WorkflowDashboardController.StalledQuery stalledOf(
    String workflowName,
    String searchTerm,
    Integer thresholdMinutes,
    Integer limitSize,
    Integer offsetSize,
    String cacheBuster
  ) {
    WorkflowDashboardController.StalledQuery q = new WorkflowDashboardController.StalledQuery();
    q.workflowName = workflowName;
    q.searchTerm = searchTerm;
    q.thresholdMinutes = thresholdMinutes;
    q.limitSize = limitSize;
    q.offsetSize = offsetSize;
    q.cacheBuster = cacheBuster;
    return q;
  }

  public class TestDeadlineWorkflow implements WorkflowDefinition, ExecutionTimeoutConfigurable {
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowDeadlineTest.TestStep' };
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
      return new List<String>{ 'WorkflowDeadlineTest.TestContinueStep' };
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

  @IsTest
  static void testStartStampsDeadline() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
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

      System.assertNotEquals(
        null,
        inst.Deadline_At__c,
        'Deadline_At__c should be stamped'
      );
      // Ensure deadline is roughly now + 60s
      Long diffSeconds =
        Math.abs(inst.Deadline_At__c.getTime() - DateTime.now().getTime()) /
        1000;
      System.assert(
        diffSeconds <= 65,
        'Deadline should be stamped roughly 60 seconds from now: ' + diffSeconds
      );
    }
  }

  @IsTest
  static void testContinueAsNewStampsDeadline() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;

      Id instanceId = WorkflowEngine.start(
        'WorkflowDeadlineTest.TestContinueWorkflow',
        'Deadline-Continue-Key',
        null
      );

      Test.startTest();
      // Run the step which triggers continueAsNew
      WorkflowEngine.runStep(
        instanceId,
        'WorkflowDeadlineTest.TestContinueStep'
      );
      Test.stopTest();

      // Verify successor exists and has a deadline stamped
      List<Workflow_Instance__c> successors = [
        SELECT Id, Status__c, Deadline_At__c
        FROM Workflow_Instance__c
        WHERE Previous_Instance__c = :instanceId
      ];
      System.assertEquals(
        1,
        successors.size(),
        'Successor should have been spawned'
      );
      System.assertNotEquals(
        null,
        successors[0].Deadline_At__c,
        'Successor Deadline_At__c should be stamped'
      );

      Long diffSeconds =
        Math.abs(
          successors[0].Deadline_At__c.getTime() - DateTime.now().getTime()
        ) / 1000;
      System.assert(
        diffSeconds <= 125,
        'Successor deadline should be roughly 120 seconds from now: ' +
        diffSeconds
      );
    }
  }

  @IsTest
  static void testWatchdogSweepExpiredNoCompensation() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;

      // Create a running instance that has already expired
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowDeadlineTest.TestDeadlineWorkflow',
        Status__c = 'Running',
        Correlation_Key__c = 'Deadline-Expired-NoComp',
        Deadline_At__c = DateTime.now().addSeconds(-10)
      );
      insert inst;

      // Add an active step execution row
      Workflow_Step_Execution__c step = new Workflow_Step_Execution__c(
        Workflow_Instance__c = inst.Id,
        Step_Name__c = 'WorkflowDeadlineTest.TestStep',
        Status__c = 'Running',
        Retry_Count__c = 0
      );
      insert step;

      Test.startTest();
      WorkflowEngine.processWatchdogHeartbeat();
      Test.stopTest();

      // Reload the instance
      Workflow_Instance__c reloadedInst = [
        SELECT Status__c, Error_Message__c, Terminal_At__c
        FROM Workflow_Instance__c
        WHERE Id = :inst.Id
      ];

      System.assertEquals(
        'Failed',
        reloadedInst.Status__c,
        'Status should be Failed'
      );
      System.assertEquals(
        'Execution deadline exceeded',
        reloadedInst.Error_Message__c
      );
      System.assertNotEquals(
        null,
        reloadedInst.Terminal_At__c,
        'Terminal_At__c should be set'
      );

      // Reload the step and check it was NOT mutated to Failed (remains Running or unchanged)
      Workflow_Step_Execution__c reloadedStep = [
        SELECT Status__c
        FROM Workflow_Step_Execution__c
        WHERE Id = :step.Id
      ];
      System.assertEquals(
        'Running',
        reloadedStep.Status__c,
        'Original step execution must not be mutated'
      );

      // Verify a new step execution of name 'Workflow_Deadline' was inserted
      List<Workflow_Step_Execution__c> auditTrail = [
        SELECT Step_Name__c, Status__c, Error_Details__c
        FROM Workflow_Step_Execution__c
        WHERE Workflow_Instance__c = :inst.Id
        ORDER BY CreatedDate DESC, Id DESC
      ];
      System.assertEquals(
        2,
        auditTrail.size(),
        'Should have exactly 2 step execution rows (original + deadline)'
      );
      System.assertEquals('Workflow_Deadline', auditTrail[0].Step_Name__c);
      System.assertEquals('Failed', auditTrail[0].Status__c);
      System.assertEquals(
        'Execution deadline exceeded',
        auditTrail[0].Error_Details__c
      );
    }
  }

  public class TestCompWorkflow implements WorkflowDefinition, ExecutionTimeoutConfigurable {
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowDeadlineTest.TestCompensatableStep' };
    }
    public String getInitialStep() {
      return 'WorkflowDeadlineTest.TestCompensatableStep';
    }
    public String getNextStep(String currentStepName, StepResult stepResult) {
      return null;
    }
    public Integer getExecutionTimeoutSeconds() {
      return 30;
    }
  }

  public class TestCompensatableStep implements CompensatableStep {
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, 'Done');
    }
    public StepResult compensate(StepContext ctx) {
      return StepResult.complete(null, 'Compensated');
    }
  }

  @IsTest
  static void testWatchdogSweepExpiredWithCompensation() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;

      // Create a running instance that has already expired but has a compensation stack
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowDeadlineTest.TestCompWorkflow',
        Status__c = 'Running',
        Correlation_Key__c = 'Deadline-Expired-WithComp',
        Deadline_At__c = DateTime.now().addSeconds(-10),
        Compensation_Stack__c = JSON.serialize(
          new List<String>{ 'WorkflowDeadlineTest.TestCompensatableStep' }
        )
      );
      insert inst;

      // Insert the original successful execution for the step so it can be compensated
      Workflow_Step_Execution__c origExec = new Workflow_Step_Execution__c(
        Workflow_Instance__c = inst.Id,
        Step_Name__c = 'WorkflowDeadlineTest.TestCompensatableStep',
        Status__c = 'Completed',
        Input__c = '{"test": 1}',
        Output__c = '{"test": 2}'
      );
      insert origExec;

      Test.startTest();
      WorkflowEngine.processWatchdogHeartbeat();
      Test.stopTest();

      // Reload the instance
      Workflow_Instance__c reloadedInst = [
        SELECT Status__c, Error_Message__c, Terminal_At__c
        FROM Workflow_Instance__c
        WHERE Id = :inst.Id
      ];

      System.assertEquals(
        'Compensating',
        reloadedInst.Status__c,
        'Status should be Compensating'
      );
      System.assertEquals(
        'Execution deadline exceeded',
        reloadedInst.Error_Message__c
      );
      System.assertEquals(
        null,
        reloadedInst.Terminal_At__c,
        'Terminal_At__c should NOT be set yet as it is Compensating'
      );

      // Verify a new step execution of name 'Workflow_Deadline' was inserted
      List<Workflow_Step_Execution__c> deadlineExecs = [
        SELECT Step_Name__c, Status__c, Error_Details__c
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :inst.Id
          AND Step_Name__c = 'Workflow_Deadline'
      ];
      System.assertEquals(
        1,
        deadlineExecs.size(),
        'Should have inserted a Workflow_Deadline step'
      );
      System.assertEquals('Failed', deadlineExecs[0].Status__c);
      System.assertEquals(
        'Execution deadline exceeded',
        deadlineExecs[0].Error_Details__c
      );

      // Verify the compensation step is pre-created and has status 'Pending'
      List<Workflow_Step_Execution__c> compStepExecs = [
        SELECT Step_Name__c, Status__c, Input__c, Output__c
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :inst.Id
          AND Step_Name__c = 'WorkflowDeadlineTest.TestCompensatableStep_Compensate'
      ];
      System.assertEquals(
        1,
        compStepExecs.size(),
        'Should have pre-created the compensation step'
      );
      System.assertEquals('Pending', compStepExecs[0].Status__c);
      System.assertEquals('{"test": 1}', compStepExecs[0].Input__c);

      // Now execute the orchestrator (or runStep) to complete the compensation
      WorkflowEngine.runStep(inst.Id, null);

      // Reload instance and verify it is now Compensated
      Workflow_Instance__c finalInst = [
        SELECT Status__c, Terminal_At__c
        FROM Workflow_Instance__c
        WHERE Id = :inst.Id
      ];
      System.assertEquals(
        'Compensated',
        finalInst.Status__c,
        'Status should transition to Compensated'
      );
      System.assertNotEquals(
        null,
        finalInst.Terminal_At__c,
        'Terminal_At__c should be set'
      );
    }
  }

  @IsTest
  static void testDashboardControllerQueries() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;

      Datetime deadline = DateTime.now().addHours(2);
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowDeadlineTest.TestDeadlineWorkflow',
        Status__c = 'Suspended',
        Correlation_Key__c = 'Deadline-Dashboard-Test',
        Deadline_At__c = deadline
      );
      insert inst;

      // 1. Test getFilteredInstances
      List<Map<String, Object>> filtered = WorkflowDashboardController.getFilteredInstances(
        iqOf(
          'WorkflowDeadlineTest.TestDeadlineWorkflow',
          'Suspended',
          'Deadline-Dashboard-Test',
          10,
          0,
          'buster'
        )
      );
      System.assert(
        !filtered.isEmpty(),
        'Filtered instances should not be empty'
      );
      System.assertEquals(
        deadline,
        (Datetime) filtered[0].get('Deadline_At__c'),
        'Deadline should be returned in getFilteredInstances'
      );

      // 2. Test getStalledInstances
      List<Map<String, Object>> stalled = WorkflowDashboardController.getStalledInstances(
        stalledOf(
          'WorkflowDeadlineTest.TestDeadlineWorkflow',
          'Deadline-Dashboard-Test',
          -1,
          10,
          0,
          'buster'
        )
      );
      System.assert(
        !stalled.isEmpty(),
        'Stalled instances should not be empty'
      );
      System.assertEquals(
        deadline,
        (Datetime) stalled[0].get('Deadline_At__c'),
        'Deadline should be returned in getStalledInstances'
      );

      // 3. Test getInstanceDetails
      Map<String, Object> details = WorkflowDashboardController.getInstanceDetails(
        inst.Id
      );
      System.assertNotEquals(null, details, 'Details should not be null');
      Workflow_Instance__c reloadedInst = (Workflow_Instance__c) details.get(
        'instance'
      );
      System.assertEquals(
        deadline,
        reloadedInst.Deadline_At__c,
        'Deadline should be returned in getInstanceDetails'
      );
    }
  }

  @IsTest
  static void testWatchdogSweepExpiredWithCompensationBulk() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;

      // Create 3 running instances that have already expired and have a compensation stack
      List<Workflow_Instance__c> insts = new List<Workflow_Instance__c>{
        new Workflow_Instance__c(
          Workflow_Name__c = 'WorkflowDeadlineTest.TestCompWorkflow',
          Status__c = 'Running',
          Correlation_Key__c = 'Deadline-Expired-Bulk1',
          Deadline_At__c = DateTime.now().addSeconds(-10),
          Compensation_Stack__c = JSON.serialize(
            new List<String>{ 'WorkflowDeadlineTest.TestCompensatableStep' }
          )
        ),
        new Workflow_Instance__c(
          Workflow_Name__c = 'WorkflowDeadlineTest.TestCompWorkflow',
          Status__c = 'Running',
          Correlation_Key__c = 'Deadline-Expired-Bulk2',
          Deadline_At__c = DateTime.now().addSeconds(-10),
          Compensation_Stack__c = JSON.serialize(
            new List<String>{ 'WorkflowDeadlineTest.TestCompensatableStep' }
          )
        ),
        new Workflow_Instance__c(
          Workflow_Name__c = 'WorkflowDeadlineTest.TestCompWorkflow',
          Status__c = 'Running',
          Correlation_Key__c = 'Deadline-Expired-Bulk3',
          Deadline_At__c = DateTime.now().addSeconds(-10),
          Compensation_Stack__c = JSON.serialize(
            new List<String>{ 'WorkflowDeadlineTest.TestCompensatableStep' }
          )
        )
      };
      insert insts;

      // Insert original successful executions for the step for all 3 instances
      List<Workflow_Step_Execution__c> origExecs = new List<Workflow_Step_Execution__c>{
        new Workflow_Step_Execution__c(
          Workflow_Instance__c = insts[0].Id,
          Step_Name__c = 'WorkflowDeadlineTest.TestCompensatableStep',
          Status__c = 'Completed',
          Input__c = '{"test": 1}',
          Output__c = '{"test": 10}'
        ),
        new Workflow_Step_Execution__c(
          Workflow_Instance__c = insts[1].Id,
          Step_Name__c = 'WorkflowDeadlineTest.TestCompensatableStep',
          Status__c = 'Completed',
          Input__c = '{"test": 2}',
          Output__c = '{"test": 20}'
        ),
        new Workflow_Step_Execution__c(
          Workflow_Instance__c = insts[2].Id,
          Step_Name__c = 'WorkflowDeadlineTest.TestCompensatableStep',
          Status__c = 'Completed',
          Input__c = '{"test": 3}',
          Output__c = '{"test": 30}'
        )
      };
      insert origExecs;

      Test.startTest();
      WorkflowEngine.processWatchdogHeartbeat();
      Test.stopTest();

      // Verify all 3 are in Compensating status and have pre-created compensation steps
      Set<Id> instIds = new Map<Id, Workflow_Instance__c>(insts).keySet();
      List<Workflow_Instance__c> reloadedInsts = [
        SELECT Id, Status__c, Error_Message__c
        FROM Workflow_Instance__c
        WHERE Id IN :instIds
      ];
      System.assertEquals(3, reloadedInsts.size());
      for (Workflow_Instance__c ri : reloadedInsts) {
        System.assertEquals('Compensating', ri.Status__c);
        System.assertEquals('Execution deadline exceeded', ri.Error_Message__c);
      }

      // Verify Workflow_Deadline records
      List<Workflow_Step_Execution__c> deadlineSteps = [
        SELECT Workflow_Instance__c, Status__c
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c IN :instIds
          AND Step_Name__c = 'Workflow_Deadline'
      ];
      System.assertEquals(3, deadlineSteps.size());

      // Verify compensation steps were pre-created correctly
      List<Workflow_Step_Execution__c> compSteps = [
        SELECT Workflow_Instance__c, Step_Name__c, Status__c, Input__c
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c IN :instIds
          AND Step_Name__c = 'WorkflowDeadlineTest.TestCompensatableStep_Compensate'
      ];
      System.assertEquals(3, compSteps.size());
      Map<Id, Workflow_Step_Execution__c> compByInstId = new Map<Id, Workflow_Step_Execution__c>();
      for (Workflow_Step_Execution__c cs : compSteps) {
        compByInstId.put(cs.Workflow_Instance__c, cs);
      }
      System.assertEquals(
        '{"test": 1}',
        compByInstId.get(insts[0].Id).Input__c
      );
      System.assertEquals(
        '{"test": 2}',
        compByInstId.get(insts[1].Id).Input__c
      );
      System.assertEquals(
        '{"test": 3}',
        compByInstId.get(insts[2].Id).Input__c
      );
    }
  }
}
