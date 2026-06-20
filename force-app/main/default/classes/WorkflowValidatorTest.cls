/**
 * Tests for WorkflowValidator (issue #23). Proves that a deliberately
 * malformed WorkflowDefinition is reported with every structural defect in a
 * single validate() call, that a well-formed definition passes clean, and that
 * validation writes nothing.
 */
@isTest
private class WorkflowValidatorTest {
  // ==========================================
  // FIXTURE STEPS
  // ==========================================

  public class GoodStepA implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      return StepResult.complete('WorkflowValidatorTest.GoodStepB', null);
    }
  }

  public class GoodStepB implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, null);
    }
  }

  public class CompensatingStep implements CompensatableStep {
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, null);
    }
    public StepResult compensate(StepContext ctx) {
      return StepResult.complete(null, null);
    }
  }

  // Intentionally NOT a WorkflowStep — used to prove STEP_NOT_WORKFLOWSTEP.
  public class NotAStep {
    public String describe() {
      return 'I am not a step';
    }
  }

  // ==========================================
  // FIXTURE WORKFLOWS
  // ==========================================

  // Well-formed: initial declared, all steps resolvable WorkflowSteps,
  // every successor declared.
  public class GoodWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{
        'WorkflowValidatorTest.GoodStepA',
        'WorkflowValidatorTest.GoodStepB',
        'WorkflowValidatorTest.CompensatingStep'
      };
    }
    public String getInitialStep() {
      return 'WorkflowValidatorTest.GoodStepA';
    }
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
  public class BadInitialWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowValidatorTest.GoodStepA' };
    }
    public String getInitialStep() {
      return 'WorkflowValidatorTest.GoodStepB'; // not declared
    }
    public String getNextStep(String currentStepName, StepResult result) {
      return null;
    }
  }

  // Blank initial step.
  public class BlankInitialWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowValidatorTest.GoodStepA' };
    }
    public String getInitialStep() {
      return '';
    }
    public String getNextStep(String currentStepName, StepResult result) {
      return null;
    }
  }

  // getNextStep returns a successor that is not declared in getSteps().
  public class DanglingSuccessorWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowValidatorTest.GoodStepA' };
    }
    public String getInitialStep() {
      return 'WorkflowValidatorTest.GoodStepA';
    }
    public String getNextStep(String currentStepName, StepResult result) {
      // Typo'd successor that was never declared.
      return 'WorkflowValidatorTest.GoodStepTypo';
    }
  }

  // A declared step that resolves but is not a WorkflowStep.
  public class NonStepWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowValidatorTest.NotAStep' };
    }
    public String getInitialStep() {
      return 'WorkflowValidatorTest.NotAStep';
    }
    public String getNextStep(String currentStepName, StepResult result) {
      return null;
    }
  }

  // A declared step name that does not resolve at all.
  public class UnresolvableStepWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowValidatorTest.NoSuchStepClass' };
    }
    public String getInitialStep() {
      return 'WorkflowValidatorTest.NoSuchStepClass';
    }
    public String getNextStep(String currentStepName, StepResult result) {
      return null;
    }
  }

  // Duplicate entry in getSteps().
  public class DuplicateStepsWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{
        'WorkflowValidatorTest.GoodStepA',
        'WorkflowValidatorTest.GoodStepA'
      };
    }
    public String getInitialStep() {
      return 'WorkflowValidatorTest.GoodStepA';
    }
    public String getNextStep(String currentStepName, StepResult result) {
      return null;
    }
  }

  // A single definition exhibiting several defect classes at once, to prove
  // validate() returns 100% of defects in one call.
  public class MultiDefectWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{
        'WorkflowValidatorTest.NotAStep', // STEP_NOT_WORKFLOWSTEP
        'WorkflowValidatorTest.NoSuchStepClass', // STEP_UNRESOLVABLE
        'WorkflowValidatorTest.NotAStep' // DUPLICATE_STEP
      };
    }
    public String getInitialStep() {
      return 'WorkflowValidatorTest.GoodStepB'; // INITIAL_STEP_NOT_DECLARED
    }
    public String getNextStep(String currentStepName, StepResult result) {
      return 'WorkflowValidatorTest.GoodStepTypo'; // DANGLING_SUCCESSOR
    }
  }

  // Not a WorkflowDefinition at all.
  public class NotAWorkflow {
    public String hello() {
      return 'hi';
    }
  }

  // ==========================================
  // TESTS
  // ==========================================

  @isTest
  static void wellFormedDefinitionPassesClean() {
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

  @isTest
  static void unresolvableDefinitionIsFlagged() {
    WorkflowValidator.ValidationResult result = WorkflowValidator.validate(
      'WorkflowValidatorTest.NoSuchWorkflowClass'
    );
    System.assertEquals(false, result.isValid());
    System.assert(
      result.hasDefect(WorkflowValidator.DEFINITION_UNRESOLVABLE),
      'Expected DEFINITION_UNRESOLVABLE: ' + result.getMessages()
    );
  }

  @isTest
  static void nonWorkflowClassIsFlagged() {
    WorkflowValidator.ValidationResult result = WorkflowValidator.validate(
      'WorkflowValidatorTest.NotAWorkflow'
    );
    System.assertEquals(false, result.isValid());
    System.assert(
      result.hasDefect(WorkflowValidator.DEFINITION_UNRESOLVABLE),
      'A class not implementing WorkflowDefinition should be flagged'
    );
  }

  @isTest
  static void blankWorkflowNameIsFlagged() {
    WorkflowValidator.ValidationResult result = WorkflowValidator.validate(null);
    System.assertEquals(false, result.isValid());
    System.assert(
      result.hasDefect(WorkflowValidator.DEFINITION_UNRESOLVABLE)
    );
  }

  @isTest
  static void initialStepNotDeclaredIsFlagged() {
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

  @isTest
  static void blankInitialStepIsFlagged() {
    WorkflowValidator.ValidationResult result = WorkflowValidator.validate(
      'WorkflowValidatorTest.BlankInitialWorkflow'
    );
    System.assertEquals(false, result.isValid());
    System.assert(
      result.hasDefect(WorkflowValidator.INITIAL_STEP_BLANK),
      'Expected INITIAL_STEP_BLANK: ' + result.getMessages()
    );
  }

  @isTest
  static void danglingSuccessorIsFlagged() {
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

  @isTest
  static void nonWorkflowStepClassIsFlagged() {
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

  @isTest
  static void unresolvableStepClassIsFlagged() {
    WorkflowValidator.ValidationResult result = WorkflowValidator.validate(
      'WorkflowValidatorTest.UnresolvableStepWorkflow'
    );
    System.assertEquals(false, result.isValid());
    System.assert(
      result.hasDefect(WorkflowValidator.STEP_UNRESOLVABLE),
      'Expected STEP_UNRESOLVABLE: ' + result.getMessages()
    );
  }

  @isTest
  static void duplicateStepsAreFlagged() {
    WorkflowValidator.ValidationResult result = WorkflowValidator.validate(
      'WorkflowValidatorTest.DuplicateStepsWorkflow'
    );
    System.assertEquals(false, result.isValid());
    System.assert(
      result.hasDefect(WorkflowValidator.DUPLICATE_STEP),
      'Expected DUPLICATE_STEP: ' + result.getMessages()
    );
  }

  @isTest
  static void allDefectsReturnedInOneCall() {
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

  @isTest
  static void validationWritesNothing() {
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
