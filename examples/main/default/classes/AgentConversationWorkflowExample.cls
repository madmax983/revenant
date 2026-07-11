/**
 * Multi-Turn Agentforce Agent Conversation Workflow
 *
 * Shows the defining advantage of durable workflows for agentic AI: a long-running
 * conversation with an Agentforce agent that can SUSPEND between turns and resume
 * in the SAME session — something stateless code cannot do.
 *
 * Flow:
 *   1. InitialTurnStep   — sends the user's opening message; stores sessionId
 *   2. AwaitFollowUpStep — suspends; resumes when a 'FollowUp' signal arrives
 *                          (a human or external system sends additional context)
 *   3. ContinuationTurnStep — rejoins the SAME agent session via the stored
 *                              sessionId; the agent remembers the first turn
 *   4. ConversationCompleteStep — records the final resolution
 *
 * Why this needs a durable workflow:
 *   - The agent sessionId must survive across asynchronous turns (could be minutes
 *     or hours apart in production).
 *   - If the agent API fails mid-turn, the step retries automatically — the
 *     session keeps its place in the conversation.
 *   - The workflow audit trail captures every agent turn verbatim.
 *
 * Agent setup:
 *   Create an Agentforce agent in Agent Studio and pass its Developer Name as
 *   the 'agentDeveloperName' input field. The agent must have a topic that handles
 *   the type of inquiry you're routing to it.
 *
 * Input: { "agentDeveloperName": "Support_Agent", "userMessage": "..." }
 */
