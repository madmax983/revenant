@IsTest
public class ReActLoopWorkflowExampleTest {
  /**
   * Happy path: the model uses both tools across two ReAct rounds — Search
   * to look up a fact, Calculator to do the math on it — then finishes.
   * Verifies the loop threads the scratchpad forward correctly and that the
   * final transcript captures every Thought/Action/Observation.
   */
  @IsTest
  static void testReActLoopUsesToolsAcrossMultipleRoundsThenFinishes() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      ReActLoopWorkflowExample.mockLlmResponses = new List<String>{
        'Thought: I should look up Salesforce\'s FY2025 revenue.\nAction: Search[sfdc revenue]',
        'Thought: That is about $38 billion; the question asks for double that.\nAction: Calculator[38 * 2]',
        'Thought: I have computed the final answer.\nAction: Finish[76]'
      };

      Test.startTest();
      Id instanceId = WorkflowEngine.start(
        'ReActLoopWorkflowExample.ReActLoopWorkflow',
        'ReAct_Happy_1',
        new Map<String, Object>{
          'question' => 'Roughly double Salesforce\'s FY2025 revenue in billions.'
        }
      );
      WorkflowTestHarness.Result result = new WorkflowTestHarness(instanceId)
        .drive();
      Test.stopTest();

      System.assertEquals('Completed', result.status);
      System.assert(result.isTerminal, 'Completed is a terminal state');
      System.assert(result.reachedStep('ReActLoopWorkflowExample.FinishStep'));

      Map<String, Object> output = (Map<String, Object>) JSON.deserializeUntyped(
        result.output
      );
      System.assertEquals('76', output.get('finalAnswer'));

      String scratchpad = (String) output.get('scratchpad');
      System.assert(
        scratchpad.contains('Action: Search[sfdc revenue]'),
        'Scratchpad should record the Search action'
      );
      System.assert(
        scratchpad.contains('Observation: Salesforce reported FY2025'),
        'Scratchpad should record the Search observation'
      );
      System.assert(
        scratchpad.contains('Action: Calculator[38 * 2]'),
        'Scratchpad should record the Calculator action'
      );
      System.assert(
        scratchpad.contains('Observation: 76'),
        'Scratchpad should record the Calculator observation'
      );
      System.assert(
        scratchpad.contains('Finish[76]'),
        'Scratchpad should record the Finish action'
      );

