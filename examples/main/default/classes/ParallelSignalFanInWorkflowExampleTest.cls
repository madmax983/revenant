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

  /**
   * Fan-in gating: when the collector branch is re-driven before every expected
   * ack has arrived, it must NOT complete on the partial set. It suspends, and
   * the engine rolls its partial claims back to Received (Processing -> Received
   * on any non-COMPLETE outcome) so nothing is consumed or lost. When the
   * remaining acks arrive and re-drive the branch, getSignals() re-reads the
   * full set and consumes every distinct ack exactly once at COMPLETE.
   */
  @isTest
  static void testCollectorWaitsForAllAcksAndRollsBackPartialClaims() {
    Id instanceId = WorkflowEngine.start(
      'ParallelSignalFanInWorkflowExample',
      'FanInPartialKey',
      null
    );

    // Suspend on Kick, then fan out with only ONE of the three acks present.
    new WorkflowOrchestrator(instanceId).execute(null);
    WorkflowEngine.signal('FanInPartialKey', 'Kick', '{}');
    WorkflowEngine.signal('FanInPartialKey', 'Ack:US', '{"ok":true}');
    new WorkflowOrchestrator(instanceId).execute(null);

    // First branch run sees a partial set (1 < 3) -> suspends, claims rolled back.
    new WorkflowOrchestrator(
        instanceId,
        'ParallelSignalFanInWorkflowExample.CollectorBranch'
      )
      .execute(null);

    System.assertEquals(
      0,
      [
        SELECT COUNT()
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Step_Name__c = 'ParallelSignalFanInWorkflowExample.CollectorBranch'
          AND Status__c = 'Completed'
      ],
      'Collector must not complete on a partial ack set'
    );
    System.assertEquals(
      'Received',
      [
        SELECT Status__c
        FROM Workflow_Signal__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Signal_Name__c = 'Ack:US'
        LIMIT 1
      ]
      .Status__c,
      'The partial ack claim must roll back to Received on suspend -- not stay Processing or be Consumed'
    );

    // The remaining acks arrive and re-drive the branch; now the set is complete.
    WorkflowEngine.signal('FanInPartialKey', 'Ack:EU', '{"ok":true}');
    WorkflowEngine.signal('FanInPartialKey', 'Ack:APAC', '{"ok":true}');
    new WorkflowOrchestrator(
        instanceId,
        'ParallelSignalFanInWorkflowExample.CollectorBranch'
      )
      .execute(null);

    Workflow_Step_Execution__c branchExec = [
      SELECT Output__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :instanceId
        AND Step_Name__c = 'ParallelSignalFanInWorkflowExample.CollectorBranch'
        AND Status__c = 'Completed'
    ];
    System.assert(
      branchExec.Output__c.contains('"count":3'),
      'Collector must complete with all 3 acks once they all arrive, got: ' +
      branchExec.Output__c
    );
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
      'All three acks must be consumed exactly once after the gated completion'
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
      'No ack may be left unclaimed or stuck claimed after the gated completion'
    );
  }

  /**
   * Fan-in gating must count distinct acks by their CANONICAL (case-folded) name.
   * A case-variant redelivery ('Ack:US' then 'ack:us') is the SAME logical ack,
   * so it must not inflate the gate: with two canonical names present the branch
   * must still suspend, not complete with a third expected name ('Ack:APAC')
   * missing. Once the final distinct name arrives the branch completes, reporting
   * three distinct names even though more physical rows were consumed.
   */
  @isTest
  static void testCollectorCountsAcksByCanonicalName() {
    Id instanceId = WorkflowEngine.start(
      'ParallelSignalFanInWorkflowExample',
      'FanInCaseKey',
      null
    );

    // Suspend on Kick, then fan out. Deliver TWO physical rows for one canonical
    // ack (different casing) plus one other ack: three rows, two canonical names.
    new WorkflowOrchestrator(instanceId).execute(null);
    WorkflowEngine.signal('FanInCaseKey', 'Kick', '{}');
    WorkflowEngine.signal('FanInCaseKey', 'Ack:US', '{"ok":true}');
    WorkflowEngine.signal('FanInCaseKey', 'ack:us', '{"ok":true}');
    WorkflowEngine.signal('FanInCaseKey', 'Ack:EU', '{"ok":true}');
    new WorkflowOrchestrator(instanceId).execute(null);

    // Two canonical names (2 < 3) must NOT satisfy the gate, even though three
    // physical rows are present -- the case-variant must collapse to one entry.
    new WorkflowOrchestrator(
        instanceId,
        'ParallelSignalFanInWorkflowExample.CollectorBranch'
      )
      .execute(null);
    System.assertEquals(
      0,
      [
        SELECT COUNT()
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Step_Name__c = 'ParallelSignalFanInWorkflowExample.CollectorBranch'
          AND Status__c = 'Completed'
      ],
      'A case-variant duplicate must not inflate the gate to a false complete'
    );
    System.assertEquals(
      0,
      [
        SELECT COUNT()
        FROM Workflow_Signal__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Signal_Name__c LIKE 'Ack:%'
          AND Status__c = 'Consumed'
      ],
      'No ack may be consumed while the canonical set is still incomplete'
    );

    // The final distinct ack arrives and re-drives the branch -> now complete.
    WorkflowEngine.signal('FanInCaseKey', 'Ack:APAC', '{"ok":true}');
    new WorkflowOrchestrator(
        instanceId,
        'ParallelSignalFanInWorkflowExample.CollectorBranch'
      )
      .execute(null);

    Workflow_Step_Execution__c branchExec = [
      SELECT Output__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :instanceId
        AND Step_Name__c = 'ParallelSignalFanInWorkflowExample.CollectorBranch'
        AND Status__c = 'Completed'
    ];
    System.assert(
      branchExec.Output__c.contains('"count":3'),
      'Collector must report THREE distinct canonical acks, not four physical rows, got: ' +
      branchExec.Output__c
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
      'Every ack row (including the case-variant duplicate) is consumed at the gated completion'
    );
  }
}
