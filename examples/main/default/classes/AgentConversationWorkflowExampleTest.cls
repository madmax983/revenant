@isTest
public class AgentConversationWorkflowExampleTest {
  /**
   * Full multi-turn conversation: workflow runs to AwaitFollowUpStep,
   * suspends, then resumes with a follow-up signal and drives to completion
   * using the stored sessionId. Verifies the sessionId is threaded through.
   */
  @isTest
  static void testMultiTurnConversationRunsToCompletion() {
    AgentConversationWorkflowExample.mockAgentResponses = new List<String>{
      'Thanks for reaching out. Could you tell me more about your account?',
      'I found your account. Your subscription has been renewed successfully.'
    };

    Test.startTest();
    Id instanceId = WorkflowEngine.start(
      'AgentConversationWorkflowExample.AgentConversationWorkflow',
      'AgentConv_1',
      new Map<String, Object>{
        'agentDeveloperName' => 'Support_Agent',
        'userMessage' => 'I need help with my subscription renewal.'
      }
    );
    WorkflowTestHarness harness = new WorkflowTestHarness(instanceId);

    // Drive to AwaitFollowUpStep — should suspend waiting for the follow-up signal
    WorkflowTestHarness.Result suspended = harness.drive();

    System.assertEquals(
      'Suspended',
      suspended.status,
      'Workflow should suspend at AwaitFollowUpStep'
    );
    System.assert(
      suspended.reachedStep('AgentConversationWorkflowExample.InitialTurnStep'),
      'InitialTurnStep should appear in the audit trail'
    );

    // Verify InitialTurnStep captured the first agent response and sessionId
    List<Workflow_Step_Execution__c> initialExecs = [
      SELECT Output__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :instanceId
        AND Step_Name__c = 'AgentConversationWorkflowExample.InitialTurnStep'
        AND Status__c = 'Completed'
    ];
    System.assertEquals(1, initialExecs.size(), 'InitialTurnStep should be completed');
    Map<String, Object> initialOut = (Map<String, Object>) JSON.deserializeUntyped(
      initialExecs[0].Output__c
    );
    System.assertEquals('mock-session-0', (String) initialOut.get('sessionId'));
    System.assert(
      ((String) initialOut.get('initialResponse')).contains('Could you tell me more')
    );

    // Resume: inject the follow-up signal and drive to completion
    WorkflowTestHarness.Result completed = harness.injectSignal(
      'AgentConv_1',
      'FollowUp',
      '{"message":"My account number is ACC-12345"}'
    );
    Test.stopTest();

    System.assertEquals('Completed', completed.status, 'Should complete after follow-up');
    System.assert(completed.isTerminal, 'Completed is terminal');

    Map<String, Object> output = (Map<String, Object>) JSON.deserializeUntyped(
      completed.output
    );
    System.assertEquals('completed', output.get('resolution'));
    System.assert(
      ((String) output.get('finalResponse')).contains('renewed successfully')
    );
    // sessionId from the continuation turn (mock-session-1 since it's turn index 1)
    System.assertEquals('mock-session-1', (String) output.get('sessionId'));
  }

  /**
   * Verifies that every step is recorded in the audit trail and that the
   * follow-up message from the signal is correctly threaded to ContinuationTurnStep.
   */
  @isTest
  static void testAuditTrailCapturesAllTurns() {
    AgentConversationWorkflowExample.mockAgentResponses = new List<String>{
      'Agent turn 1 response',
      'Agent turn 2 response'
    };

    Test.startTest();
    Id instanceId = WorkflowEngine.start(
      'AgentConversationWorkflowExample.AgentConversationWorkflow',
      'AgentConv_Audit_1',
      new Map<String, Object>{
        'agentDeveloperName' => 'Support_Agent',
        'userMessage' => 'Test message'
      }
    );
    WorkflowTestHarness harness = new WorkflowTestHarness(instanceId);
    harness.drive(); // Drive to suspension

    harness.injectSignal(
      'AgentConv_Audit_1',
      'FollowUp',
      '{"message":"Follow-up context"}'
    );
    Test.stopTest();

    // Verify all four steps appear in the execution audit
    List<Workflow_Step_Execution__c> execs = [
      SELECT Step_Name__c, Status__c
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c = :instanceId
      ORDER BY CreatedDate ASC
    ];
    Set<String> stepNames = new Set<String>();
    for (Workflow_Step_Execution__c e : execs) {
      System.assertEquals('Completed', e.Status__c, e.Step_Name__c + ' should be Completed');
      stepNames.add(e.Step_Name__c);
    }
    System.assert(
      stepNames.contains('AgentConversationWorkflowExample.InitialTurnStep'),
      'InitialTurnStep missing from audit'
    );
    System.assert(
      stepNames.contains('AgentConversationWorkflowExample.AwaitFollowUpStep'),
      'AwaitFollowUpStep missing from audit'
    );
    System.assert(
      stepNames.contains('AgentConversationWorkflowExample.ContinuationTurnStep'),
      'ContinuationTurnStep missing from audit'
    );
    System.assert(
      stepNames.contains('AgentConversationWorkflowExample.ConversationCompleteStep'),
      'ConversationCompleteStep missing from audit'
    );

    // AwaitFollowUpStep output should contain the follow-up message and sessionId
    Workflow_Step_Execution__c awaitExec = [
      SELECT Output__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :instanceId
        AND Step_Name__c = 'AgentConversationWorkflowExample.AwaitFollowUpStep'
      LIMIT 1
    ];
    Map<String, Object> awaitOut = (Map<String, Object>) JSON.deserializeUntyped(
      awaitExec.Output__c
    );
    System.assertEquals('Follow-up context', (String) awaitOut.get('followUpMessage'));
    System.assertEquals('mock-session-0', (String) awaitOut.get('sessionId'),
      'sessionId from InitialTurnStep must be threaded to ContinuationTurnStep'
    );
  }
}