      // Two full Reason/Act rounds plus the final Reason that emits Finish.
      Integer reasonVisits = 0;
      Integer actVisits = 0;
      for (String stepName : result.executedSteps) {
        if (stepName == 'ReActLoopWorkflowExample.ReasonStep') {
          reasonVisits++;
        }
        if (stepName == 'ReActLoopWorkflowExample.ActStep') {
          actVisits++;
        }
      }
      System.assertEquals(
        3,
        reasonVisits,
        'ReasonStep should run once per round plus the Finish round'
      );
      System.assertEquals(
        2,
        actVisits,
        'ActStep should run once per tool call'
      );
    }
  }

  /**
   * An unrecognized tool name doesn't fail the workflow — runTool() returns
   * an error observation the model can react to on the next round, exactly
   * like a real ReAct agent recovering from a bad tool call.
   */
  @IsTest
  static void testUnknownToolYieldsObservationAndLoopContinues() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      ReActLoopWorkflowExample.mockLlmResponses = new List<String>{
        'Thought: Let me check the weather.\nAction: Weather[Paris]',
        'Thought: That tool does not exist; I already know the answer.\nAction: Finish[42]'
      };

      Test.startTest();
      Id instanceId = WorkflowEngine.start(
        'ReActLoopWorkflowExample.ReActLoopWorkflow',
        'ReAct_UnknownTool_1',
        new Map<String, Object>{
          'question' => 'What is the answer to everything?'
        }
      );
      WorkflowTestHarness.Result result = new WorkflowTestHarness(instanceId)
        .drive();
      Test.stopTest();

      System.assertEquals('Completed', result.status);
      Map<String, Object> output = (Map<String, Object>) JSON.deserializeUntyped(
        result.output
      );
      System.assertEquals('42', output.get('finalAnswer'));
      System.assert(
        ((String) output.get('scratchpad'))
          .contains('Error: unknown tool "Weather"'),
        'Scratchpad should record the tool error as an observation'
      );
    }
  }

  /**
   * Loop guard: if the model never emits Finish[...], ReasonStep forces a
   * graceful completion after MAX_ITERATIONS rounds instead of looping
   * forever (and instead of exhausting per-transaction governor limits).
   */
  @IsTest
  static void testLoopGuardForcesGracefulFinishAfterMaxIterations() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      List<String> neverEndingResponses = new List<String>();
      for (Integer i = 0; i < ReActLoopWorkflowExample.maxIterations; i++) {
        neverEndingResponses.add(
          'Thought: Still looking.\nAction: Search[sfdc revenue]'
        );
      }
      ReActLoopWorkflowExample.mockLlmResponses = neverEndingResponses;

      Test.startTest();
      Id instanceId = WorkflowEngine.start(
        'ReActLoopWorkflowExample.ReActLoopWorkflow',
        'ReAct_LoopGuard_1',
        new Map<String, Object>{
          'question' => 'A question the model can never answer.'
        }
      );
      WorkflowTestHarness.Result result = new WorkflowTestHarness(instanceId)
        .drive();
      Test.stopTest();

      System.assertEquals(
        'Completed',
        result.status,
        'Loop guard should still reach a terminal state'
      );
      Map<String, Object> output = (Map<String, Object>) JSON.deserializeUntyped(
        result.output
      );
      System.assert(
        ((String) output.get('finalAnswer'))
          .contains('Could not reach a final answer'),
        'Loop guard should surface a graceful fallback answer'
      );

      Integer reasonVisits = 0;
      Integer actVisits = 0;
      for (String stepName : result.executedSteps) {
        if (stepName == 'ReActLoopWorkflowExample.ReasonStep') {
          reasonVisits++;
        }
        if (stepName == 'ReActLoopWorkflowExample.ActStep') {
          actVisits++;
        }
      }
      System.assertEquals(
        ReActLoopWorkflowExample.maxIterations + 1,
        reasonVisits,
        'ReasonStep visits: one per iteration, plus the guard-triggered visit'
      );
      System.assertEquals(
        ReActLoopWorkflowExample.maxIterations,
        actVisits,
        'ActStep should run exactly MAX_ITERATIONS times before the guard trips'
      );
    }
  }

  /**
   * Unit-level coverage for the Calculator[expr] tool's arithmetic parser,
   * independent of the workflow loop or any LLM call.
   */
  @IsTest
  static void testCalculatorToolEvaluatesArithmeticExpressions() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      System.assertEquals(
        '5',
        ReActLoopWorkflowExample.evaluateArithmetic('2+3')
      );
      System.assertEquals(
        '14',
        ReActLoopWorkflowExample.evaluateArithmetic('2*(3+4)')
      );
      System.assertEquals(
        '2.5',
        ReActLoopWorkflowExample.evaluateArithmetic('10/4')
      );
      System.assertEquals(
        '-1',
        ReActLoopWorkflowExample.evaluateArithmetic('4 - 5')
      );
      System.assert(
        ReActLoopWorkflowExample.evaluateArithmetic('1/0').startsWith('Error:'),
        'Division by zero should be reported as a tool error, not thrown'
      );
      System.assert(
        ReActLoopWorkflowExample.evaluateArithmetic('2 +').startsWith('Error:'),
        'A malformed expression should be reported as a tool error, not thrown'
      );
    }
  }

  /**
   * Unit-level coverage for parsing the model's raw Thought/Action completion
   * text, including the fallback when the model doesn't follow the format.
   */
  @IsTest
  static void testParseReactCompletionHandlesWellFormedAndMalformedText() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      ReActLoopWorkflowExample.ParsedStep finish = ReActLoopWorkflowExample.parseReactCompletion(
        'Thought: Done here.\nAction: Finish[the answer]'
      );
      System.assertEquals('Done here.', finish.thought);
      System.assert(finish.isFinish);
      System.assertEquals('the answer', finish.actionInput);

      ReActLoopWorkflowExample.ParsedStep act = ReActLoopWorkflowExample.parseReactCompletion(
        'Thought: Need a fact.\nAction: Search[revenant]'
      );
      System.assert(!act.isFinish);
      System.assertEquals('Search', act.actionName);
      System.assertEquals('revenant', act.actionInput);

      ReActLoopWorkflowExample.ParsedStep malformed = ReActLoopWorkflowExample.parseReactCompletion(
        'I am just going to answer directly: 76'
      );
      System.assert(
        malformed.isFinish,
        'A reply that skips the Action[...] format should fail safe to Finish'
      );
    }
  }
}
