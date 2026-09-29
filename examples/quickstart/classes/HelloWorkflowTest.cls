/**
 * @description Tests for HelloWorkflow, the quickstart example.
 */
@IsTest
private class HelloWorkflowTest {
  private static final String GREET = 'HelloWorkflow.GreetStep';
  private static final String SIGN_OFF = 'HelloWorkflow.SignOffStep';

  @IsTest
  static void runsBothStepsToCompleted() {
    System.runAs(QuickstartTestUser.revenantAdmin()) {
      Test.startTest();
      Id instanceId = WorkflowEngine.start(
        HelloWorkflow.NAME,
        'hello-test-1',
        new Map<String, Object>{ 'name' => 'Revenant' }
      );
      WorkflowTestHarness.Result result = new WorkflowTestHarness(instanceId)
        .drive();
      Test.stopTest();

      System.assertEquals('Completed', result.status, 'Must complete');
      System.assertEquals(
        new List<String>{ GREET, SIGN_OFF },
        result.completedSteps,
        'Must run the two steps in order'
      );
      Map<String, Object> output = (Map<String, Object>) JSON.deserializeUntyped(
        result.output
      );
      System.assertEquals(
        'Hello, Revenant!',
        output.get('greeting'),
        'Output must carry the greeting of step 1'
      );
    }
  }

  @IsTest
  static void greetsWorldWhenInputIsEmpty() {
    System.runAs(QuickstartTestUser.revenantAdmin()) {
      Test.startTest();
      Id instanceId = WorkflowEngine.start(
        HelloWorkflow.NAME,
        'hello-test-2',
        null
      );
      WorkflowTestHarness.Result result = new WorkflowTestHarness(instanceId)
        .drive();
      Test.stopTest();

      System.assertEquals('Completed', result.status, 'Must complete');
      System.assert(
        result.output.contains('Hello, World!'),
        'Empty input must greet World'
      );
    }
  }

  @IsTest
  static void greetStepReadsTheName() {
    System.assertEquals(
      '"Hello, Ada!"',
      greet(new Map<String, Object>{ 'name' => 'Ada' }),
      'A map input gives its name'
    );
    System.assertEquals(
      '"Hello, Ada!"',
      greet('Ada'),
      'A string input is the name'
    );
    System.assertEquals(
      '"Hello, World!"',
      greet(new Map<String, Object>{ 'name' => '  ' }),
      'A blank name gives World'
    );
    System.assertEquals(
      '"Hello, World!"',
      greet(new List<Object>{ 'Ada' }),
      'Other input gives World'
    );
  }

  @IsTest
  static void definitionIsTwoLinearSteps() {
    HelloWorkflow definition = new HelloWorkflow();
    System.assertEquals(
      new List<String>{ GREET, SIGN_OFF },
      definition.getSteps(),
      'Must declare two steps'
    );
    System.assertEquals(GREET, definition.getInitialStep(), 'Greet is first');
    System.assertEquals(
      SIGN_OFF,
      definition.getNextStep(GREET, null),
      'Sign-off follows greet'
    );
    System.assertEquals(
      null,
      definition.getNextStep(SIGN_OFF, null),
      'Sign-off is last'
    );
  }

  private static String greet(Object startInput) {
    StepContext ctx = new StepContextTestBuilder()
      .workflowInput(startInput)
      .build();
    return new HelloWorkflow.GreetStep().execute(ctx).directive().outputJson;
  }
}