public with sharing class AgentConversationWorkflowExample {
  /**
   * Set in @isTest methods — skips the real Invocable.Action call and returns
   * mock responses so the workflow can be driven end-to-end without a real agent.
   * Element 0 = InitialTurnStep response, Element 1 = ContinuationTurnStep response.
   */
  @TestVisible
  private static List<String> mockAgentResponses;

  // ── Workflow definition ────────────────────────────────────────────────────

  /**
   * @description The durable definition of the multi-turn agent conversation,
   * routing linearly from the opening turn through the follow-up suspend, the
   * continuation turn, and the terminal completion step.
   */
  public class AgentConversationWorkflow implements WorkflowDefinition {
    /**
     * @description Declares the ordered step names comprising the conversation.
     * @return The list of InitialTurn, AwaitFollowUp, ContinuationTurn, and ConversationComplete step names.
     */
    public List<String> getSteps() {
      return new List<String>{
        'AgentConversationWorkflowExample.InitialTurnStep',
        'AgentConversationWorkflowExample.AwaitFollowUpStep',
        'AgentConversationWorkflowExample.ContinuationTurnStep',
        'AgentConversationWorkflowExample.ConversationCompleteStep'
      };
    }

    /**
     * @description Names the step the engine runs first for a new instance.
     * @return The InitialTurnStep step name.
     */
    public String getInitialStep() {
      return 'AgentConversationWorkflowExample.InitialTurnStep';
    }

    /**
     * @description Advances linearly through the conversation steps.
     * @param currentStep The name of the step that just completed.
     * @param result The result of the completed step.
     * @return The next step name, or null once ConversationCompleteStep terminates the workflow.
     */
    public String getNextStep(String currentStep, StepResult result) {
      if (currentStep == 'AgentConversationWorkflowExample.InitialTurnStep') {
        return 'AgentConversationWorkflowExample.AwaitFollowUpStep';
      }
      if (currentStep == 'AgentConversationWorkflowExample.AwaitFollowUpStep') {
        return 'AgentConversationWorkflowExample.ContinuationTurnStep';
      }
      if (
        currentStep == 'AgentConversationWorkflowExample.ContinuationTurnStep'
      ) {
        return 'AgentConversationWorkflowExample.ConversationCompleteStep';
      }
      return null; // ConversationCompleteStep is terminal
    }
  }

  // ── Step definitions ───────────────────────────────────────────────────────

  /**
   * Step 1: Send the opening message to the agent.
   *
   * The sessionId returned by the agent is stored in the step output and
   * threaded forward to ContinuationTurnStep. This is the key durable handle —
   * it allows the later step to re-attach to the SAME conversation even if
   * minutes or hours have passed between turns.
   */
  public class InitialTurnStep implements WorkflowStep {
    /**
     * @description Sends the user's opening message to the agent and stores the
     * returned sessionId so a later turn can rejoin the same conversation.
     * @param ctx The durable step context supplying the agentDeveloperName and userMessage input.
     * @return A completed StepResult carrying the agent name, sessionId, and initial response.
     */
    public StepResult execute(StepContext ctx) {
      Map<String, Object> input = parseJson(ctx.inputJson);
      String agentDevName = (String) input.get('agentDeveloperName');
      String userMessage = (String) input.get('userMessage');

      if (String.isBlank(agentDevName)) {
        throw new WorkflowEngine.WorkflowException(
          'agentDeveloperName is required'
        );
      }
      if (String.isBlank(userMessage)) {
        throw new WorkflowEngine.WorkflowException('userMessage is required');
      }

      AgentResponse turn = invokeAgent(agentDevName, userMessage, null, 0);

      return StepResult.complete(
        null,
        new Map<String, Object>{
          'agentDeveloperName' => agentDevName,
          'sessionId' => turn.sessionId,
          'initialResponse' => turn.agentResponse
        }
      );
    }
  }

  /**
   * Step 2: Suspend until a 'FollowUp' signal arrives.
   *
   * The signal payload must contain a 'message' key with the user's follow-up.
   * The sessionId from Step 1 is threaded through to ContinuationTurnStep.
   *
   * Send the signal via CLI:
   *   sf apex run --code "WorkflowEngine.signal('<instanceId>', 'FollowUp',
   *     '{\"message\":\"My account number is 12345\"}');"
   *
   * Or from any Apex that has the instance ID (trigger, flow action, etc.).
   */
  public class AwaitFollowUpStep implements WorkflowStep {
    /**
     * @description Suspends until a 'FollowUp' signal arrives, then consumes it and
     * threads the follow-up message plus stored sessionId to the continuation turn.
     * @param ctx The durable step context supplying the prior output and instance id for the signal query.
     * @return A suspend StepResult while awaiting the signal, else a completed result with the follow-up message.
     */
    public StepResult execute(StepContext ctx) {
      Map<String, Object> prevOutput = parseJson(ctx.inputJson);
      String agentDevName = (String) prevOutput.get('agentDeveloperName');
      String sessionId = (String) prevOutput.get('sessionId');

      List<Workflow_Signal__c> signals = [
        SELECT Id, Payload__c
        FROM Workflow_Signal__c
        WHERE
          Workflow_Instance__c = :ctx.workflowInstanceId
          AND Signal_Name__c = 'FollowUp'
          AND Status__c = 'Received'
        WITH SYSTEM_MODE
        LIMIT 1
      ];

      if (signals.isEmpty()) {
        return StepResult.suspend();
      }

      Workflow_Signal__c sig = signals[0];
      sig.Status__c = 'Consumed';
      update as user sig;

      Map<String, Object> payload = parseJson(sig.Payload__c);
      return StepResult.complete(
        null,
        new Map<String, Object>{
          'agentDeveloperName' => agentDevName,
          'sessionId' => sessionId,
          'followUpMessage' => payload.get('message')
        }
      );
    }
  }

  /**
   * Step 3: Continue the conversation in the SAME agent session.
   *
   * Passing the stored sessionId re-attaches to the conversation history —
   * the agent remembers everything from Step 1 without re-sending it.
   */
  public class ContinuationTurnStep implements WorkflowStep {
    /**
     * @description Continues the conversation in the same agent session by replaying
     * the stored sessionId, so the agent retains the earlier turn's context.
     * @param ctx The durable step context supplying the agent name, sessionId, and follow-up message.
     * @return A completed StepResult carrying the (possibly refreshed) sessionId and final response.
     */
    public StepResult execute(StepContext ctx) {
      Map<String, Object> input = parseJson(ctx.inputJson);
      String agentDevName = (String) input.get('agentDeveloperName');
      String sessionId = (String) input.get('sessionId');
      String followUpMessage = (String) input.get('followUpMessage');

      AgentResponse turn = invokeAgent(
        agentDevName,
        followUpMessage,
        sessionId,
        1
      );

      return StepResult.complete(
        null,
        new Map<String, Object>{
          'sessionId' => turn.sessionId,
          'finalResponse' => turn.agentResponse
        }
      );
    }
  }

  /**
   * Step 4: Record the final resolution.
   */
  public class ConversationCompleteStep implements WorkflowStep {
    /**
     * @description Records the final resolution of the conversation, carrying the
     * last agent response and session forward as the terminal output.
     * @param ctx The durable step context supplying the final response and sessionId.
     * @return A completed StepResult marking the conversation resolved.
     */
    public StepResult execute(StepContext ctx) {
      Map<String, Object> input = parseJson(ctx.inputJson);
      return StepResult.complete(
        null,
        new Map<String, Object>{
          'resolution' => 'completed',
          'finalResponse' => input.get('finalResponse'),
          'sessionId' => input.get('sessionId')
        }
      );
    }
  }

  // ── Agent invocation helper ────────────────────────────────────────────────

  /**
   * Invokes an Agentforce agent via the platform's generateAiAgentResponse
   * invocable action. No HTTP callout or Named Credential needed.
   *
   * @param agentDeveloperName  API name of the Agentforce agent (e.g. Support_Agent)
   * @param userMessage         Message to send this turn
   * @param sessionId           Existing session to continue, or null for a new session
   * @param mockResponseIndex   Which entry in mockAgentResponses to use in tests
   * @return The agent's response wrapper (mocked in tests), including its sessionId.
   */
  private static AgentResponse invokeAgent(
    String agentDeveloperName,
    String userMessage,
    String sessionId,
    Integer mockResponseIndex
  ) {
    if (Test.isRunningTest()) {
      AgentResponse mock = new AgentResponse();
      mock.agentResponse = (mockAgentResponses != null &&
        mockAgentResponses.size() > mockResponseIndex)
        ? mockAgentResponses[mockResponseIndex]
        : 'Mock agent response';
      mock.sessionId = 'mock-session-' + mockResponseIndex;
      mock.success = true;
      return mock;
    }

    Invocable.Action action = Invocable.Action.createCustomAction(
      'generateAiAgentResponse',
      agentDeveloperName
    );
    action.setInvocationParameter('userMessage', userMessage);
    if (String.isNotBlank(sessionId)) {
      action.setInvocationParameter('sessionId', sessionId);
    }

    List<Invocable.Action.Result> results = action.invoke();
    Invocable.Action.Result outcome = results[0];

    AgentResponse resp = new AgentResponse();
    if (outcome.isSuccess()) {
      resp.agentResponse = (String) outcome.getOutputParameters()
        .get('agentResponse');
      resp.sessionId = (String) outcome.getOutputParameters().get('sessionId');
      resp.success = true;
    } else {
      throw new WorkflowEngine.WorkflowException(
        'Agent invocation failed: ' + String.valueOf(outcome.getErrors())
      );
    }
    return resp;
  }

  private class AgentResponse {
    String agentResponse;
    String sessionId;
    Boolean success;
  }

  private static Map<String, Object> parseJson(String jsonStr) {
    if (String.isBlank(jsonStr)) {
      return new Map<String, Object>();
    }
    return (Map<String, Object>) JSON.deserializeUntyped(jsonStr);
  }
}
