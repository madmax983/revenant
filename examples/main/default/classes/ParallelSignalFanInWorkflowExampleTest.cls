/**
 * Issue #38 reference scenario: a parallel (scatter-gather) branch that needs to
 * inspect MANY DISTINCT signal names should call ctx.getSignals() ONCE and filter
 * in memory, rather than issuing a per-name ctx.getSignal(name) / ctx.hasSignal(name)
 * lookup for each name.
 *
 * Inside a parallel branch each read atomically CLAIMS the signals it sees
 * (Received -> Processing, promoted to Consumed at COMPLETE) for exactly-once
 * delivery across siblings. A single getSignals() claims the whole pending page in
 * one DML statement and stays exactly-once; per-name lookups each spend a claim
 * statement (and a FOR UPDATE lock query), so past the engine's internal per-branch
 * claim budget the overflow names would degrade to at-least-once.
 *
 * This test pins the recommended primitive: one getSignals() call in a parallel
 * branch observes every distinct present name and consumes each exactly once.
 */
@isTest
private class ParallelSignalFanInWorkflowExampleTest {
  @isTest
  static void testCollectorBranchClaimsManyDistinctNamesExactlyOnceInOnePass() {
    Id instanceId = WorkflowEngine.start(
      'ParallelSignalFanInWorkflowExample',
      'FanInKey',
      null
    );

    // 1. First run: the gather step has no Kick signal yet -> suspends.
    new WorkflowOrchestrator(instanceId).execute(null);

    Workflow_Instance__c inst = [
      SELECT Status__c, Current_Step__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals('Suspended', inst.Status__c);
    System.assertEquals(
      'ParallelSignalFanInWorkflowExample.GatherSpawnStep',
      inst.Current_Step__c
    );

    // 2. Kick the fan-out, then deliver several DISTINCT named acknowledgements
    //    the collector branch will inspect (one name per upstream worker).
    WorkflowEngine.signal('FanInKey', 'Kick', '{}');
    WorkflowEngine.signal('FanInKey', 'Ack:US', '{"ok":true}');
    WorkflowEngine.signal('FanInKey', 'Ack:EU', '{"ok":true}');
    WorkflowEngine.signal('FanInKey', 'Ack:APAC', '{"ok":true}');

    // The three distinct acks are buffered (Kick is consumed by the spawn step).
    System.assertEquals(
      3,
      [
        SELECT COUNT()
        FROM Workflow_Signal__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Signal_Name__c LIKE 'Ack:%'
          AND Status__c = 'Received'
      ],
      'All three distinct acks should be buffered before fan-out'
    );

    // 3. Resume: the gather step reads Kick and SPLITs into the collector + sibling.
    new WorkflowOrchestrator(instanceId).execute(null);

    // 4. Run the collector branch. It calls getSignals() ONCE and filters by name.
    new WorkflowOrchestrator(
        instanceId,
        'ParallelSignalFanInWorkflowExample.CollectorBranch'
      )
      .execute(null);

    Workflow_Step_Execution__c branchExec = [
      SELECT Status__c, Output__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :instanceId
        AND Step_Name__c = 'ParallelSignalFanInWorkflowExample.CollectorBranch'
        AND Status__c = 'Completed'
    ];

    // The single getSignals() pass saw every distinct present name...
    System.assert(
      branchExec.Output__c.contains('"collectedVia":"getSignals"'),
      'Collector must report it used the recommended getSignals() primitive, got: ' +
      branchExec.Output__c
    );
    for (String name : new List<String>{ 'Ack:US', 'Ack:EU', 'Ack:APAC' }) {
      System.assert(
        branchExec.Output__c.contains(name),
        'Collector must observe ' +
        name +
        ' in its single getSignals() pass, got: ' +
        branchExec.Output__c
      );
    }
    System.assert(
      branchExec.Output__c.contains('"count":3'),
      'Collector must observe all 3 distinct names, got: ' + branchExec.Output__c
    );

    // ...and each distinct ack was claimed and consumed EXACTLY ONCE: none remain
    // Received (missed) or Processing (claimed but not promoted).
    System.assertEquals(
      3,
      [
        SELECT COUNT()
        FROM Workflow_Signal__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Signal_Name__c LIKE 'Ack:%'
          AND Status__c = 'Consumed'
      ],
      'All three distinct acks must be consumed exactly once by the single getSignals() claim'
    );
    System.assertEquals(
      0,
      [
        SELECT COUNT()
        FROM Workflow_Signal__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Signal_Name__c LIKE 'Ack:%'
          AND Status__c IN ('Received', 'Processing')
      ],
      'No ack may be left unclaimed (Received) or stuck claimed (Processing)'
    );
  }
}
