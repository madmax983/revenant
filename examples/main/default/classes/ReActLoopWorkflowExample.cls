/**
 * ReAct (Reason + Act) Tool-Calling Loop
 *
 * Shows the classic ReAct pattern (Yao et al., 2022) — an LLM alternates
 * between reasoning ("Thought"), invoking a tool ("Action"), and reading the
 * tool's result ("Observation") until it has enough information to answer —
 * built as a Revenant workflow loop instead of an in-memory while-loop.
 *
 * Flow (a cycle in the DAG, not a straight line):
 *
 *   ReasonStep ──(tool call needed)──> ActStep ──> ReasonStep ──> ActStep ──> ...
 *      │                                                                 │
 *      └──────────────────────(model emits Finish[answer])───────────> FinishStep
 *
 * Why this needs to be a *workflow* loop, not a plain Apex `while` loop:
 *  - Each LLM call is a callout, capped at 100 per transaction. A hand-rolled
 *    loop that calls the model many times in one execute() burns through that
 *    budget on a single hop. Splitting Thought/Act into their own steps means
 *    every iteration gets a *fresh* transaction and a fresh governor-limit
 *    budget — see docs/agentforce.md ("move the loop to the workflow level").
 *  - If the tool call or the model call throws mid-reasoning, only that one
 *    step retries (with backoff) — the scratchpad already accumulated in
 *    prior iterations is never lost or replayed.
 *  - Every Thought/Action/Observation is captured verbatim in the immutable
 *    Workflow_Step_Execution__c audit trail — a complete, inspectable replay
 *    of the agent's reasoning, not just its final answer.
 *  - A MAX_ITERATIONS guard (below) forces a graceful FinishStep instead of
 *    looping forever if the model never emits `Finish[...]`.
 *
 * Tools available to the model:
 *   Search[query]      — looks up a fact in a small static knowledge base
 *   Calculator[expr]   — evaluates an arithmetic expression
 *   Finish[answer]     — ends the loop with a final answer
 *
 * Input: { "question": "..." }
 */
