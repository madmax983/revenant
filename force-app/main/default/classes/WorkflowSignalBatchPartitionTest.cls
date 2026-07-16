/**
 * @description Unit tests for {@link WorkflowSignalBatchPartition}, driving the public
 * partitionForwardSignals phase directly with crafted request lists and a hand-built
 * {@link WorkflowSignalBatch.SignalInstanceMaps} cache. Covers the null-request skip,
 * the unmatched (inst == null) skip, the in-batch cancelled-sibling skip, the
 * CompensationFailed non-cancel skip, the keyed-cancel early return, the unkeyed-cancel
 * path that drives an instance terminal and records it in cancelledInstanceIds, the
 * in-batch keyed-signal dedup, and the wakeable vs non-wakeable staging.
 */
@IsTest
public class WorkflowSignalBatchPartitionTest {
  private static final String SIG_WF = 'WorkflowSignalBatchPartitionTest.SigWorkflow';

  /**
   * @description Fixture workflow definition so a cancelled instance carries a
   * resolvable Workflow_Name__c.
   */
  public class SigWorkflow implements WorkflowDefinition {
    /**
     * @description Declares the single fixture step.
     * @return The one-element list of step names.
     */
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowSignalBatchPartitionTest.SigStep' };
    }
    /**
     * @description Names the entry step.
     * @return The initial step name.
     */
    public String getInitialStep() {
      return 'WorkflowSignalBatchPartitionTest.SigStep';
    }
    /**
     * @description Terminates after the single step.
     * @param currentStepName The step that just completed.
     * @param stepResult The result of the completed step.
     * @return Always null, marking the workflow complete.
     */
    public String getNextStep(String currentStepName, StepResult stepResult) {
      return null;
    }
  }

  private static Workflow_Instance__c makeInst(String key, String status) {
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = SIG_WF,
      Correlation_Key__c = key,
      Status__c = status,
      Current_Step__c = 'WorkflowSignalBatchPartitionTest.SigStep'
    );
    insert inst;
    return inst;
  }

  private static WorkflowSignalBatch.SignalInstanceMaps mapsFor(
    List<Workflow_Instance__c> insts
  ) {
    WorkflowSignalBatch.SignalInstanceMaps maps = new WorkflowSignalBatch.SignalInstanceMaps();
    for (Workflow_Instance__c inst : insts) {
      maps.instById.put(String.valueOf(inst.Id), inst);
      if (String.isNotBlank(inst.Correlation_Key__c)) {
        maps.instByKey.put(
          WorkflowKeys.normalizeKey(inst.Correlation_Key__c),
          inst
        );
      }
    }
    return maps;
  }

  private static WorkflowEngine.SignalRequest req(
    String keyOrId,
    String signalName,
    String payload
  ) {
    return new WorkflowEngine.SignalRequest(keyOrId, signalName, payload);
  }

  @IsTest
  static void testNullAndUnmatchedRequestsSkipped() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = makeInst('sig-ok', 'Suspended');
      WorkflowSignalBatch.SignalInstanceMaps maps = mapsFor(
        new List<Workflow_Instance__c>{ inst }
      );

      List<WorkflowEngine.SignalRequest> requests = new List<WorkflowEngine.SignalRequest>{
        null, // null-request skip
        req('nonexistent-key', 'Go', null), // resolves to null instance
        req('sig-ok', 'Go', null)
      };

      WorkflowSignalBatchPartition.ForwardSignalPartition part = WorkflowSignalBatchPartition.partitionForwardSignals(
        requests,
        maps,
        new Set<Id>()
      );

      System.assertEquals(
        1,
        part.unkeyedSignals.size(),
        'Only the matched request stages a signal row'
      );
      System.assertEquals(
        1,
        part.signalsByInstanceId.size(),
        'Only the matched instance records a signal name'
      );
      System.assert(
        part.signalsByInstanceId.containsKey(inst.Id),
        'The matched instance is recorded'
      );
    }
  }

  @IsTest
  static void testCancelledSiblingSkipped() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = makeInst('sig-cancelled', 'Suspended');
      WorkflowSignalBatch.SignalInstanceMaps maps = mapsFor(
        new List<Workflow_Instance__c>{ inst }
      );

      WorkflowSignalBatchPartition.ForwardSignalPartition part = WorkflowSignalBatchPartition.partitionForwardSignals(
        new List<WorkflowEngine.SignalRequest>{
          req('sig-cancelled', 'Go', null)
        },
        maps,
        new Set<Id>{ inst.Id } // already driven terminal by a prior in-batch cancel
      );

      System.assert(
        part.signalsByInstanceId.containsKey(inst.Id),
        'The signal name is recorded before the cancelled-sibling skip'
      );
      System.assert(
        part.unkeyedSignals.isEmpty(),
        'A sibling of a cancelled instance stages no row'
      );
    }
  }

  @IsTest
  static void testCompensationFailedNonCancelSkipped() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = makeInst('sig-cf', 'CompensationFailed');
      WorkflowSignalBatch.SignalInstanceMaps maps = mapsFor(
        new List<Workflow_Instance__c>{ inst }
      );

      WorkflowSignalBatchPartition.ForwardSignalPartition part = WorkflowSignalBatchPartition.partitionForwardSignals(
        new List<WorkflowEngine.SignalRequest>{ req('sig-cf', 'Go', null) },
        maps,
        new Set<Id>()
      );

      System.assert(
        part.unkeyedSignals.isEmpty(),
        'A non-cancel signal to a CompensationFailed instance is skipped'
      );
      System.assert(
        part.keyedSignals.isEmpty(),
        'No keyed row is staged either'
      );
    }
  }

  @IsTest
  static void testKeyedCancelEarlyReturn() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = makeInst('sig-kc', 'Suspended');
      WorkflowSignalBatch.SignalInstanceMaps maps = mapsFor(
        new List<Workflow_Instance__c>{ inst }
      );

      WorkflowEngine.SignalRequest keyedCancel = req('sig-kc', 'Cancel', null)
        .withIdempotencyKey('idem-1');

      WorkflowSignalBatchPartition.ForwardSignalPartition part = WorkflowSignalBatchPartition.partitionForwardSignals(
        new List<WorkflowEngine.SignalRequest>{ keyedCancel },
        maps,
        new Set<Id>()
      );

      System.assert(
        part.unkeyedSignals.isEmpty() && part.keyedSignals.isEmpty(),
        'A keyed cancel is deferred to the pre-pass and stages nothing here'
      );
      System.assertEquals(
        'Suspended',
        [SELECT Status__c FROM Workflow_Instance__c WHERE Id = :inst.Id]
        .Status__c,
        'A keyed cancel does not cancel the instance in this phase'
      );
    }
  }

  @IsTest
  static void testUnkeyedCancelDrivesTerminalAndRecordsCancelled() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c inst = makeInst('sig-uc', 'Suspended');
      WorkflowSignalBatch.SignalInstanceMaps maps = mapsFor(
        new List<Workflow_Instance__c>{ inst }
      );
      Set<Id> cancelledInstanceIds = new Set<Id>();

      Test.startTest();
      WorkflowSignalBatchPartition.ForwardSignalPartition part = WorkflowSignalBatchPartition.partitionForwardSignals(
        new List<WorkflowEngine.SignalRequest>{
          req('sig-uc', 'Cancel', '{"runCompensations":false}')
        },
        maps,
        cancelledInstanceIds
      );
      Test.stopTest();

      System.assert(
        part.cancelledInstanceIds.contains(inst.Id),
        'The unkeyed cancel drove the instance terminal and recorded it'
      );
      System.assertEquals(
        'Cancelled',
        [SELECT Status__c FROM Workflow_Instance__c WHERE Id = :inst.Id]
        .Status__c,
        'The instance was cancelled'
      );
      System.assert(
        part.unkeyedSignals.isEmpty(),
        'A cancel stages no forward signal row'
      );
    }
  }

  @IsTest
  static void testKeyedSignalInBatchDedup() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = makeInst('sig-dedup', 'Suspended');
      WorkflowSignalBatch.SignalInstanceMaps maps = mapsFor(
        new List<Workflow_Instance__c>{ inst }
      );

      List<WorkflowEngine.SignalRequest> requests = new List<WorkflowEngine.SignalRequest>{
        req('sig-dedup', 'Approve', 'p1').withIdempotencyKey('k1'),
        req('sig-dedup', 'Approve', 'p2').withIdempotencyKey('k1') // duplicate key
      };

      WorkflowSignalBatchPartition.ForwardSignalPartition part = WorkflowSignalBatchPartition.partitionForwardSignals(
        requests,
        maps,
        new Set<Id>()
      );

      System.assertEquals(
        1,
        part.keyedSignals.size(),
        'The in-batch duplicate composite key is deduped to a single row'
      );
      System.assertEquals(
        1,
        part.seenCompositeKeys.size(),
        'Only one composite key is recorded'
      );
    }
  }

  @IsTest
  static void testWakeableVsNonWakeableStaging() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c wakeInst = makeInst('sig-wake', 'Running');
      Workflow_Instance__c pendInst = makeInst('sig-pend', 'Pending');
      WorkflowSignalBatch.SignalInstanceMaps maps = mapsFor(
        new List<Workflow_Instance__c>{ wakeInst, pendInst }
      );

      List<WorkflowEngine.SignalRequest> requests = new List<WorkflowEngine.SignalRequest>{
        req('sig-wake', 'Go', null),
        req('sig-pend', 'Go', null)
      };

      WorkflowSignalBatchPartition.ForwardSignalPartition part = WorkflowSignalBatchPartition.partitionForwardSignals(
        requests,
        maps,
        new Set<Id>()
      );

      System.assertEquals(
        2,
        part.unkeyedSignals.size(),
        'Both unkeyed signals stage a row (at-least-once)'
      );
      System.assert(
        part.instancesWithUnkeyedSignal.contains(wakeInst.Id),
        'A wakeable (Running) instance is marked wakeable'
      );
      System.assert(
        !part.instancesWithUnkeyedSignal.contains(pendInst.Id),
        'A non-wakeable (Pending) instance is not marked wakeable'
      );
      System.assert(
        part.activeInstById.containsKey(wakeInst.Id),
        'The wakeable instance is cached for the wake phase'
      );
      System.assert(
        !part.activeInstById.containsKey(pendInst.Id),
        'The non-wakeable instance is not cached for the wake phase'
      );
    }
  }
}
