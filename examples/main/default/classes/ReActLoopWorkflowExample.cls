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
  private static String AI_MODEL = 'sfdc_ai__DefaultGPT35Turbo';

  // Loop guard: forces FinishStep instead of looping forever if the model
  // never emits Finish[...]. Each iteration is one ReasonStep + ActStep hop.
  @TestVisible
  private static Integer MAX_ITERATIONS = 5;

  // Toy knowledge base for the Search[query] tool — a stand-in for a real
  // lookup (SOQL, Knowledge article search, or an external API callout).
  private static final Map<String, String> KNOWLEDGE_BASE = new Map<String, String>{
    'sfdc revenue' => 'Salesforce reported FY2025 total revenue of approximately $37.9 billion.',
    'temporal' => 'Temporal is a durable execution engine; Revenant is inspired by it and by DBOS.',
    'react paper' => 'ReAct (Yao et al., 2022) interleaves reasoning traces ("Thought") with actions ("Action") and observations to let an LLM plan and use tools.'
  };

  // ── Workflow definition ────────────────────────────────────────────────────

  /**
   * @description The ReAct loop workflow definition: a cyclic DAG that alternates
   * ReasonStep and ActStep until the model decides to finish, then routes to FinishStep.
   */
  public class ReActLoopWorkflow implements WorkflowDefinition {
    /**
     * @description Declares the reason, act, and finish steps of the ReAct loop.
     * @return The list of step names in the ReAct workflow.
     */
    public List<String> getSteps() {
      return new List<String>{
        'ReActLoopWorkflowExample.ReasonStep',
        'ReActLoopWorkflowExample.ActStep',
        'ReActLoopWorkflowExample.FinishStep'
      };
    }

    /**
     * @description Returns the first step, the reasoning step.
     * @return The name of the initial step.
     */
    public String getInitialStep() {
      return 'ReActLoopWorkflowExample.ReasonStep';
    }

    /**
     * @description Drives the loop: ReasonStep routes to ActStep or FinishStep based
     * on whether the model is done, and ActStep always cycles back to ReasonStep.
     * @param currentStep The name of the step that just completed.
     * @param result The result of the completed step, whose output drives routing.
     * @return The next step name, or null after the terminal FinishStep.
     */
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
    /**
     * @description Asks the model for the next Thought/Action given the question and
     * scratchpad, appends the thought, and either finishes (with the answer or on
     * hitting the iteration guard) or emits the chosen tool call for ActStep.
     * @param ctx The durable step context exposing the question and accumulated scratchpad.
     * @return A complete result flagged done to finish, or carrying the next tool call.
     */
    public StepResult execute(StepContext ctx) {
      Map<String, Object> input = parseJson(ctx.inputJson);
      String question = (String) input.get('question');
      if (String.isBlank(question)) {
        throw new WorkflowEngine.WorkflowException('question is required');
      }
      String scratchpad = input.containsKey('scratchpad')
        ? (String) input.get('scratchpad')
        : '';
      Integer iteration = input.containsKey('iteration')
        ? Integer.valueOf(String.valueOf(input.get('iteration')))
        : 0;

      if (iteration >= MAX_ITERATIONS) {
        return StepResult.complete(
          null,
          new Map<String, Object>{
            'done' => true,
            'finalAnswer' => 'Could not reach a final answer within ' +
            MAX_ITERATIONS +
            ' reasoning steps.',
            'scratchpad' => scratchpad
          }
        );
      }

      String completion = reason(question, scratchpad, iteration);
      ParsedStep parsed = parseReactCompletion(completion);
      String updatedScratchpad = scratchpad + '\nThought: ' + parsed.thought;

      if (parsed.isFinish) {
        return StepResult.complete(
          null,
          new Map<String, Object>{
            'done' => true,
            'finalAnswer' => parsed.actionInput,
            'scratchpad' => updatedScratchpad +
            '\nFinish[' +
            parsed.actionInput +
            ']'
          }
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
  }

  /**
   * Action + Observation: executes the tool ReasonStep chose and appends the
   * result to the scratchpad, then always loops back to ReasonStep so the
   * model can react to what it just observed.
   */
  public class ActStep implements WorkflowStep {
    /**
     * @description Runs the tool ReasonStep selected, appends the Action/Observation
     * to the scratchpad, increments the iteration, and loops back to ReasonStep.
     * @param ctx The durable step context exposing the chosen tool name and input.
     * @return A complete result carrying the updated scratchpad and iteration count.
     */
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
    /**
     * @description Terminal step that surfaces the model's final answer and the full
     * Thought/Action/Observation transcript.
     * @param ctx The durable step context exposing the final answer and scratchpad.
     * @return A complete result carrying the final answer and transcript.
     */
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
      ArithmeticParser parser = new ArithmeticParser(expression);
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

  /**
   * Minimal recursive-descent parser for +, -, *, /, and parentheses — just
   * enough to back the Calculator[expr] tool without an external dependency.
   */
  private class ArithmeticParser {
    private final String src;
    private Integer pos = 0;

    ArithmeticParser(String expression) {
      this.src = (expression == null) ? '' : expression.replaceAll('\\s+', '');
    }

    Decimal parseExpression() {
      Decimal value = parseTerm();
      while (pos < src.length() && (peek() == '+' || peek() == '-')) {
        String op = peek();
        pos++;
        Decimal rhs = parseTerm();
        value = (op == '+') ? value + rhs : value - rhs;
      }
      return value;
    }

    Decimal parseTerm() {
      Decimal value = parseFactor();
      while (pos < src.length() && (peek() == '*' || peek() == '/')) {
        String op = peek();
        pos++;
        Decimal rhs = parseFactor();
        if (op == '*') {
          value = value * rhs;
        } else {
          if (rhs == 0) {
            throw new IllegalArgumentException('division by zero');
          }
          value = value / rhs;
        }
      }
      return value;
    }

    Decimal parseFactor() {
      if (pos < src.length() && peek() == '-') {
        pos++;
        return -parseFactor();
      }
      if (pos < src.length() && peek() == '(') {
        pos++;
        Decimal value = parseExpression();
        expect(')');
        return value;
      }
      return parseNumber();
    }

    Decimal parseNumber() {
      Integer start = pos;
      while (pos < src.length() && (peek().isNumeric() || peek() == '.')) {
        pos++;
      }
      if (start == pos) {
        throw new IllegalArgumentException(
          'expected a number at position ' + pos
        );
      }
      return Decimal.valueOf(src.substring(start, pos));
    }

    private String peek() {
      return src.substring(pos, pos + 1);
    }

    private void expect(String ch) {
      if (pos >= src.length() || peek() != ch) {
        throw new IllegalArgumentException(
          'expected "' + ch + '" at position ' + pos
        );
      }
      pos++;
    }

    void expectEnd() {
      if (pos != src.length()) {
        throw new IllegalArgumentException(
          'unexpected trailing characters at position ' + pos
        );
      }
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
    request.modelName = AI_MODEL;

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
