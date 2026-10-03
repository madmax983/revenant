/**
 * @description Tests for `Wait_Type__c` on the step row (issue #229). The suspension
 * handlers write it. The sleep handler and the step claim clear it.
 */
@IsTest
public class WorkflowWaitTypeTest {
  private static final String GATE_WF = 'WorkflowWaitTypeTest.GateWorkflow';
  private static final String GATE_STEP = 'WorkflowWaitTypeTest.GateStep';
  private static final String CHILD_WF = 'WorkflowEngineMocksATest.ChildWorkflow';

  /** @description One-step definition for the claim test. */
  public class GateWorkflow implements WorkflowDefinition {
    /**
     * @description Returns the step list.
     * @return The step names.
     */
    public List<String> getSteps() {
      return new List<String>{ GATE_STEP };
    }
    /**
     * @description Returns the first step.
     * @return The initial step name.
     */
    public String getInitialStep() {
      return GATE_STEP;
    }
    /**
     * @description Ends after the gate step.
     * @param current The completed step.
     * @param result The step result.
     * @return Always null.
     */
    public String getNextStep(String current, StepResult result) {
      return null;
    }
  }

  /** @description Suspends until the Go signal is present. */
  public class GateStep implements WorkflowStep {
    /**
     * @description Completes when Go is present, else suspends.
     * @param ctx The step context.
     * @return A COMPLETE or SUSPEND result.
     */
    public StepResult execute(StepContext ctx) {
      if (!ctx.signals().getSignal('Go').isPresent()) {
        return StepResult.suspend();
      }
      return StepResult.complete(null, 'Done');
    }
  }

