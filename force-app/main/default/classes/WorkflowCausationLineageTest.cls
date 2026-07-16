/**
 * @description Direct unit tests for {@link WorkflowCausationLineage}. Each test
 * drives `WorkflowCausationLineage.getCausationLineage(Id)` against
 * purpose-built `Workflow_Instance__c` rows (no engine facade, no orchestration)
 * to exercise the ancestor-walk branches in isolation: the null/short-circuit
 * guards, the cycle and missing-row breaks, the hop ceiling, every
 * `resolveNextAncestorId` encoding (blank cause, direct id present/missing,
 * `key:`-scoped by correlation key, terminal else), and the multi-level
 * predecessor look-ahead in `getEarliestPredecessorCreatedDate`. The class under
 * test performs zero DML and reads WITH SYSTEM_MODE, so these tests assert purely
 * on the returned lineage projection. Fixtures are created under `System.runAs`
 * the current user so the walk runs in a realistic user context.
 */
@IsTest
private class WorkflowCausationLineageTest {
  /** @description Workflow definition name stamped on every fixture instance. */
  private static final String WF_NAME = 'WorkflowCausationLineageTest.Wf';

  /**
   * @description Returns the current running user, used to scope each test's
   * fixture creation and assertions inside a `System.runAs` block.
   * @return the current user
   */
  private static User currentUser() {
    return new User(Id = UserInfo.getUserId());
  }

