/**
 * Tests for WorkflowValidator (issue #23). Proves that a deliberately
 * malformed WorkflowDefinition is reported with every structural defect in a
 * single validate() call, that a well-formed definition passes clean, and that
 * validation writes nothing.
 */
@IsTest
public class WorkflowValidatorTest {
  // ==========================================
  // FIXTURE STEPS
  // ==========================================

  /**
   * @description Well-formed fixture step that completes forward to GoodStepB.
   */
  public class GoodStepA implements WorkflowStep {
    /**
     * @description Completes routing to GoodStepB.
     * @param ctx The durable step context for this execution.
     * @return A completed StepResult naming GoodStepB as the successor.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.complete('WorkflowValidatorTest.GoodStepB', null);
    }
  }

  /**
   * @description Well-formed terminal fixture step that completes with no successor.
   */
  public class GoodStepB implements WorkflowStep {
    /**
     * @description Completes with no successor.
     * @param ctx The durable step context for this execution.
     * @return A completed StepResult with no next step.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, null);
    }
  }

  /**
   * @description Fixture step implementing CompensatableStep, used to prove a compensatable
   * step validates cleanly.
   */
  public class CompensatingStep implements CompensatableStep {
    /**
     * @description Completes with no successor.
     * @param ctx The durable step context for this execution.
     * @return A completed StepResult with no next step.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, null);
    }
    /**
     * @description Compensating action that completes without side effects.
     * @param ctx The durable step context for this compensation.
     * @return A completed StepResult.
     */
    public StepResult compensate(StepContext ctx) {
      return StepResult.complete(null, null);
    }
  }

  /**
   * @description Fixture class that is intentionally NOT a WorkflowStep, used to prove
   * STEP_NOT_WORKFLOWSTEP is reported.
   */
  public class NotAStep {
    /**
     * @description Returns a marker string; exists only so the class has a member.
     * @return A fixed description string.
     */
    public String describe() {
      return 'I am not a step';
    }
  }

  // ==========================================
  // FIXTURE WORKFLOWS
  // ==========================================

  // Well-formed: initial declared, all steps resolvable WorkflowSteps,
  // every successor declared.
  /**
   * @description Well-formed fixture workflow: initial declared, all steps resolvable
   * WorkflowSteps, every successor declared. Used to prove a clean definition passes.
   */
  public class GoodWorkflow implements WorkflowDefinition {
    /**
     * @description Lists the fixture's declared steps.
     * @return The ordered list of fully-qualified step names.
     */
    public List<String> getSteps() {
      return new List<String>{
        'WorkflowValidatorTest.GoodStepA',
        'WorkflowValidatorTest.GoodStepB',
        'WorkflowValidatorTest.CompensatingStep'
      };
    }
    /**
     * @description Names the initial step.
     * @return The fully-qualified initial step name.
     */
    public String getInitialStep() {
      return 'WorkflowValidatorTest.GoodStepA';
    }
    /**
     * @description Routes each declared step to the next, terminating after the last.
     * @param currentStepName The name of the step that just completed.
     * @param result The result of the completed step.
     * @return The next declared step name, or null when complete.
     */
    public String getNextStep(String currentStepName, StepResult result) {
      if (currentStepName == 'WorkflowValidatorTest.GoodStepA') {
        return 'WorkflowValidatorTest.GoodStepB';
      }
      if (currentStepName == 'WorkflowValidatorTest.GoodStepB') {
        return 'WorkflowValidatorTest.CompensatingStep';
      }
      return null;
    }
  }

