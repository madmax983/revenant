/**
 * @description Example workflow demonstrating opt-in start-input validation
 * (issue #51). By implementing {@link ValidatedWorkflow} alongside {@link
 * WorkflowDefinition}, this workflow declares an input contract that the engine
 * enforces synchronously at `WorkflowEngine.start(...)` / `startOrGet(...)` and at
 * the Start Workflow invocable — before any `Workflow_Instance__c` is inserted.
 *
 * A start whose payload is missing `accountId`, carries a non-numeric `amount`,
 * or is malformed JSON is rejected up front with a field-level {@link
 * WorkflowInputException} (in Apex) or a branchable `isValid=false` +
 * `validationError` result (in Flow) — instead of failing later as a cryptic
 * async NullPointerException on a `Failed` instance. The single step below can
 * therefore trust that the required fields are present and well-typed.
 */
public inherited sharing class ValidatedOnboardingWorkflowExample implements WorkflowDefinition, ValidatedWorkflow {
  /**
   * @description Declares the start-input contract: `accountId` (String) and
   * `amount` (any JSON number) are required; `vipOnboarding` (Boolean) and
   * `startDate` (ISO date) are type-checked when present. This runs in memory only
   * (no SOQL/DML/callouts) and is the single source of truth for what a valid
   * start payload looks like.
   * @return The onboarding start-input contract.
   */
  public WorkflowInputContract getInputContract() {
    return new WorkflowInputContract()
      .require('accountId', WorkflowInputType.STRING_TYPE)
      .require('amount', WorkflowInputType.DECIMAL_TYPE)
      .optional('vipOnboarding', WorkflowInputType.BOOLEAN_TYPE)
      .optional('startDate', WorkflowInputType.DATE_TYPE);
  }

  /**
   * @description Declares the workflow's single step.
   * @return The list of fully-qualified step class names.
   */
  public List<String> getSteps() {
    return new List<String>{ 'ValidatedOnboardingWorkflowExample.WelcomeStep' };
  }

  /**
   * @description Returns the first step the engine executes.
   * @return The name of the initial step.
   */
  public String getInitialStep() {
    return 'ValidatedOnboardingWorkflowExample.WelcomeStep';
  }

  /**
   * @description Single-step DAG: completes after the welcome step.
   * @param currentStepName The name of the step that just completed.
   * @param stepResult The result of the completed step.
   * @return Always null — the workflow ends after the welcome step.
   */
  public String getNextStep(String currentStepName, StepResult stepResult) {
    return null;
  }

  /**
   * @description Terminal step that trusts the contract-validated start input:
   * because the engine rejected any start missing `accountId` or with a
   * non-numeric `amount`, this step can read them without defensive null checks.
   */
  public inherited sharing class WelcomeStep implements WorkflowStep {
    /**
     * @description Reads the validated onboarding input and completes with a
     * summary. The payload is guaranteed to carry a String `accountId` and a
     * numeric `amount` by the input contract.
     * @param ctx The durable step context exposing the instance input JSON.
     * @return A complete result summarizing the onboarding start.
     */
    public StepResult execute(StepContext ctx) {
      Map<String, Object> input = (Map<String, Object>) JSON.deserializeUntyped(
        ctx.workflowInputJson
      );
      String accountId = (String) input.get('accountId');
      Object amount = input.get('amount');
      Map<String, Object> summary = new Map<String, Object>{
        'accountId' => accountId,
        'amount' => amount,
        'status' => 'Onboarded'
      };
      return StepResult.complete(null, summary);
    }
  }
}
