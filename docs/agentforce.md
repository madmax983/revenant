# Agentforce & AI Workflows in Revenant

## Two invocation patterns

| Pattern | API | Best for |
|---|---|---|
| **Raw LLM** | `aiplatform.ModelsAPI` | Classification, summarization, extraction — single-turn, no agent setup required |
| **Agentforce Agent** | `Invocable.Action.createCustomAction('generateAiAgentResponse', agentName)` | Full agent with configured topics, actions, memory — multi-turn, requires Agent Studio |

Both work natively inside a step's `execute()` — no HTTP callout, no Named Credential. `WorkflowOrchestrator implements Database.AllowsCallouts` already provides the callout context.

---

## Pattern 1 — LLM classification with `aiplatform.ModelsAPI`

Use this when you need a quick AI decision mid-workflow and don't need a full Agentforce agent.

```java
private static String classifyWithLlm(String inquiryText) {
    String prompt =
        'Classify the inquiry into exactly one of: billing, technical, escalate.\n' +
        'Respond with ONLY that single word.\n\nInquiry: ' + inquiryText;

    aiplatform.ModelsAPI.createGenerations_Request req =
        new aiplatform.ModelsAPI.createGenerations_Request();
    req.modelName = 'sfdc_ai__DefaultGPT35Turbo';

    aiplatform.ModelsAPI_GenerationRequest body = new aiplatform.ModelsAPI_GenerationRequest();
    body.prompt = prompt;
    req.body = body;

    aiplatform.ModelsAPI.createGenerations_Response res =
        new aiplatform.ModelsAPI().createGenerations(req);

    return res.Code200.generation.generatedText.trim().toLowerCase();
}
```

The step just calls this and returns `StepResult.complete()` with the classification. If the LLM API throws, the engine retries the step automatically with the default `RetryPolicy` — no extra error-handling code needed.

**Multi-turn chat** uses `createChatGenerations()` instead, which accepts a `List<aiplatform.ModelsAPI_ChatMessage>`. For stateful multi-turn conversations, prefer the Agentforce agent pattern below.

### Route on the LLM result

`getNextStep()` reads the completed step's output JSON to branch:

```java
public String getNextStep(String currentStep, StepResult result) {
    if (currentStep == 'TriageWorkflow.AiClassifyStep') {
        String cls = (String)
            ((Map<String,Object>) JSON.deserializeUntyped(result.directive().outputJson)).get('classification');
        if (cls == 'billing')   return 'TriageWorkflow.AutoResolveBillingStep';
        if (cls == 'technical') return 'TriageWorkflow.CreateCaseStep';
        return 'TriageWorkflow.EscalateStep';
    }
    // ...
}
```

Full example: `examples/main/default/classes/AiSupportTriageWorkflowExample.cls`

---

## Pattern 2 — Multi-turn Agentforce agent conversation

This is the core use case for durable AI workflows. The `sessionId` returned by the agent on the first turn is stored in the step output and threaded forward to subsequent steps. Stateless code cannot do this — if the process dies between turns, the session is lost. With durable workflows it survives indefinitely.

### Turn 1 — open the session

```java
public class InitialTurnStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
        Map<String,Object> input = parseJson(ctx.inputJson);
        AgentResponse turn = invokeAgent(
            (String) input.get('agentDeveloperName'),
            (String) input.get('userMessage'),
            null  // new session
        );
        return StepResult.complete(null, new Map<String,Object>{
            'agentDeveloperName' => input.get('agentDeveloperName'),
            'sessionId'          => turn.sessionId,   // <-- the durable handle
            'initialResponse'    => turn.agentResponse
        });
    }
}
```

### Suspend — wait for follow-up input