public with sharing class ReActLoopWorkflowExample {
  /**
   * Set in @isTest methods to skip the real aiplatform.ModelsAPI call. Element
   * N is returned on the (N+1)th visit to ReasonStep (0-based), so a 3-round
   * ReAct trace supplies 3 entries: e.g. a Search, a Calculator, then a Finish.
   */
  @TestVisible
  private static List<String> mockLlmResponses;

  @TestVisible
  private static String aiModel = 'sfdc_ai__DefaultGPT35Turbo';

  // Loop guard: forces FinishStep instead of looping forever if the model
  // never emits Finish[...]. Each iteration is one ReasonStep + ActStep hop.
  @TestVisible
  private static Integer maxIterations = 5;

  // Toy knowledge base for the Search[query] tool — a stand-in for a real
  // lookup (SOQL, Knowledge article search, or an external API callout).
  private static final Map<String, String> KNOWLEDGE_BASE = new Map<String, String>{
    'sfdc revenue' => 'Salesforce reported FY2025 total revenue of approximately $37.9 billion.',
    'temporal' => 'Temporal is a durable execution engine; Revenant is inspired by it and by DBOS.',
    'react paper' => 'ReAct (Yao et al., 2022) interleaves reasoning traces ("Thought") with actions ("Action") and observations to let an LLM plan and use tools.'
  };

  // ── Workflow definition ────────────────────────────────────────────────────

  public class ReActLoopWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{
        'ReActLoopWorkflowExample.ReasonStep',
        'ReActLoopWorkflowExample.ActStep',
        'ReActLoopWorkflowExample.FinishStep'
      };
    }

    public String getInitialStep() {
      return 'ReActLoopWorkflowExample.ReasonStep';
    }

    public String getNextStep(String currentStep, StepResult result) {
      if (currentStep == 'ReActLoopWorkflowExample.ReasonStep') {
        Map<String, Object> out = (Map<String, Object>) JSON.deserializeUntyped(
          result.outputJson
        );
        Boolean done = (Boolean) out.get('done');
        return done
          ? 'ReActLoopWorkflowExample.FinishStep'
          : 'ReActLoopWorkflowExample.ActStep';
      }
      if (currentStep == 'ReActLoopWorkflowExample.ActStep') {
        // Loop back: the engine records a fresh Workflow_Step_Execution__c and
        // idempotency-key visit sequence each time we cycle back to ReasonStep.
        return 'ReActLoopWorkflowExample.ReasonStep';
      }
      return null; // FinishStep is terminal
    }
  }

  // ── Step definitions ───────────────────────────────────────────────────────

  /**
   * Thought + Action: asks the model what to do next given the question and
   * everything observed so far, then decides whether to call a tool (routes
   * to ActStep) or stop (routes to FinishStep).
   */
  public class ReasonStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      Map<String, Object> input = parseJson(ctx.inputJson);
      String question = (String) input.get('question');
      if (String.isBlank(question)) {
        throw new WorkflowEngine.WorkflowException('question is required');
      }
      String scratchpad = readScratchpad(input);
      Integer iteration = readIteration(input);

      if (iteration >= maxIterations) {
        return StepResult.complete(null, maxIterationsResult(scratchpad));
      }

      String completion = reason(question, scratchpad, iteration);
      ParsedStep parsed = parseReactCompletion(completion);
      String updatedScratchpad = scratchpad + '\nThought: ' + parsed.thought;

      if (parsed.isFinish) {
        return StepResult.complete(
          null,
          finishResult(parsed, updatedScratchpad)
        );
      }

      return StepResult.complete(
        null,
        new Map<String, Object>{
          'done' => false,
          'question' => question,
          'scratchpad' => updatedScratchpad,
          'iteration' => iteration,
          'toolName' => parsed.actionName,
          'toolInput' => parsed.actionInput
        }
      );
    }

    private String readScratchpad(Map<String, Object> input) {
      return input.containsKey('scratchpad')
        ? (String) input.get('scratchpad')
        : '';
    }

    private Integer readIteration(Map<String, Object> input) {
      return input.containsKey('iteration')
        ? Integer.valueOf(String.valueOf(input.get('iteration')))
        : 0;
    }

    private Map<String, Object> maxIterationsResult(String scratchpad) {
      return new Map<String, Object>{
        'done' => true,
        'finalAnswer' => 'Could not reach a final answer within ' +
        maxIterations +
        ' reasoning steps.',
        'scratchpad' => scratchpad
      };
    }

    private Map<String, Object> finishResult(
      ParsedStep parsed,
      String updatedScratchpad
    ) {
      return new Map<String, Object>{
        'done' => true,
        'finalAnswer' => parsed.actionInput,
        'scratchpad' => updatedScratchpad +
        '\nFinish[' +
        parsed.actionInput +
        ']'
      };
    }
  }

  /**
   * Action + Observation: executes the tool ReasonStep chose and appends the
   * result to the scratchpad, then always loops back to ReasonStep so the
   * model can react to what it just observed.
   */
  public class ActStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      Map<String, Object> input = parseJson(ctx.inputJson);
      String question = (String) input.get('question');
      String scratchpad = (String) input.get('scratchpad');
      Integer iteration = Integer.valueOf(
        String.valueOf(input.get('iteration'))
      );
      String toolName = (String) input.get('toolName');
      String toolInput = (String) input.get('toolInput');

      String observation = runTool(toolName, toolInput);
      String updatedScratchpad =
        scratchpad +
        '\nAction: ' +
        toolName +
        '[' +
        toolInput +
        ']' +
        '\nObservation: ' +
        observation;

      return StepResult.complete(
        null,
        new Map<String, Object>{
          'question' => question,
          'scratchpad' => updatedScratchpad,
          'iteration' => iteration + 1
        }
      );
    }
  }

  /**
   * Terminal step: surfaces the model's final answer and the full
   * Thought/Action/Observation transcript that led to it.
   */
  public class FinishStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      Map<String, Object> input = parseJson(ctx.inputJson);
      return StepResult.complete(
        null,
        new Map<String, Object>{
          'finalAnswer' => input.get('finalAnswer'),
          'scratchpad' => input.get('scratchpad')
        }
      );
    }
  }

  // ── Tools ───────────────────────────────────────────────────────────────────

  @TestVisible
  private static String runTool(String toolName, String toolInput) {
    if (String.isBlank(toolName)) {
      return 'Error: no tool specified.';
    }
    if (toolName.equalsIgnoreCase('Search')) {
      return searchKnowledgeBase(toolInput);
    }
    if (toolName.equalsIgnoreCase('Calculator')) {
      return evaluateArithmetic(toolInput);
    }
    return 'Error: unknown tool "' +
      toolName +
      '". Available tools: Search, Calculator.';
  }

  private static String searchKnowledgeBase(String query) {
    String needle = query == null ? '' : query.trim().toLowerCase();
    for (String key : KNOWLEDGE_BASE.keySet()) {
      if (needle.contains(key)) {
        return KNOWLEDGE_BASE.get(key);
      }
    }
    return 'No knowledge base entry found for "' + query + '".';
  }

  @TestVisible
  private static String evaluateArithmetic(String expression) {
    try {
      ReActArithmeticParser parser = new ReActArithmeticParser(expression);
      Decimal value = parser.parseExpression();
      parser.expectEnd();
      return String.valueOf(value);
    } catch (Exception e) {
      return 'Error: could not evaluate expression "' +
        expression +
        '" (' +
        e.getMessage() +
        ')';
    }
  }

  // ── LLM helper (ReAct prompting via aiplatform.ModelsAPI) ──────────────────

  @TestVisible
  private class ParsedStep {
    public String thought;
    public Boolean isFinish = false;
    public String actionName;
    public String actionInput;
  }

  private static String reason(
    String question,
    String scratchpad,
    Integer iteration
  ) {
    if (mockLlmResponses != null && mockLlmResponses.size() > iteration) {
      return mockLlmResponses[iteration];
    }

    aiplatform.ModelsAPI.createGenerations_Request request = new aiplatform.ModelsAPI.createGenerations_Request();
    request.modelName = aiModel;

    aiplatform.ModelsAPI_GenerationRequest body = new aiplatform.ModelsAPI_GenerationRequest();
    body.prompt = buildPrompt(question, scratchpad);
    request.body = body;

    aiplatform.ModelsAPI modelsAPI = new aiplatform.ModelsAPI();
    aiplatform.ModelsAPI.createGenerations_Response response = modelsAPI.createGenerations(
      request
    );
    return response.Code200.generation.generatedText;
  }

  private static String buildPrompt(String question, String scratchpad) {
    return 'Answer the question using interleaved Thought/Action/Observation steps (the ReAct method).\n\n' +
      'Available tools:\n' +
      '  Search[query]     - look up a fact in the knowledge base\n' +
      '  Calculator[expr]  - evaluate an arithmetic expression\n' +
      '  Finish[answer]    - give the final answer and stop\n\n' +
      'Respond with EXACTLY two lines, in this form:\n' +
      'Thought: <your reasoning about what to do next>\n' +
      'Action: <ToolName>[<tool input>]\n\n' +
      'Question: ' +
      question +
      '\n' +
      scratchpad +
      '\n';
  }

  @TestVisible
  private static ParsedStep parseReactCompletion(String completion) {
    ParsedStep parsed = new ParsedStep();

    Matcher thoughtMatcher = Pattern.compile('(?im)^Thought:\\s*(.+)$')
      .matcher(completion);
    parsed.thought = thoughtMatcher.find()
      ? thoughtMatcher.group(1).trim()
      : completion.trim();

    Matcher actionMatcher = Pattern.compile(
        '(?im)^Action:\\s*(\\w+)\\[(.*)\\]\\s*$'
      )
      .matcher(completion);
    if (!actionMatcher.find()) {
      // Model didn't follow the Action[...] format — fail safe by finishing
      // with whatever it said rather than looping on an unparseable reply.
      parsed.isFinish = true;
      parsed.actionInput = parsed.thought;
      return parsed;
    }

    parsed.actionName = actionMatcher.group(1);
    parsed.actionInput = actionMatcher.group(2).trim();
    parsed.isFinish = parsed.actionName.equalsIgnoreCase('Finish');
    return parsed;
  }

  private static Map<String, Object> parseJson(String jsonStr) {
    if (String.isBlank(jsonStr)) {
      return new Map<String, Object>();
    }
    return (Map<String, Object>) JSON.deserializeUntyped(jsonStr);
  }
}
