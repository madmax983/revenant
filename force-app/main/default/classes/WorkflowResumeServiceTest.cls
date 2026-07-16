/**
 * @description Unit tests for {@link WorkflowResumeService}, driving the single-target
 * manual-resume surface directly. Covers both not-found throws, the three arms of the
 * private applyResumePayloadToActiveStep helper (blank current step, no active step,
 * and the timeout>0 vs null-timeout deadline re-arm) reached through the public resume
 * paths, and the resume(Id, stepName, payload) delegation to resumeInstance.
 *
 * <p>Note: the in-test enqueue always takes the {@code Test.isRunningTest()} branch
 * ({@code System.enqueueJob(new WorkflowOrchestrator(...))}); the production
 * {@code WorkflowOrchestratorEnqueue.enqueueOrchestrator} branch is unreachable under
 * test and is intentionally left uncovered. Assertions read the resume's own writes
 * synchronously before the enqueued orchestrator runs at test-method end.
 */
@IsTest
public class WorkflowResumeServiceTest {
  private static final String RESUME_WF = 'WorkflowResumeServiceTest.ResumeWorkflow';
  private static final String WAIT_STEP = 'WorkflowResumeServiceTest.ResumeWaitStep';
  private static final String TIMEOUT_STEP = 'WorkflowResumeServiceTest.TimeoutResumeStep';

  /**
   * @description Fixture workflow whose steps suspend, so a resumed instance re-drives
   * cleanly when the enqueued orchestrator runs at test-method end.
   */
  public class ResumeWorkflow implements WorkflowDefinition {
    /**
     * @description Declares the two fixture steps.
     * @return The list of step names.
     */
    public List<String> getSteps() {
      return new List<String>{ WAIT_STEP, TIMEOUT_STEP };
    }
    /**
     * @description Names the entry step.
     * @return The initial step name.
     */
    public String getInitialStep() {
      return WAIT_STEP;
    }
    /**
     * @description Terminates after either step.
     * @param currentStepName The step that just completed.
     * @param stepResult The result of the completed step.
     * @return Always null, marking the workflow complete.
     */
    public String getNextStep(String currentStepName, StepResult stepResult) {
      return null;
    }
  }