```java
public class AwaitFollowUpStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
        Map<String,Object> prev = parseJson(ctx.inputJson);

        List<Workflow_Signal__c> signals = [
            SELECT Id, Payload__c FROM Workflow_Signal__c
            WHERE Workflow_Instance__c = :ctx.workflowInstanceId
              AND Signal_Name__c = 'FollowUp'
              AND Status__c = 'Received'
            WITH SYSTEM_MODE LIMIT 1
        ];
        if (signals.isEmpty()) {
            return StepResult.suspend();   // park; engine does nothing until a signal arrives
        }

        signals[0].Status__c = 'Consumed';
        update signals[0];

        Map<String,Object> payload = parseJson(signals[0].Payload__c);
        return StepResult.complete(null, new Map<String,Object>{
            'agentDeveloperName' => prev.get('agentDeveloperName'),
            'sessionId'          => prev.get('sessionId'),  // thread forward
            'followUpMessage'    => payload.get('message')
        });
    }
}
```

### Turn 2 — re-attach to the same session

```java
public class ContinuationTurnStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
        Map<String,Object> input = parseJson(ctx.inputJson);
        AgentResponse turn = invokeAgent(
            (String) input.get('agentDeveloperName'),
            (String) input.get('followUpMessage'),
            (String) input.get('sessionId')  // agent remembers the first turn
        );
        return StepResult.complete(null, new Map<String,Object>{
            'sessionId'     => turn.sessionId,
            'finalResponse' => turn.agentResponse
        });
    }
}
```

### Core `invokeAgent` helper

```java
private static AgentResponse invokeAgent(
    String agentDeveloperName, String userMessage, String sessionId
) {
    Invocable.Action action = Invocable.Action.createCustomAction(
        'generateAiAgentResponse',
        agentDeveloperName
    );
    action.setInvocationParameter('userMessage', userMessage);
    if (String.isNotBlank(sessionId)) {
        action.setInvocationParameter('sessionId', sessionId);
    }

    Invocable.Action.Result outcome = action.invoke()[0];
    if (!outcome.isSuccess()) {
        throw new WorkflowEngine.WorkflowException(
            'Agent invocation failed: ' + outcome.getErrors()
        );
    }

    AgentResponse resp = new AgentResponse();
    resp.agentResponse = (String) outcome.getOutputParameters().get('agentResponse');
    resp.sessionId     = (String) outcome.getOutputParameters().get('sessionId');
    resp.success       = true;
    return resp;
}
```

### Sending the follow-up signal

From anywhere that has the instance ID — Apex, a Flow action, a trigger, or the CLI:

```bash
sf apex run --code "WorkflowEngine.signal(
    '<instanceId>',
    'FollowUp',
    '{\"message\":\"My account number is ACC-12345\"}'
);"
```

Or from Apex:

```java
WorkflowEngine.signal(instanceId, 'FollowUp', '{"message":"My account number is ACC-12345"}');
```

Full example: `examples/main/default/classes/AgentConversationWorkflowExample.cls`

---

## Pattern 3 — Human-in-the-loop escalation gate

For cases where the AI's output needs a human sign-off before the workflow continues. `waitForApproval()` suspends the workflow and renders approve/reject buttons in the dashboard.

```java
public class EscalateStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
        List<Workflow_Signal__c> signals = [
            SELECT Id, Payload__c FROM Workflow_Signal__c
            WHERE Workflow_Instance__c = :ctx.workflowInstanceId
              AND Signal_Name__c = 'Approve:EscalationReview'
              AND Status__c = 'Received'
            WITH SYSTEM_MODE LIMIT 1
        ];
        if (signals.isEmpty()) {
            return StepResult.waitForApproval('EscalationReview', null);
        }

        signals[0].Status__c = 'Consumed';
        update signals[0];

        Map<String,Object> decision = (Map<String,Object>)
            JSON.deserializeUntyped(signals[0].Payload__c);
        return StepResult.complete(null, new Map<String,Object>{
            'resolution' => 'human-reviewed',
            'approved'   => decision.get('approved'),
            'reviewedBy' => decision.get('approver')
        });
    }
}
```

The pattern is identical whether the preceding step was an LLM call or a human task — the workflow just suspends and the engine waits.

---

## Pattern 4 — ReAct tool-calling loop