  // Initial step not contained in getSteps().
  /**
   * @description Fixture whose initial step is not contained in getSteps(), used to prove
   * INITIAL_STEP_NOT_DECLARED is reported.
   */
  public class BadInitialWorkflow implements WorkflowDefinition {
    /**
     * @description Lists the single declared step.
     * @return The ordered list of fully-qualified step names.
     */
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowValidatorTest.GoodStepA' };
    }
    /**
     * @description Names an initial step that is deliberately not declared.
     * @return An undeclared initial step name.
     */
    public String getInitialStep() {
      return 'WorkflowValidatorTest.GoodStepB'; // not declared
    }
    /**
     * @description Terminates immediately.
     * @param currentStepName The name of the step that just completed.
     * @param result The result of the completed step.
     * @return Always null.
     */
    public String getNextStep(String currentStepName, StepResult result) {
      return null;
    }
  }

  // Blank initial step.
  /**
   * @description Fixture whose initial step is blank, used to prove INITIAL_STEP_BLANK is
   * reported.
   */
  public class BlankInitialWorkflow implements WorkflowDefinition {
    /**
     * @description Lists the single declared step.
     * @return The ordered list of fully-qualified step names.
     */
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowValidatorTest.GoodStepA' };
    }
    /**
     * @description Returns a blank initial step to trigger the blank-initial defect.
     * @return An empty string.
     */
    public String getInitialStep() {
      return '';
    }
    /**
     * @description Terminates immediately.
     * @param currentStepName The name of the step that just completed.
     * @param result The result of the completed step.
     * @return Always null.
     */
    public String getNextStep(String currentStepName, StepResult result) {
      return null;
    }
  }

