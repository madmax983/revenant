/**
 * @description The quickstart workflow. Two steps: greet, then sign off.
 * No callout, no saga, no signal. See docs/quickstart.md.
 */
public inherited sharing class HelloWorkflow implements WorkflowDefinition {
  /** @description The name to give WorkflowEngine.start. */
  public static final String NAME = 'HelloWorkflow';

  private static final String GREET = 'HelloWorkflow.GreetStep';
  private static final String SIGN_OFF = 'HelloWorkflow.SignOffStep';

  /**
   * @description Declares the two steps.
   * @return The step names.
   */
  public List<String> getSteps() {
    return new List<String>{ GREET, SIGN_OFF };
  }

  /**
   * @description The first step.
   * @return The greet step name.
   */
  public String getInitialStep() {
    return GREET;
  }

  /**
   * @description Greet goes to sign-off. Sign-off is the last step.
   * @param currentStepName The step that completed.
   * @param stepResult The result of that step.
   * @return The next step name, or null at the end.
   */
  public String getNextStep(String currentStepName, StepResult stepResult) {
    return currentStepName == GREET ? SIGN_OFF : null;
  }

  /**
   * @description Step 1. Makes the greeting from the start input.
   */
  public class GreetStep implements WorkflowStep {
    /**
     * @description Reads the name. The start input is `{"name": "..."}` or a string.
     * A missing or blank name gives "World".
     * @param ctx The step context.
     * @return Complete, with the greeting as output.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(
        null,
        'Hello, ' + nameFrom(ctx.workflowInputJson) + '!'
      );
    }
  }

  /**
   * @description Step 2. Runs in a new Queueable. Reads the output of step 1.
   */
  public class SignOffStep implements WorkflowStep {
    /**
     * @description Puts the greeting of step 1 in the workflow output.
     * @param ctx The step context.
     * @return Complete, with `{"greeting": "..."}` as output.
     */
    public StepResult execute(StepContext ctx) {
      String greeting = (String) JSON.deserialize(
        ctx.previousStepOutput,
        String.class
      );
      return StepResult.complete(
        null,
        new Map<String, Object>{ 'greeting' => greeting }
      );
    }
  }

  private static String nameFrom(String inputJson) {
    Object input = String.isBlank(inputJson)
      ? null
      : JSON.deserializeUntyped(inputJson);
    Object name = input instanceof Map<String, Object>
      ? ((Map<String, Object>) input).get('name')
      : input;
    String text = name instanceof String ? ((String) name).trim() : null;
    return String.isBlank(text) ? 'World' : text;
  }
}