[ReAct](https://arxiv.org/abs/2210.03629) interleaves **Thought** (reasoning), **Action** (a tool call), and **Observation** (the tool's result) until the model has enough information to answer. The natural way to loop is a plain `while` inside one step — but that step makes one LLM callout per iteration, and callouts are capped at 100 per transaction (see Governor limits below). Model the loop as a **cycle in the DAG** instead: `ReasonStep` (Thought + choose an Action) routes to `ActStep` (run the tool, record the Observation), which always routes back to `ReasonStep` — until the model emits `Finish[answer]`, which routes to a terminal step.

```java
public String getNextStep(String currentStep, StepResult result) {
    if (currentStep == 'ReActLoopWorkflowExample.ReasonStep') {
        Map<String,Object> out = (Map<String,Object>) JSON.deserializeUntyped(result.directive().outputJson);
        Boolean done = (Boolean) out.get('done');
        return done ? 'ReActLoopWorkflowExample.FinishStep' : 'ReActLoopWorkflowExample.ActStep';
    }
    if (currentStep == 'ReActLoopWorkflowExample.ActStep') {
        return 'ReActLoopWorkflowExample.ReasonStep';  // loop back
    }
    return null; // FinishStep is terminal
}
```

Each iteration threads a growing scratchpad (the Thought/Action/Observation transcript) and an `iteration` counter forward as ordinary step output/input — the same threading technique Pattern 2 uses for `sessionId`. Why the workflow-level loop beats an in-step `while`:

- **Fresh governor-limit budget per iteration.** Each hop is its own Queueable transaction, so a 10-round ReAct trace never risks the 100-callout ceiling the way one step making 10 sequential LLM calls would.
- **No lost reasoning on a transient failure.** If the LLM call or the tool throws mid-loop, only that one step retries with backoff — the scratchpad accumulated so far is durable and is never replayed or discarded.
- **A complete, inspectable audit trail.** Every Thought, Action, and Observation is a `Workflow_Step_Execution__c` record, not just the final answer.
- **A loop guard is mandatory.** Cap iterations (a `MAX_ITERATIONS` check in `ReasonStep`) and route straight to the terminal step once hit, so a model that never emits `Finish[...]` still ends gracefully instead of looping until the watchdog or DML limits step in.

Full example: `examples/main/default/classes/ReActLoopWorkflowExample.cls` — two tools (`Search[query]`, `Calculator[expr]`) plus `Finish[answer]`, with a static-mock harness (`mockLlmResponses`) for driving the loop deterministically in tests.

---

## Testing AI steps

### `aiplatform.ModelsAPI` — static mock field

Inject a canned classification before `WorkflowEngine.start()`:

```java
@isTest
static void testBillingInquiryAutoResolves() {
    AiSupportTriageWorkflowExample.mockAiClassification = 'billing';

    Test.startTest();
    Id instanceId = WorkflowEngine.start(
        'AiSupportTriageWorkflowExample.TriageWorkflow',
        'triage-1',
        new Map<String,Object>{ 'inquiryText' => 'I was charged twice.' }
    );
    WorkflowTestHarness.Result result = new WorkflowTestHarness(instanceId).drive();
    Test.stopTest();

    System.assertEquals('Completed', result.status);
    System.assert(result.reachedStep('AiSupportTriageWorkflowExample.AutoResolveBillingStep'));
}
```

The `classifyWithLlm` helper checks `String.isNotBlank(mockAiClassification)` at the top and returns early — no live LLM call is made.

### `Invocable.Action` — `Test.isRunningTest()` guard

`Invocable.Action.createCustomAction()` throws in test context if the named agent doesn't exist. Guard at the call site and inject mock responses via a list:

```java
@TestVisible private static List<String> mockAgentResponses;

private static AgentResponse invokeAgent(...) {
    if (Test.isRunningTest()) {
        AgentResponse mock = new AgentResponse();
        mock.agentResponse = mockAgentResponses.get(mockResponseIndex);
        mock.sessionId = 'mock-session-' + mockResponseIndex;
        mock.success = true;
        return mock;
    }
    // live path ...
}
```

In the test, set responses before starting the workflow (index 0 = first turn, 1 = second turn):

```java
@isTest
static void testMultiTurnConversation() {
    AgentConversationWorkflowExample.mockAgentResponses = new List<String>{
        'Thanks for reaching out. Could you tell me more?',
        'I found your account. Renewal confirmed.'
    };

    Test.startTest();
    Id instanceId = WorkflowEngine.start(
        'AgentConversationWorkflowExample.AgentConversationWorkflow',
        'AgentConv_1',
        new Map<String,Object>{
            'agentDeveloperName' => 'Support_Agent',
            'userMessage'        => 'Help with my renewal.'
        }
    );
    WorkflowTestHarness harness = new WorkflowTestHarness(instanceId);
    WorkflowTestHarness.Result suspended = harness.drive();
    System.assertEquals('Suspended', suspended.status);

    WorkflowTestHarness.Result completed = harness.injectSignal(
        'AgentConv_1', 'FollowUp', '{"message":"My account is ACC-12345"}'
    );
    Test.stopTest();

    System.assertEquals('Completed', completed.status);
}
```

### Human-in-the-loop in tests

Use `injectSignal` with the `Approve:` prefix:

```java
harness.injectSignal('triage-1', 'Approve:EscalationReview', '{"approved":true}');
```

See `docs/testing.md` Pattern 2 for the full approval flow test template.

---

## Naming pitfall: don't shadow the `JSON` class

In Apex, a local variable or parameter named `json` shadows the built-in `JSON` class. This compiles but fails at deploy time:

```java
// BAD — 'json' shadows JSON class; deserializeUntyped is called on the String variable
private static Map<String,Object> parse(String json) {
    return (Map<String,Object>) JSON.deserializeUntyped(json); // deploy error
}

// GOOD
private static Map<String,Object> parseJson(String jsonStr) {
    return (Map<String,Object>) JSON.deserializeUntyped(jsonStr);
}
```

---

## Governor limits

| API | Counts against | Notes |
|---|---|---|
| `aiplatform.ModelsAPI.createGenerations()` | Callout count (100/tx) | Synchronous; no `@future` needed |
| `Invocable.Action.invoke()` | Callout count (100/tx) | Synchronous; same callout budget |
| `Invocable.Action.invoke()` | Callout count (100/tx) | Cannot be called from a `@future` or batch `execute()` |

Both APIs require a callout-allowed context. `WorkflowOrchestrator implements Database.AllowsCallouts` already provides this — steps run inside a Queueable that's allowed to call out.

The 100-callout limit is per transaction. A step that makes one LLM call counts as one callout. If a single step needs to loop and call the API many times, move the loop to the workflow level (one step per iteration) so each hop gets a fresh budget.

---

## Org setup

`project-scratch-def.json` must include:

```json
{
  "orgName": "Revenant Dev",
  "edition": "developer",
  "features": ["Einstein1AIPlatform"],
  "settings": {
    "agentPlatformSettings": { "enableAgentPlatform": true },
    "einsteinGptSettings":   { "enableEinsteinGptPlatform": true }
  }
}
```

For `Invocable.Action` / `generateAiAgentResponse`, the target agent must be created in **Agent Studio** (Setup → Agents) with:
- A Developer Name matching the `agentDeveloperName` input (e.g. `Support_Agent`)
- At least one configured Topic that handles the inquiry type
- The agent deployed and active in the org

`aiplatform.ModelsAPI` works without any additional agent setup — the model is accessed directly.

---

## Decision table

| Requirement | Use |
|---|---|
| Classify, extract, or summarize text in one call | `aiplatform.ModelsAPI` |
| Route a workflow based on AI output | `aiplatform.ModelsAPI` + `getNextStep()` branching |
| Multi-turn conversation with memory between turns | `Invocable.Action` + sessionId threading |
| Leverage an agent with pre-built topics and CRM actions | `Invocable.Action` |
| Let the model reason, call tools, and iterate (ReAct) | `aiplatform.ModelsAPI` + a `ReasonStep`/`ActStep` DAG cycle |
| Human sign-off on an AI recommendation | `StepResult.waitForApproval()` |
| Retry failed AI calls automatically | Both — engine retries the step on any unhandled exception |
| Audit trail of every AI decision | Both — step execution records capture all output |