  // getNextStep returns a successor that is not declared in getSteps().
  /**
   * @description Fixture whose getNextStep returns a successor that is not declared in
   * getSteps(), used to prove DANGLING_SUCCESSOR is reported.
   */
  public class DanglingSuccessorWorkflow implements WorkflowDefinition {
    /**
     * @description Lists the single declared step.
     * @return The ordered list of fully-qualified step names.
     */
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowValidatorTest.GoodStepA' };
    }
    /**
     * @description Names the initial step.
     * @return The fully-qualified initial step name.
     */
    public String getInitialStep() {
      return 'WorkflowValidatorTest.GoodStepA';
    }
    /**
     * @description Routes to an undeclared (typo'd) successor to trigger the dangling defect.
     * @param currentStepName The name of the step that just completed.
     * @param result The result of the completed step.
     * @return An undeclared successor step name.
     */
    public String getNextStep(String currentStepName, StepResult result) {
      // Typo'd successor that was never declared.
      return 'WorkflowValidatorTest.GoodStepTypo';
    }
  }

  // A declared step that resolves but is not a WorkflowStep.
  /**
   * @description Fixture declaring a step that resolves but is not a WorkflowStep, used to
   * prove STEP_NOT_WORKFLOWSTEP is reported.
   */
  public class NonStepWorkflow implements WorkflowDefinition {
    /**
     * @description Lists a declared step that is not a WorkflowStep.
     * @return The ordered list of fully-qualified step names.
     */
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowValidatorTest.NotAStep' };
    }
    /**
     * @description Names the initial (non-WorkflowStep) step.
     * @return The fully-qualified initial step name.
     */
    public String getInitialStep() {
      return 'WorkflowValidatorTest.NotAStep';
    }
    /**
     * @description Terminates immediately.
     * @param currentStepName The name of the step that just completed.
     * @param result The result of the completed step.
     * @return Always null.
     */
    public String getNextStep(String currentStepName, StepResult result) {
      return null;
    }
  }

  // A declared step name that does not resolve at all.
  /**
   * @description Fixture declaring a step name that does not resolve to any class, used to
   * prove STEP_UNRESOLVABLE is reported.
   */
  public class UnresolvableStepWorkflow implements WorkflowDefinition {
    /**
     * @description Lists a declared step that cannot be resolved.
     * @return The ordered list of fully-qualified step names.
     */
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowValidatorTest.NoSuchStepClass' };
    }
    /**
     * @description Names the initial (unresolvable) step.
     * @return The fully-qualified initial step name.
     */
    public String getInitialStep() {
      return 'WorkflowValidatorTest.NoSuchStepClass';
    }
    /**
     * @description Terminates immediately.
     * @param currentStepName The name of the step that just completed.
     * @param result The result of the completed step.
     * @return Always null.
     */
    public String getNextStep(String currentStepName, StepResult result) {
      return null;
    }
  }

  // Duplicate entry in getSteps().
  /**
   * @description Fixture declaring the same step twice in getSteps(), used to prove
   * DUPLICATE_STEP is reported.
   */
  public class DuplicateStepsWorkflow implements WorkflowDefinition {
    /**
     * @description Lists a step declared twice.
     * @return The ordered list of fully-qualified step names, with a duplicate.
     */
    public List<String> getSteps() {
      return new List<String>{
        'WorkflowValidatorTest.GoodStepA',
        'WorkflowValidatorTest.GoodStepA'
      };
    }
    /**
     * @description Names the initial step.
     * @return The fully-qualified initial step name.
     */
    public String getInitialStep() {
      return 'WorkflowValidatorTest.GoodStepA';
    }
    /**
     * @description Terminates immediately.
     * @param currentStepName The name of the step that just completed.
     * @param result The result of the completed step.
     * @return Always null.
     */
    public String getNextStep(String currentStepName, StepResult result) {
      return null;
    }
  }

  // A single definition exhibiting several defect classes at once, to prove
  // validate() returns 100% of defects in one call.
  /**
   * @description Fixture exhibiting several defect classes at once, used to prove validate()
   * returns 100% of defects in a single call.
   */
  public class MultiDefectWorkflow implements WorkflowDefinition {
    /**
     * @description Lists steps that trigger the not-a-step, unresolvable, and duplicate defects.
     * @return The ordered list of intentionally defective step names.
     */
    public List<String> getSteps() {
      return new List<String>{
        'WorkflowValidatorTest.NotAStep', // STEP_NOT_WORKFLOWSTEP
        'WorkflowValidatorTest.NoSuchStepClass', // STEP_UNRESOLVABLE
        'WorkflowValidatorTest.NotAStep' // DUPLICATE_STEP
      };
    }
    /**
     * @description Names an undeclared initial step to trigger the initial-not-declared defect.
     * @return An undeclared initial step name.
     */
    public String getInitialStep() {
      return 'WorkflowValidatorTest.GoodStepB'; // INITIAL_STEP_NOT_DECLARED
    }
    /**
     * @description Routes to an undeclared successor to trigger the dangling-successor defect.
     * @param currentStepName The name of the step that just completed.
     * @param result The result of the completed step.
     * @return An undeclared successor step name.
     */
    public String getNextStep(String currentStepName, StepResult result) {
      return 'WorkflowValidatorTest.GoodStepTypo'; // DANGLING_SUCCESSOR
    }
  }

  /**
   * @description Fixture that does not implement WorkflowDefinition at all, used to prove
   * DEFINITION_UNRESOLVABLE is reported.
   */
  public class NotAWorkflow {
    /**
     * @description Returns a marker string; exists only so the class has a member.
     * @return A fixed greeting string.
     */
    public String hello() {
      return 'hi';
    }
  }

  // A definition whose contract methods throw (e.g. reading malformed config).
  /**
   * @description Fixture whose contract methods throw, used to prove CONTRACT_METHOD_THREW is
   * reported for each throwing method rather than aborting validation.
   */
  public class ThrowingContractWorkflow implements WorkflowDefinition {
    /**
     * @description Throws to simulate a malformed definition.
     * @return Never returns; always throws.
     */
    public List<String> getSteps() {
      throw new TestValidatorException('boom from getSteps');
    }
    /**
     * @description Throws to simulate a malformed definition.
     * @return Never returns; always throws.
     */
    public String getInitialStep() {
      throw new TestValidatorException('boom from getInitialStep');
    }
    /**
     * @description Terminates immediately.
     * @param currentStepName The name of the step that just completed.
     * @param result The result of the completed step.
     * @return Always null.
     */
    public String getNextStep(String currentStepName, StepResult result) {
      return null;
    }
  }

  /**
   * @description Test-only exception thrown by the throwing-contract fixtures.
   */
  public class TestValidatorException extends Exception {
  }

  // Well-formed versioned workflow: every successor across versions is declared.
  /**
   * @description Well-formed versioned fixture where every successor across versions is
   * declared, used to prove a clean VersionedWorkflow passes.
   */
  public class GoodVersionedWorkflow implements VersionedWorkflow {
    /**
     * @description Lists the declared steps.
     * @return The ordered list of fully-qualified step names.
     */
    public List<String> getSteps() {
      return new List<String>{
        'WorkflowValidatorTest.GoodStepA',
        'WorkflowValidatorTest.GoodStepB'
      };
    }
    /**
     * @description Names the initial step.
     * @return The fully-qualified initial step name.
     */
    public String getInitialStep() {
      return 'WorkflowValidatorTest.GoodStepA';
    }
    /**
     * @description Reports the latest defined version.
     * @return The latest version number.
     */
    public Integer getLatestVersion() {
      return 2;
    }
    /**
     * @description Version-unaware routing that delegates to version 1.
     * @param currentStepName The name of the step that just completed.
     * @param result The result of the completed step.
     * @return The next declared step name, or null when complete.
     */
    public String getNextStep(String currentStepName, StepResult result) {
      return getNextStep(currentStepName, result, 1);
    }
    /**
     * @description Version-aware routing to the next declared step.
     * @param currentStepName The name of the step that just completed.
     * @param result The result of the completed step.
     * @param version The workflow version to evaluate.
     * @return The next declared step name, or null when complete.
     */
    public String getNextStep(
      String currentStepName,
      StepResult result,
      Integer version
    ) {
      if (currentStepName == 'WorkflowValidatorTest.GoodStepA') {
        return 'WorkflowValidatorTest.GoodStepB';
      }
      return null;
    }
  }

  // Versioned workflow whose v2 routing reaches a successor NOT in getSteps().
  // The two-argument fallback (v1) routes only to declared steps, so this dangle
  // is detectable only by probing the version-aware overload.
  /**
   * @description Versioned fixture whose v2 routing reaches an undeclared successor,
   * detectable only by probing the version-aware overload, used to prove the versioned
   * dangling-successor probe.
   */
  public class VersionedDanglingWorkflow implements VersionedWorkflow {
    /**
     * @description Lists the single declared step.
     * @return The ordered list of fully-qualified step names.
     */
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowValidatorTest.GoodStepA' };
    }
    /**
     * @description Names the initial step.
     * @return The fully-qualified initial step name.
     */
    public String getInitialStep() {
      return 'WorkflowValidatorTest.GoodStepA';
    }
    /**
     * @description Reports the latest defined version.
     * @return The latest version number.
     */
    public Integer getLatestVersion() {
      return 2;
    }
    /**
     * @description Version-unaware fallback that terminates cleanly.
     * @param currentStepName The name of the step that just completed.
     * @param result The result of the completed step.
     * @return Always null on the 2-arg path.
     */
    public String getNextStep(String currentStepName, StepResult result) {
      // v1 fallback: terminate (no dangling successor on the 2-arg path).
      return null;
    }
    /**
     * @description Version-aware routing that returns an undeclared successor on v2+.
     * @param currentStepName The name of the step that just completed.
     * @param result The result of the completed step.
     * @param version The workflow version to evaluate.
     * @return An undeclared successor on v2+, otherwise null.
     */
    public String getNextStep(
      String currentStepName,
      StepResult result,
      Integer version
    ) {
      if (
        version >= 2 &&
        currentStepName == 'WorkflowValidatorTest.GoodStepA'
      ) {
        return 'WorkflowValidatorTest.V2OnlyStepTypo'; // undeclared
      }
      return null;
    }
  }

  // Versioned workflow whose getLatestVersion() throws (malformed config). The
  // engine calls getLatestVersion() before starting, so this must be flagged.
  /**
   * @description Versioned fixture whose getLatestVersion() throws, used to prove
   * CONTRACT_METHOD_THREW is reported for the version accessor the engine calls before start.
   */
  public class ThrowingVersionWorkflow implements VersionedWorkflow {
    /**
     * @description Lists the single declared step.
     * @return The ordered list of fully-qualified step names.
     */
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowValidatorTest.GoodStepA' };
    }
    /**
     * @description Names the initial step.
     * @return The fully-qualified initial step name.
     */
    public String getInitialStep() {
      return 'WorkflowValidatorTest.GoodStepA';
    }
    /**
     * @description Throws to simulate malformed version configuration.
     * @return Never returns; always throws.
     */
    public Integer getLatestVersion() {
      throw new TestValidatorException('bad version config');
    }
    /**
     * @description Version-unaware routing that terminates immediately.
     * @param currentStepName The name of the step that just completed.
     * @param result The result of the completed step.
     * @return Always null.
     */
    public String getNextStep(String currentStepName, StepResult result) {
      return null;
    }
    /**
     * @description Version-aware routing that terminates immediately.
     * @param currentStepName The name of the step that just completed.
     * @param result The result of the completed step.
     * @param version The workflow version to evaluate.
     * @return Always null.
     */
    public String getNextStep(
      String currentStepName,
      StepResult result,
      Integer version
    ) {
      return null;
    }
  }

  // ==========================================
  // TESTS
  // ==========================================

  @IsTest
  static void wellFormedDefinitionPassesClean() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      WorkflowValidator.ValidationResult result = WorkflowValidator.validate(
        'WorkflowValidatorTest.GoodWorkflow'
      );
      Test.stopTest();

      System.assertEquals(
        true,
        result.isValid(),
        'Well-formed workflow should pass: ' + result.getMessages()
      );
      System.assertEquals(0, result.defects.size(), 'Expected zero defects');
    }
  }

  @IsTest
  static void unresolvableDefinitionIsFlagged() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowValidator.ValidationResult result = WorkflowValidator.validate(
        'WorkflowValidatorTest.NoSuchWorkflowClass'
      );
      System.assertEquals(false, result.isValid());
      System.assert(
        result.hasDefect(WorkflowValidator.DEFINITION_UNRESOLVABLE),
        'Expected DEFINITION_UNRESOLVABLE: ' + result.getMessages()
      );
    }
  }

  @IsTest
  static void nonWorkflowClassIsFlagged() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowValidator.ValidationResult result = WorkflowValidator.validate(
        'WorkflowValidatorTest.NotAWorkflow'
      );
      System.assertEquals(false, result.isValid());
      System.assert(
        result.hasDefect(WorkflowValidator.DEFINITION_UNRESOLVABLE),
        'A class not implementing WorkflowDefinition should be flagged'
      );
    }
  }

  @IsTest
  static void blankWorkflowNameIsFlagged() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowValidator.ValidationResult result = WorkflowValidator.validate(
        null
      );
      System.assertEquals(false, result.isValid());
      System.assert(
        result.hasDefect(WorkflowValidator.DEFINITION_UNRESOLVABLE)
      );
    }
  }

  @IsTest
  static void initialStepNotDeclaredIsFlagged() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowValidator.ValidationResult result = WorkflowValidator.validate(
        'WorkflowValidatorTest.BadInitialWorkflow'
      );
      System.assertEquals(false, result.isValid());
      System.assert(
        result.hasDefect(WorkflowValidator.INITIAL_STEP_NOT_DECLARED),
        'Expected INITIAL_STEP_NOT_DECLARED: ' + result.getMessages()
      );
      assertMessageNames(result, 'WorkflowValidatorTest.GoodStepB');
    }
  }

  @IsTest
  static void blankInitialStepIsFlagged() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowValidator.ValidationResult result = WorkflowValidator.validate(
        'WorkflowValidatorTest.BlankInitialWorkflow'
      );
      System.assertEquals(false, result.isValid());
      System.assert(
        result.hasDefect(WorkflowValidator.INITIAL_STEP_BLANK),
        'Expected INITIAL_STEP_BLANK: ' + result.getMessages()
      );
    }
  }

  @IsTest
  static void danglingSuccessorIsFlagged() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowValidator.ValidationResult result = WorkflowValidator.validate(
        'WorkflowValidatorTest.DanglingSuccessorWorkflow'
      );
      System.assertEquals(false, result.isValid());
      System.assert(
        result.hasDefect(WorkflowValidator.DANGLING_SUCCESSOR),
        'Expected DANGLING_SUCCESSOR: ' + result.getMessages()
      );
      assertMessageNames(result, 'WorkflowValidatorTest.GoodStepTypo');
    }
  }

  @IsTest
  static void nonWorkflowStepClassIsFlagged() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowValidator.ValidationResult result = WorkflowValidator.validate(
        'WorkflowValidatorTest.NonStepWorkflow'
      );
      System.assertEquals(false, result.isValid());
      System.assert(
        result.hasDefect(WorkflowValidator.STEP_NOT_WORKFLOWSTEP),
        'Expected STEP_NOT_WORKFLOWSTEP: ' + result.getMessages()
      );
      assertMessageNames(result, 'WorkflowValidatorTest.NotAStep');
    }
  }

  @IsTest
  static void unresolvableStepClassIsFlagged() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowValidator.ValidationResult result = WorkflowValidator.validate(
        'WorkflowValidatorTest.UnresolvableStepWorkflow'
      );
      System.assertEquals(false, result.isValid());
      System.assert(
        result.hasDefect(WorkflowValidator.STEP_UNRESOLVABLE),
        'Expected STEP_UNRESOLVABLE: ' + result.getMessages()
      );
    }
  }

  @IsTest
  static void duplicateStepsAreFlagged() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowValidator.ValidationResult result = WorkflowValidator.validate(
        'WorkflowValidatorTest.DuplicateStepsWorkflow'
      );
      System.assertEquals(false, result.isValid());
      System.assert(
        result.hasDefect(WorkflowValidator.DUPLICATE_STEP),
        'Expected DUPLICATE_STEP: ' + result.getMessages()
      );
    }
  }

  @IsTest
  static void allDefectsReturnedInOneCall() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowValidator.ValidationResult result = WorkflowValidator.validate(
        'WorkflowValidatorTest.MultiDefectWorkflow'
      );
      System.assertEquals(false, result.isValid());
      // 100% of the structural defect classes wired into this fixture.
      System.assert(
        result.hasDefect(WorkflowValidator.INITIAL_STEP_NOT_DECLARED),
        'missing INITIAL_STEP_NOT_DECLARED: ' + result.getMessages()
      );
      System.assert(
        result.hasDefect(WorkflowValidator.STEP_NOT_WORKFLOWSTEP),
        'missing STEP_NOT_WORKFLOWSTEP: ' + result.getMessages()
      );
      System.assert(
        result.hasDefect(WorkflowValidator.STEP_UNRESOLVABLE),
        'missing STEP_UNRESOLVABLE: ' + result.getMessages()
      );
      System.assert(
        result.hasDefect(WorkflowValidator.DUPLICATE_STEP),
        'missing DUPLICATE_STEP: ' + result.getMessages()
      );
      System.assert(
        result.hasDefect(WorkflowValidator.DANGLING_SUCCESSOR),
        'missing DANGLING_SUCCESSOR: ' + result.getMessages()
      );
    }
  }

  @IsTest
  static void validationWritesNothing() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Measure DML in the same governor context (no Test.startTest, which would
      // reset limits and mask any DML the validator performed).
      Integer dmlBefore = Limits.getDmlStatements();

      WorkflowValidator.validate('WorkflowValidatorTest.MultiDefectWorkflow');
      WorkflowValidator.validate('WorkflowValidatorTest.GoodWorkflow');

      System.assertEquals(
        dmlBefore,
        Limits.getDmlStatements(),
        'Validation must perform no DML'
      );
      System.assertEquals(
        0,
        [SELECT COUNT() FROM Workflow_Instance__c],
        'Validation must create no Workflow_Instance__c'
      );
      System.assertEquals(
        0,
        [SELECT COUNT() FROM Workflow_Step_Execution__c],
        'Validation must create no Workflow_Step_Execution__c'
      );
    }
  }

  @IsTest
  static void contractMethodThrowIsReportedNotPropagated() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // getInitialStep()/getSteps() throwing must surface as defects, not abort.
      WorkflowValidator.ValidationResult result = WorkflowValidator.validate(
        'WorkflowValidatorTest.ThrowingContractWorkflow'
      );
      System.assertEquals(
        false,
        result.isValid(),
        'A throwing definition must be reported as invalid'
      );
      System.assert(
        result.hasDefect(WorkflowValidator.CONTRACT_METHOD_THREW),
        'Expected CONTRACT_METHOD_THREW: ' + result.getMessages()
      );
      // Both contract methods threw; both should be surfaced.
      Integer threwCount = 0;
      for (WorkflowValidator.Defect d : result.defects) {
        if (d.code == WorkflowValidator.CONTRACT_METHOD_THREW) {
          threwCount++;
        }
      }
      System.assertEquals(
        2,
        threwCount,
        'Both getInitialStep() and getSteps() throws should be reported: ' +
        result.getMessages()
      );
    }
  }

  @IsTest
  static void wellFormedVersionedWorkflowPassesClean() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowValidator.ValidationResult result = WorkflowValidator.validate(
        'WorkflowValidatorTest.GoodVersionedWorkflow'
      );
      System.assertEquals(
        true,
        result.isValid(),
        'Well-formed versioned workflow should pass: ' + result.getMessages()
      );
    }
  }

  @IsTest
  static void versionedDanglingSuccessorIsFlagged() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // The dangling successor is reachable only via the version-aware
      // getNextStep(..., version) overload, so this proves the versioned probe.
      WorkflowValidator.ValidationResult result = WorkflowValidator.validate(
        'WorkflowValidatorTest.VersionedDanglingWorkflow'
      );
      System.assertEquals(false, result.isValid());
      System.assert(
        result.hasDefect(WorkflowValidator.DANGLING_SUCCESSOR),
        'Expected DANGLING_SUCCESSOR from versioned probe: ' +
        result.getMessages()
      );
      assertMessageNames(result, 'WorkflowValidatorTest.V2OnlyStepTypo');
    }
  }

  @IsTest
  static void versionedGetLatestVersionThrowIsFlagged() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowValidator.ValidationResult result = WorkflowValidator.validate(
        'WorkflowValidatorTest.ThrowingVersionWorkflow'
      );
      System.assertEquals(
        false,
        result.isValid(),
        'A versioned workflow whose getLatestVersion() throws must be flagged'
      );
      System.assert(
        result.hasDefect(WorkflowValidator.CONTRACT_METHOD_THREW),
        'Expected CONTRACT_METHOD_THREW from getLatestVersion(): ' +
        result.getMessages()
      );
    }
  }

  // Asserts that at least one defect message embeds the given step name.
  private static void assertMessageNames(
    WorkflowValidator.ValidationResult result,
    String expectedName
  ) {
    Boolean found = false;
    for (String msg : result.getMessages()) {
      if (msg.contains(expectedName)) {
        found = true;
        break;
      }
    }
    System.assert(
      found,
      'Expected a defect message naming "' +
        expectedName +
        '" but got: ' +
        result.getMessages()
    );
  }
}