  /**
   * @description Fixture step with no timeout configuration, exercising the
   * null-timeout arm of the resume payload apply.
   */
  public class ResumeWaitStep implements WorkflowStep {
    /**
     * @description Suspends the instance.
     * @param ctx The durable step context.
     * @return A suspend result.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.suspend();
    }
  }

  /**
   * @description Fixture step declaring a positive timeout, exercising the
   * timeout>0 deadline-arming arm of the resume payload apply.
   */
  public class TimeoutResumeStep implements WorkflowStep, TimeoutConfigurable {
    /**
     * @description Declares this step's execution timeout.
     * @return The timeout in seconds.
     */
    public Integer getTimeoutSeconds() {
      return 300;
    }
    /**
     * @description Suspends the instance.
     * @param ctx The durable step context.
     * @return A suspend result.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.suspend();
    }
  }

  private static Workflow_Instance__c newSuspended(
    String key,
    String currentStep
  ) {
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = RESUME_WF,
      Correlation_Key__c = key,
      Status__c = 'Suspended',
      Current_Step__c = currentStep
    );
    insert inst;
    return inst;
  }

  private static Workflow_Step_Execution__c newStepExec(
    Id instanceId,
    String stepName
  ) {
    Workflow_Step_Execution__c stepExec = new Workflow_Step_Execution__c(
      Workflow_Instance__c = instanceId,
      Step_Name__c = stepName,
      Status__c = 'Suspended',
      Retry_Count__c = 0
    );
    insert stepExec;
    return stepExec;
  }

  @IsTest
  static void testResumeByKeyNotFoundThrows() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Boolean threw = false;
      try {
        WorkflowResumeService.resume('no-such-suspended-key', '{}');
      } catch (WorkflowEngine.WorkflowException ex) {
        threw = true;
        System.assert(
          ex.getMessage()
            .contains('No suspended workflow found with correlation key'),
          'Missing key must throw: ' + ex.getMessage()
        );
      }
      System.assert(threw, 'Resuming an unknown key must throw');
    }
  }

  @IsTest
  static void testResumeInstanceNotFoundThrows() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // A real instance that is NOT Suspended does not match the resume query.
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = RESUME_WF,
        Correlation_Key__c = 'not-suspended-1',
        Status__c = 'Running',
        Current_Step__c = WAIT_STEP
      );
      insert inst;

      Boolean threw = false;
      try {
        WorkflowResumeService.resumeInstance(inst.Id, '{}');
      } catch (WorkflowEngine.WorkflowException ex) {
        threw = true;
        System.assert(
          ex.getMessage().contains('No suspended workflow found with ID'),
          'A non-suspended instance must throw: ' + ex.getMessage()
        );
      }
      System.assert(threw, 'Resuming a non-suspended instance must throw');
    }
  }

  @IsTest
  static void testResumeBlankCurrentStepEarlyReturn() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Blank Current_Step__c: applyResumePayloadToActiveStep returns immediately.
      Workflow_Instance__c inst = newSuspended('resume-blank-step', null);

      WorkflowResumeService.resume('resume-blank-step', '{"v":1}');

      Workflow_Instance__c reloaded = [
        SELECT Status__c, Sleep_Until__c
        FROM Workflow_Instance__c
        WHERE Id = :inst.Id
      ];
      System.assertEquals(
        'Running',
        reloaded.Status__c,
        'Instance flipped to Running'
      );
      System.assertEquals(
        null,
        reloaded.Sleep_Until__c,
        'Any armed timed-wait deadline is disarmed'
      );
    }
  }

  @IsTest
  static void testResumeEmptyActiveStepsEarlyReturn() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Current step is set but there is no matching step-execution row.
      Workflow_Instance__c inst = newSuspended('resume-no-exec', WAIT_STEP);

      WorkflowResumeService.resume('resume-no-exec', '{"v":2}');

      Workflow_Instance__c reloaded = [
        SELECT Status__c
        FROM Workflow_Instance__c
        WHERE Id = :inst.Id
      ];
      System.assertEquals(
        'Running',
        reloaded.Status__c,
        'Instance flipped to Running'
      );
      System.assertEquals(
        0,
        [
          SELECT COUNT()
          FROM Workflow_Step_Execution__c
          WHERE Workflow_Instance__c = :inst.Id
        ],
        'No step execution was created when there was no active step'
      );
    }
  }

  @IsTest
  static void testResumeNullTimeoutArm() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = newSuspended(
        'resume-null-timeout',
        WAIT_STEP
      );
      Workflow_Step_Execution__c stepExec = newStepExec(inst.Id, WAIT_STEP);

      WorkflowResumeService.resumeInstance(inst.Id, '{"resumed":true}');

      Workflow_Step_Execution__c reloaded = [
        SELECT Status__c, Output__c, Timeout_At__c
        FROM Workflow_Step_Execution__c
        WHERE Id = :stepExec.Id
      ];
      System.assertEquals(
        'Running',
        reloaded.Status__c,
        'Active step flipped Running'
      );
      System.assertNotEquals(
        null,
        reloaded.Output__c,
        'The resume payload is stored on the active step'
      );
      System.assertEquals(
        null,
        reloaded.Timeout_At__c,
        'A step with no timeout config has its deadline cleared'
      );
    }
  }

  @IsTest
  static void testResumeTimeoutArm() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = newSuspended('resume-timeout', TIMEOUT_STEP);
      Workflow_Step_Execution__c stepExec = newStepExec(inst.Id, TIMEOUT_STEP);

      WorkflowResumeService.resumeInstance(inst.Id, '{"resumed":true}');

      Workflow_Step_Execution__c reloaded = [
        SELECT Status__c, Timeout_At__c
        FROM Workflow_Step_Execution__c
        WHERE Id = :stepExec.Id
      ];
      System.assertEquals(
        'Running',
        reloaded.Status__c,
        'Active step flipped Running'
      );
      System.assertNotEquals(
        null,
        reloaded.Timeout_At__c,
        'A timeout-configured step re-arms a positive deadline'
      );
    }
  }

  @IsTest
  static void testResumeByIdAndStepNameDelegates() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // resume(Id, stepName, payload) delegates to resumeInstance(Id, payload).
      Workflow_Instance__c inst = newSuspended('resume-delegate', WAIT_STEP);
      newStepExec(inst.Id, WAIT_STEP);

      WorkflowResumeService.resume(inst.Id, WAIT_STEP, '{"v":3}');

      Workflow_Instance__c reloaded = [
        SELECT Status__c
        FROM Workflow_Instance__c
        WHERE Id = :inst.Id
      ];
      System.assertEquals(
        'Running',
        reloaded.Status__c,
        'The stepName overload delegates to resumeInstance and flips Running'
      );
    }
  }
}