  private static Workflow_Instance__c newInstance() {
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = GATE_WF,
      Status__c = 'Running',
      Current_Step__c = GATE_STEP,
      Correlation_Key__c = 'WaitType-' + Crypto.getRandomInteger()
    );
    insert inst;
    return inst;
  }

  private static Workflow_Step_Execution__c newStepExec(Id instanceId) {
    Workflow_Step_Execution__c exec = new Workflow_Step_Execution__c(
      Workflow_Instance__c = instanceId,
      Step_Name__c = GATE_STEP,
      Status__c = 'Running',
      Retry_Count__c = 0
    );
    insert exec;
    return exec;
  }

  private static WorkflowEngine.StepOutcomeContext outcomeFor(
    Workflow_Instance__c inst,
    Workflow_Step_Execution__c exec,
    StepResult result
  ) {
    WorkflowEngine.StepOutcomeContext outcome = new WorkflowEngine.StepOutcomeContext();
    outcome.instance = [
      SELECT Id, Status__c, Correlation_Key__c, Current_Step__c, Held_At__c
      FROM Workflow_Instance__c
      WHERE Id = :inst.Id
    ];
    outcome.stepExec = exec;
    outcome.result = result;
    outcome.isParallel = false;
    return outcome;
  }

  private static String storedType(Id stepExecId) {
    return [
      SELECT Wait_Type__c
      FROM Workflow_Step_Execution__c
      WHERE Id = :stepExecId
    ]
    .Wait_Type__c;
  }

  @IsTest
  static void testSuspendWritesGenericSignal() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c inst = newInstance();
      Workflow_Step_Execution__c exec = newStepExec(inst.Id);
      Test.startTest();
      WorkflowStepSuspension.handleSuspendOutcome(
        outcomeFor(inst, exec, StepResult.suspend())
      );
      Test.stopTest();
      System.assertEquals(
        WorkflowWaitDescriptorService.TYPE_GENERIC,
        storedType(exec.Id),
        'A plain suspend is a generic signal wait'
      );
    }
  }

  @IsTest
  static void testTimedSuspendWritesGenericSignal() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c inst = newInstance();
      Workflow_Step_Execution__c exec = newStepExec(inst.Id);
      Test.startTest();
      WorkflowStepSuspension.handleSuspendOutcome(
        outcomeFor(inst, exec, StepResult.suspend(60, GATE_STEP))
      );
      Test.stopTest();
      System.assertEquals(
        WorkflowWaitDescriptorService.TYPE_GENERIC,
        storedType(exec.Id),
        'A timed suspend is a generic signal wait'
      );
    }
  }

  @IsTest
  static void testApprovalWritesApproval() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c inst = newInstance();
      Workflow_Step_Execution__c exec = newStepExec(inst.Id);
      Test.startTest();
      WorkflowStepSuspension.handleWaitForApprovalOutcome(
        outcomeFor(inst, exec, StepResult.waitForApproval('Gate', 'Manager'))
      );
      Test.stopTest();
      System.assertEquals(
        WorkflowWaitDescriptorService.TYPE_APPROVAL,
        storedType(exec.Id),
        'An approval gate is an approval wait'
      );
    }
  }

  @IsTest
  static void testStartChildWritesChildCompletion() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c inst = newInstance();
      Workflow_Step_Execution__c exec = newStepExec(inst.Id);
      Test.startTest();
      WorkflowStepSuspension.handleStartChildOutcome(
        outcomeFor(
          inst,
          exec,
          StepResult.startChild(CHILD_WF, 'WaitType-Child', 'in')
        )
      );
      Test.stopTest();
      System.assertEquals(
        WorkflowWaitDescriptorService.TYPE_CHILD,
        storedType(exec.Id),
        'A single child is a child-completion wait'
      );
    }
  }

  @IsTest
  static void testStartChildrenWritesChildCompletion() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c inst = newInstance();
      Workflow_Step_Execution__c exec = newStepExec(inst.Id);
      StepResult.ChildRequest req = new StepResult.ChildRequest(
        CHILD_WF,
        'WaitType-Bulk',
        'in'
      );
      Test.startTest();
      WorkflowStepSuspension.handleStartChildrenOutcome(
        outcomeFor(
          inst,
          exec,
          StepResult.startChildren(new List<StepResult.ChildRequest>{ req })
        )
      );
      Test.stopTest();
      System.assertEquals(
        WorkflowWaitDescriptorService.TYPE_CHILD,
        storedType(exec.Id),
        'A child bulk is a child-completion wait'
      );
    }
  }

  @IsTest
  static void testSleepClearsStaleType() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c inst = newInstance();
      Workflow_Step_Execution__c exec = newStepExec(inst.Id);
      update new Workflow_Step_Execution__c(
        Id = exec.Id,
        Wait_Type__c = WorkflowWaitDescriptorService.TYPE_APPROVAL
      );
      Test.startTest();
      WorkflowStepSuspension.handleSleepOutcome(
        outcomeFor(inst, exec, StepResult.sleep(60))
      );
      Test.stopTest();
      System.assertEquals(
        null,
        storedType(exec.Id),
        'A sleep is not a signal wait, so the type is blank'
      );
    }
  }

  @IsTest
  static void testResumeClearsType() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      String correlationKey = 'WaitType-Resume-' + Crypto.getRandomInteger();
      Test.startTest();
      Id instId = WorkflowEngine.start(GATE_WF, correlationKey, null);
      WorkflowEngine.runStep(instId); // GateStep suspends.
      Id execId = [
        SELECT Id
        FROM Workflow_Step_Execution__c
        WHERE Workflow_Instance__c = :instId
      ]
      .Id;
      String parkedType = storedType(execId);
      WorkflowEngine.signal(correlationKey, 'Go', '"p"');
      WorkflowEngine.runStep(instId); // GateStep completes.
      Test.stopTest();
      System.assertEquals(
        WorkflowWaitDescriptorService.TYPE_GENERIC,
        parkedType,
        'The parked row carries the type'
      );
      System.assertEquals(
        null,
        storedType(execId),
        'The step claim clears the type'
      );
    }
  }
}