  /**
   * @description Inserts a bare `Workflow_Instance__c` fixture with the required
   * developer name and status populated.
   * @param status the lifecycle status to stamp on the instance
   * @return the inserted instance
   */
  private static Workflow_Instance__c makeInstance(String status) {
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = WF_NAME,
      Status__c = status
    );
    insert inst;
    return inst;
  }

  /**
   * @description Produces a syntactically valid `Workflow_Instance__c` Id that
   * references no row, by inserting then deleting a throwaway instance. Used to
   * exercise the missing-row walk breaks without relying on an eager
   * describe/key-prefix lookup.
   * @return an Id of the Workflow_Instance__c type with no backing record
   */
  private static Id deletedInstanceId() {
    Workflow_Instance__c tmp = makeInstance('Running');
    Id id = tmp.Id;
    delete tmp;
    return id;
  }

  /**
   * @description A null instanceId short-circuits to an empty lineage before any
   * SOQL is issued.
   */
  @IsTest
  static void nullInstanceIdReturnsEmptyLineage() {
    System.runAs(currentUser()) {
      Test.startTest();
      List<WorkflowEngine.WorkflowStatus> lineage = WorkflowCausationLineage.getCausationLineage(
        null
      );
      Test.stopTest();

      System.assertEquals(
        0,
        lineage.size(),
        'A null instanceId must yield an empty lineage'
      );
    }
  }

  /**
   * @description A first-hop id that matches no row breaks the walk immediately
   * (the `inst == null` guard), yielding an empty lineage.
   */
  @IsTest
  static void missingFirstHopReturnsEmptyLineage() {
    System.runAs(currentUser()) {
      Id missingId = deletedInstanceId();

      Test.startTest();
      List<WorkflowEngine.WorkflowStatus> lineage = WorkflowCausationLineage.getCausationLineage(
        missingId
      );
      Test.stopTest();

      System.assertEquals(
        0,
        lineage.size(),
        'A missing first-hop row must break the walk to an empty lineage'
      );
    }
  }

  /**
   * @description A blank causation id falls back to `Parent_Instance__c`, and a
   * null parent then terminates the walk.
   */
  @IsTest
  static void blankCauseFollowsParentInstanceFallback() {
    System.runAs(currentUser()) {
      Workflow_Instance__c parent = makeInstance('Running');
      Workflow_Instance__c child = new Workflow_Instance__c(
        Workflow_Name__c = WF_NAME,
        Status__c = 'Running',
        Parent_Instance__c = parent.Id
      );
      insert child;

      Test.startTest();
      List<WorkflowEngine.WorkflowStatus> lineage = WorkflowCausationLineage.getCausationLineage(
        child.Id
      );
      Test.stopTest();

      System.assertEquals(
        2,
        lineage.size(),
        'Blank cause must walk child -> parent then stop at the null parent'
      );
      System.assertEquals(
        child.Id,
        lineage[0].instanceId,
        'Lineage must start at the requested instance'
      );
      System.assertEquals(
        parent.Id,
        lineage[1].instanceId,
        'Blank cause must resolve the Parent_Instance__c ancestor'
      );
    }
  }

  /**
   * @description A valid direct-id causation whose target row exists is followed;
   * a self-referential cause exercises the visited-id cycle guard, which breaks
   * the walk after the first (already-visited) revisit.
   */
  @IsTest
  static void validDirectIdPresentAndCycleGuard() {
    System.runAs(currentUser()) {
      Workflow_Instance__c inst = makeInstance('Running');
      inst.Causation_Id__c = inst.Id;
      update inst;

      Test.startTest();
      List<WorkflowEngine.WorkflowStatus> lineage = WorkflowCausationLineage.getCausationLineage(
        inst.Id
      );
      Test.stopTest();

      System.assertEquals(
        1,
        lineage.size(),
        'A self-referential valid direct id must be visited once then break on the cycle guard'
      );
      System.assertEquals(
        inst.Id,
        lineage[0].instanceId,
        'The single lineage entry must be the instance itself'
      );
    }
  }

  /**
   * @description A valid direct-id causation whose target row is missing resolves
   * to null, breaking the walk on the next iteration (the requested instance is
   * still returned).
   */
  @IsTest
  static void validDirectIdMissingTargetStopsWalk() {
    System.runAs(currentUser()) {
      Id missingId = deletedInstanceId();

      Workflow_Instance__c inst = makeInstance('Running');
      inst.Causation_Id__c = missingId;
      update inst;

      Test.startTest();
      List<WorkflowEngine.WorkflowStatus> lineage = WorkflowCausationLineage.getCausationLineage(
        inst.Id
      );
      Test.stopTest();

      System.assertEquals(
        1,
        lineage.size(),
        'A valid direct id whose target is missing must stop the walk after the origin'
      );
      System.assertEquals(
        inst.Id,
        lineage[0].instanceId,
        'The origin instance must still be projected'
      );
    }
  }

  /**
   * @description A `key:`-scoped JSON causation carrying an inline timestamp
   * resolves the parent by correlation key without a predecessor walk, when a
   * parent created at or before the inline timestamp exists.
   */
  @IsTest
  static void keyScopedJsonWithInlineTimestampResolvesParent() {
    System.runAs(currentUser()) {
      Workflow_Instance__c parent = new Workflow_Instance__c(
        Workflow_Name__c = WF_NAME,
        Status__c = 'Running',
        Correlation_Key__c = 'lineageKey'
      );
      insert parent;

      Long futureMs = System.now().addYears(1).getTime();
      Workflow_Instance__c child = new Workflow_Instance__c(
        Workflow_Name__c = WF_NAME,
        Status__c = 'Running',
        Causation_Id__c = 'key:{"k":"lineageKey","t":' + futureMs + '}'
      );
      insert child;

      Test.startTest();
      List<WorkflowEngine.WorkflowStatus> lineage = WorkflowCausationLineage.getCausationLineage(
        child.Id
      );
      Test.stopTest();

      System.assertEquals(
        2,
        lineage.size(),
        'A key-scoped cause must resolve child -> keyed parent'
      );
      System.assertEquals(
        parent.Id,
        lineage[1].instanceId,
        'The keyed parent must be the resolved ancestor'
      );
    }
  }

  /**
   * @description A `key:`-scoped causation with no inline timestamp forces the
   * `getEarliestPredecessorCreatedDate` fallback; when no instance carries the
   * correlation key, the parent query is empty and the walk terminates with only
   * the origin.
   */
  @IsTest
  static void keyScopedNoTimestampEmptyParentsStopsWalk() {
    System.runAs(currentUser()) {
      Workflow_Instance__c child = new Workflow_Instance__c(
        Workflow_Name__c = WF_NAME,
        Status__c = 'Running',
        Causation_Id__c = 'key:unmatchedKey'
      );
      insert child;

      Test.startTest();
      List<WorkflowEngine.WorkflowStatus> lineage = WorkflowCausationLineage.getCausationLineage(
        child.Id
      );
      Test.stopTest();

      System.assertEquals(
        1,
        lineage.size(),
        'An unmatched key-scoped cause must terminate with only the origin instance'
      );
      System.assertEquals(
        child.Id,
        lineage[0].instanceId,
        'The origin instance must be projected'
      );
    }
  }

  /**
   * @description A non-blank causation that is neither a valid id nor
   * `key:`-scoped hits the terminal `else`, resolving to null and stopping the
   * walk at the origin.
   */
  @IsTest
  static void unrecognizedCauseHitsTerminalElse() {
    System.runAs(currentUser()) {
      Workflow_Instance__c inst = makeInstance('Running');
      inst.Causation_Id__c = 'trace-not-an-id-nor-key';
      update inst;

      Test.startTest();
      List<WorkflowEngine.WorkflowStatus> lineage = WorkflowCausationLineage.getCausationLineage(
        inst.Id
      );
      Test.stopTest();

      System.assertEquals(
        1,
        lineage.size(),
        'An unrecognized causation encoding must stop the walk at the origin'
      );
    }
  }

  /**
   * @description A `key:`-scoped causation with no inline timestamp and a
   * multi-level `Previous_Instance__c` chain drives
   * `getEarliestPredecessorCreatedDate`: one predecessor query then the in-memory
   * look-ahead advances several levels before the chain-terminal early return.
   */
  @IsTest
  static void predecessorLookAheadWalksChain() {
    System.runAs(currentUser()) {
      // Deepest predecessor first so each Previous_Instance__c lookup is set at insert.
      Workflow_Instance__c p4 = makeInstance('Completed');
      Workflow_Instance__c p3 = new Workflow_Instance__c(
        Workflow_Name__c = WF_NAME,
        Status__c = 'Completed',
        Previous_Instance__c = p4.Id
      );
      insert p3;
      Workflow_Instance__c p2 = new Workflow_Instance__c(
        Workflow_Name__c = WF_NAME,
        Status__c = 'Completed',
        Previous_Instance__c = p3.Id
      );
      insert p2;
      Workflow_Instance__c p1 = new Workflow_Instance__c(
        Workflow_Name__c = WF_NAME,
        Status__c = 'Completed',
        Previous_Instance__c = p2.Id
      );
      insert p1;
      Workflow_Instance__c origin = new Workflow_Instance__c(
        Workflow_Name__c = WF_NAME,
        Status__c = 'Running',
        Causation_Id__c = 'key:chainKeyNoMatch',
        Previous_Instance__c = p1.Id
      );
      insert origin;

      Test.startTest();
      List<WorkflowEngine.WorkflowStatus> lineage = WorkflowCausationLineage.getCausationLineage(
        origin.Id
      );
      Test.stopTest();

      // The correlation key matches no instance, so after the predecessor look-ahead
      // the parent query is empty and the walk stops at the origin.
      System.assertEquals(
        1,
        lineage.size(),
        'The predecessor look-ahead must run then terminate with only the origin'
      );
      System.assertEquals(
        origin.Id,
        lineage[0].instanceId,
        'The origin instance must be projected'
      );
    }
  }

  /**
   * @description A parent chain longer than the 12-hop ceiling is truncated: the
   * walk collects exactly maxHops ancestors even though the chain is deeper.
   */
  @IsTest
  static void parentChainTruncatesAtMaxHops() {
    System.runAs(currentUser()) {
      Integer chainLength = 14;
      List<Workflow_Instance__c> chain = new List<Workflow_Instance__c>();
      for (Integer i = 0; i < chainLength; i++) {
        chain.add(
          new Workflow_Instance__c(
            Workflow_Name__c = WF_NAME,
            Status__c = 'Running'
          )
        );
      }
      insert chain;

      // Wire child -> parent so index 0 is the deepest child and the last index is
      // the root (blank causation -> Parent_Instance__c fallback each hop).
      for (Integer i = 0; i < chainLength - 1; i++) {
        chain[i].Parent_Instance__c = chain[i + 1].Id;
      }
      update chain;

      Test.startTest();
      List<WorkflowEngine.WorkflowStatus> lineage = WorkflowCausationLineage.getCausationLineage(
        chain[0].Id
      );
      Test.stopTest();

      System.assertEquals(
        12,
        lineage.size(),
        'The walk must truncate at the 12-hop ceiling despite a deeper chain'
      );
      System.assertEquals(
        chain[0].Id,
        lineage[0].instanceId,
        'Truncated lineage must still start at the requested instance'
      );
      System.assertEquals(
        chain[11].Id,
        lineage[11].instanceId,
        'The last collected ancestor must be the 12th hop of the chain'
      );
    }
  }
}
