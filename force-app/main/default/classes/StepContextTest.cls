@isTest
public class StepContextTest {
  @isTest
  static void testConstructorAndProperties() {
    Id dummyInstanceId = '00D000000000001EAA';
    StepContext ctx = new StepContext(
      dummyInstanceId,
      'TestWorkflow',
      'TestStep',
      '{"input": 1}',
      '{"prev": 2}',
      '{"state": 3}',
      '{"wfInput": 4}'
    );

    System.assertEquals(dummyInstanceId, ctx.workflowInstanceId);
    System.assertEquals('TestWorkflow', ctx.workflowName);
    System.assertEquals('TestStep', ctx.stepName);
    System.assertEquals('{"input": 1}', ctx.inputJson);
    System.assertEquals('{"prev": 2}', ctx.previousStepOutput);
    System.assertEquals('{"state": 3}', ctx.stepStateJson);
    System.assertEquals('{"wfInput": 4}', ctx.workflowInputJson);
    System.assertEquals(1, ctx.workflowVersion);
  }

  @isTest
  static void testConstructorWithVersion() {
    Id dummyInstanceId = '00D000000000001EAA';
    StepContext ctx = new StepContext(
      dummyInstanceId,
      'TestWorkflow',
      'TestStep',
      '{"input": 1}',
      '{"prev": 2}',
      '{"state": 3}',
      '{"wfInput": 4}',
      3
    );

    System.assertEquals(dummyInstanceId, ctx.workflowInstanceId);
    System.assertEquals('TestWorkflow', ctx.workflowName);
    System.assertEquals('TestStep', ctx.stepName);
    System.assertEquals('{"input": 1}', ctx.inputJson);
    System.assertEquals('{"prev": 2}', ctx.previousStepOutput);
    System.assertEquals('{"state": 3}', ctx.stepStateJson);
    System.assertEquals('{"wfInput": 4}', ctx.workflowInputJson);
    System.assertEquals(3, ctx.workflowVersion);
  }

  @isTest
  static void testShouldYieldNormalConditions() {
    Id dummyInstanceId = '00D000000000001EAA';
    StepContext ctx = new StepContext(
      dummyInstanceId,
      'TestWorkflow',
      'TestStep',
      null,
      null,
      null,
      null
    );

    // Under normal test execution conditions, limits should not be exceeded
    System.assertEquals(
      false,
      ctx.shouldYield(),
      'shouldYield should be false under normal conditions'
    );
  }

  @isTest
  static void testShouldYieldQueryRowsThresholdExceeded() {
    Id dummyInstanceId = '00D000000000001EAA';
    StepContext ctx = new StepContext(
      dummyInstanceId,
      'TestWorkflow',
      'TestStep',
      null,
      null,
      null,
      null
    );

    // Set mock to trigger SOQL query row limits checking logic
    StepContext.mockQueryRowsFraction = 0.81;
    System.assertEquals(
      true,
      ctx.shouldYield(),
      'shouldYield should return true when query rows exceed 80%'
    );

    StepContext.mockQueryRowsFraction = 0.80;
    System.assertEquals(
      false,
      ctx.shouldYield(),
      'shouldYield should return false when query rows are exactly 80%'
    );

    StepContext.mockQueryRowsFraction = 0.79;
    System.assertEquals(
      false,
      ctx.shouldYield(),
      'shouldYield should return false when query rows are below 80%'
    );
  }

  @isTest
  static void testShouldYieldAsyncApexExecutionsLimit() {
    Id dummyInstanceId = '00D000000000001EAA';
    StepContext ctx = new StepContext(
      dummyInstanceId,
      'TestWorkflow',
      'TestStep',
      null,
      null,
      null,
      null
    );

    // Set mock fraction above 80%
    StepContext.mockAsyncExecutionsFraction = 0.81;
    System.assertEquals(
      true,
      ctx.shouldYield(),
      'shouldYield should return true when async executions exceed 80%'
    );

    // Set mock fraction at 80%
    StepContext.mockAsyncExecutionsFraction = 0.80;
    System.assertEquals(
      false,
      ctx.shouldYield(),
      'shouldYield should return false when async executions are exactly 80%'
    );

    // Set mock fraction below 80%
    StepContext.mockAsyncExecutionsFraction = 0.79;
    System.assertEquals(
      false,
      ctx.shouldYield(),
      'shouldYield should return false when async executions are below 80%'
    );

    // Reset
    StepContext.mockAsyncExecutionsFraction = null;
  }

  // --- Inbound signal payload accessors (issue #11) ---

  @isTest
  static void testNoPendingSignalsReturnsCleanEmptyResult() {
    Id dummyInstanceId = '00D000000000001EAA';
    // Construct via the existing 8-arg constructor (no signals supplied).
    StepContext ctx = new StepContext(
      dummyInstanceId,
      'TestWorkflow',
      'TestStep',
      null,
      null,
      null,
      null,
      1
    );

    System.assertEquals(
      0,
      ctx.getSignals().size(),
      'getSignals() must return an empty (never null) list when none pending'
    );
    System.assertEquals(
      0,
      ctx.getSignals('Anything').size(),
      'getSignals(name) must return an empty list when none pending'
    );
    System.assertEquals(
      false,
      ctx.hasSignal('Anything'),
      'hasSignal must be false when none pending'
    );

    StepContext.Signal sig = ctx.getSignal('Anything');
    System.assertNotEquals(
      null,
      sig,
      'getSignal must never return null (clean empty result)'
    );
    System.assertEquals(
      false,
      sig.isPresent(),
      'Empty signal must report isPresent() == false'
    );
    System.assertEquals(
      null,
      sig.payload,
      'Empty signal payload must be null, not a null-deref hazard'
    );
  }

  @isTest
  static void testPendingSignalsExposedInArrivalOrder() {
    Id dummyInstanceId = '00D000000000001EAA';
    List<StepContext.Signal> pending = new List<StepContext.Signal>{
      new StepContext.Signal(null, 'First', '{"n":1}'),
      new StepContext.Signal(null, 'Second', '{"n":2}'),
      new StepContext.Signal(null, 'First', '{"n":3}')
    };
    StepContext ctx = new StepContext(
      dummyInstanceId,
      'TestWorkflow',
      'TestStep',
      null,
      null,
      null,
      null,
      1,
      pending
    );

    List<StepContext.Signal> all = ctx.getSignals();
    System.assertEquals(3, all.size(), 'All pending signals must be exposed');
    System.assertEquals('First', all[0].name);
    System.assertEquals('{"n":1}', all[0].payload);
    System.assertEquals('Second', all[1].name);
    System.assertEquals('First', all[2].name);
  }

  @isTest
  static void testGetSignalReturnsMostRecentMatchingName() {
    Id dummyInstanceId = '00D000000000001EAA';
    List<StepContext.Signal> pending = new List<StepContext.Signal>{
      new StepContext.Signal(null, 'Approval', '{"approved":true}'),
      new StepContext.Signal(null, 'Other', '{"x":1}'),
      new StepContext.Signal(null, 'Approval', '{"approved":false}')
    };
    StepContext ctx = new StepContext(
      dummyInstanceId,
      'TestWorkflow',
      'TestStep',
      null,
      null,
      null,
      null,
      1,
      pending
    );

    StepContext.Signal latest = ctx.getSignal('Approval');
    System.assertEquals(true, latest.isPresent());
    System.assertEquals(
      '{"approved":false}',
      latest.payload,
      'getSignal must return the most recent (last-arriving) signal of that name'
    );

    List<StepContext.Signal> approvals = ctx.getSignals('Approval');
    System.assertEquals(2, approvals.size());
    System.assertEquals(true, ctx.hasSignal('Approval'));
    System.assertEquals(false, ctx.hasSignal('Nope'));
  }

  @isTest
  static void testConsumedSignalIdsTracksObservedNamesOnly() {
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = 'X',
      Status__c = 'Running'
    );
    insert inst;

    Workflow_Signal__c sA = new Workflow_Signal__c(
      Workflow_Instance__c = inst.Id,
      Signal_Name__c = 'Approval',
      Payload__c = '{"approved":false}',
      Status__c = 'Received'
    );
    Workflow_Signal__c sB = new Workflow_Signal__c(
      Workflow_Instance__c = inst.Id,
      Signal_Name__c = 'Other',
      Payload__c = '{"x":1}',
      Status__c = 'Received'
    );
    insert new List<Workflow_Signal__c>{ sA, sB };

    List<StepContext.Signal> pending = new List<StepContext.Signal>{
      new StepContext.Signal(sA.Id, 'Approval', sA.Payload__c),
      new StepContext.Signal(sB.Id, 'Other', sB.Payload__c)
    };
    StepContext ctx = new StepContext(
      inst.Id,
      'X',
      'Step',
      null,
      null,
      null,
      null,
      1,
      pending
    );

    // Before observing anything, nothing is consumable.
    System.assertEquals(
      0,
      ctx.getConsumedSignalIds().size(),
      'Nothing is consumed until observed'
    );

    // Observe only the "Approval" name.
    ctx.getSignal('Approval');
    Set<Id> consumed = ctx.getConsumedSignalIds();
    System.assertEquals(
      1,
      consumed.size(),
      'Only observed signal names should be consumable'
    );
    System.assert(
      consumed.contains(sA.Id),
      'Observed Approval signal must be consumable'
    );
    System.assert(
      !consumed.contains(sB.Id),
      'Unobserved Other signal must NOT be consumed'
    );
  }

  @isTest
  static void testGetSignalsAllMarksEverythingObserved() {
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = 'X',
      Status__c = 'Running'
    );
    insert inst;

    Workflow_Signal__c sA = new Workflow_Signal__c(
      Workflow_Instance__c = inst.Id,
      Signal_Name__c = 'A',
      Payload__c = 'a',
      Status__c = 'Received'
    );
    Workflow_Signal__c sB = new Workflow_Signal__c(
      Workflow_Instance__c = inst.Id,
      Signal_Name__c = 'B',
      Payload__c = 'b',
      Status__c = 'Received'
    );
    insert new List<Workflow_Signal__c>{ sA, sB };

    List<StepContext.Signal> pending = new List<StepContext.Signal>{
      new StepContext.Signal(sA.Id, 'A', 'a'),
      new StepContext.Signal(sB.Id, 'B', 'b')
    };
    StepContext ctx = new StepContext(
      inst.Id,
      'X',
      'Step',
      null,
      null,
      null,
      null,
      1,
      pending
    );

    // Reading the full list observes every pending signal.
    ctx.getSignals();
    System.assertEquals(
      2,
      ctx.getConsumedSignalIds().size(),
      'getSignals() (all) must mark every pending signal observed'
    );
  }

  @isTest
  static void testBlankNamedLookupMatchesNothing() {
    Id dummyInstanceId = '00D000000000001EAA';
    List<StepContext.Signal> pending = new List<StepContext.Signal>{
      new StepContext.Signal(null, 'Real', '{"v":1}')
    };
    StepContext ctx = new StepContext(
      dummyInstanceId,
      'TestWorkflow',
      'TestStep',
      null,
      null,
      null,
      null,
      1,
      pending
    );

    // A blank/null name must never fall through to the unscoped (all) query and
    // must not mark unrelated signals observed/consumable.
    System.assertEquals(false, ctx.getSignal('').isPresent());
    System.assertEquals(false, ctx.getSignal(null).isPresent());
    System.assertEquals(false, ctx.hasSignal(''));
    System.assertEquals(0, ctx.getSignals('').size());
    System.assertEquals(
      0,
      ctx.getConsumedSignalIds().size(),
      'A blank named lookup must not mark any signal consumable'
    );
  }

  // A SignalSource test double whose named list read returns only the oldest
  // page (and reports capped/uncapped on demand), while getLatestSignal always
  // returns the true most-recent row -- mirroring a row-budget-truncated read.
  private class FakeNameSource implements StepContext.SignalSource {
    private final List<StepContext.Signal> page;
    private final StepContext.Signal trueLatest;
    private final Boolean capped;
    private FakeNameSource(
      List<StepContext.Signal> page,
      StepContext.Signal trueLatest,
      Boolean capped
    ) {
      this.page = page;
      this.trueLatest = trueLatest;
      this.capped = capped;
    }
    public List<StepContext.Signal> getPendingSignals(String signalName) {
      return page.clone();
    }
    public StepContext.Signal getLatestSignal(String signalName) {
      return trueLatest;
    }
    public Boolean readWasCapped() {
      return capped;
    }
  }

  @isTest
  static void testGetSignalUsesTrueLatestWhenListReadCapped() {
    Id dummyInstanceId = '00D000000000001EAA';
    // Oldest partial page for 'Evt' (budget-truncated); the true most-recent
    // 'Evt' row is NOT in this page.
    List<StepContext.Signal> oldestPage = new List<StepContext.Signal>{
      new StepContext.Signal(null, 'Evt', '{"seq":1}', DateTime.now().addMinutes(-5)),
      new StepContext.Signal(null, 'Evt', '{"seq":2}', DateTime.now().addMinutes(-4))
    };
    StepContext.Signal trueLatest = new StepContext.Signal(
      null,
      'Evt',
      '{"seq":99}',
      DateTime.now()
    );
    StepContext ctx = new StepContext(
      dummyInstanceId,
      'W',
      'S',
      null,
      null,
      null,
      null,
      1,
      (StepContext.SignalSource) new FakeNameSource(oldestPage, trueLatest, true)
    );

    // Read the (capped) list first; this populates the partial per-name cache.
    System.assertEquals(2, ctx.getSignals('Evt').size());

    // A subsequent latest lookup must NOT return the last row of the partial
    // page ({"seq":2}); it must reflect the true most-recent pending signal.
    StepContext.Signal latest = ctx.getSignal('Evt');
    System.assertEquals(true, latest.isPresent());
    System.assertEquals(
      '{"seq":99}',
      latest.payload,
      'getSignal after a capped getSignals must return the true latest, not the partial page tail'
    );
  }

  @isTest
  static void testGetSignalRecoversClaimedPageWhenSourceSeesNoneAfterCap() {
    Id dummyInstanceId = '00D000000000001EAA';
    // A capped page whose rows this branch already claimed (Processing); the
    // source now sees no still-Received rows of this name, so getLatestSignal
    // returns null. The branch still owns the rows, so getSignal must not report
    // a false absence (which would strand a suspend-on-absent branch).
    List<StepContext.Signal> claimedPage = new List<StepContext.Signal>{
      new StepContext.Signal(null, 'Foo', '{"seq":1}', DateTime.now().addMinutes(-2), true),
      new StepContext.Signal(null, 'Foo', '{"seq":2}', DateTime.now().addMinutes(-1), true)
    };
    StepContext ctx = new StepContext(
      dummyInstanceId,
      'W',
      'S',
      null,
      null,
      null,
      null,
      1,
      (StepContext.SignalSource) new FakeNameSource(claimedPage, null, true)
    );

    System.assertEquals(2, ctx.getSignals('Foo').size());

    StepContext.Signal latest = ctx.getSignal('Foo');
    System.assertEquals(
      true,
      latest.isPresent(),
      'A fully-claimed capped name must not be reported absent'
    );
    System.assertEquals(
      '{"seq":2}',
      latest.payload,
      'getSignal must recover the newest claimed row from the cached page'
    );
  }

  @isTest
  static void testGetSignalUsesListTailWhenListReadComplete() {
    Id dummyInstanceId = '00D000000000001EAA';
    // A complete (uncapped) list: its last element IS the true latest, so the
    // cached list is trusted and getLatestSignal must NOT override it.
    List<StepContext.Signal> fullList = new List<StepContext.Signal>{
      new StepContext.Signal(null, 'Evt', '{"seq":1}', DateTime.now().addMinutes(-2)),
      new StepContext.Signal(null, 'Evt', '{"seq":2}', DateTime.now().addMinutes(-1))
    };
    // trueLatest differs so a regression that always consults the source fails.
    StepContext.Signal sentinel = new StepContext.Signal(
      null,
      'Evt',
      '{"seq":99}',
      DateTime.now()
    );
    StepContext ctx = new StepContext(
      dummyInstanceId,
      'W',
      'S',
      null,
      null,
      null,
      null,
      1,
      (StepContext.SignalSource) new FakeNameSource(fullList, sentinel, false)
    );

    System.assertEquals(2, ctx.getSignals('Evt').size());
    StepContext.Signal latest = ctx.getSignal('Evt');
    System.assertEquals(
      '{"seq":2}',
      latest.payload,
      'getSignal after a complete getSignals must reuse the cached list tail, not re-query'
    );
  }

  @isTest
  static void testNamedLookupFallsThroughWhenFullListReadCapped() {
    Id dummyInstanceId = '00D000000000001EAA';
    // A capped unscoped read sees only a partial page (e.g. a Noise backlog)
    // that does NOT contain 'Important', while the source can still resolve the
    // true latest 'Important' row.
    List<StepContext.Signal> partialAll = new List<StepContext.Signal>{
      new StepContext.Signal(null, 'Noise', '{"n":1}', DateTime.now().addMinutes(-3)),
      new StepContext.Signal(null, 'Noise', '{"n":2}', DateTime.now().addMinutes(-2))
    };
    StepContext.Signal important = new StepContext.Signal(
      null,
      'Important',
      '{"go":true}',
      DateTime.now()
    );
    StepContext ctx = new StepContext(
      dummyInstanceId,
      'W',
      'S',
      null,
      null,
      null,
      null,
      1,
      (StepContext.SignalSource) new FakeNameSource(partialAll, important, true)
    );

    // Unscoped read caps and only sees the Noise page.
    System.assertEquals(2, ctx.getSignals().size());

    // A named latest lookup must NOT be answered from the partial full-list
    // cache (which would report 'Important' absent); it must reflect the true
    // pending signal so the step does not suspend and strand.
    System.assertEquals(
      true,
      ctx.hasSignal('Important'),
      'hasSignal after a capped full-list read must not falsely report absence'
    );
    System.assertEquals('{"go":true}', ctx.getSignal('Important').payload);
  }

  @isTest
  static void testCachedNamedLookupIsCaseInsensitive() {
    Id dummyInstanceId = '00D000000000001EAA';
    List<StepContext.Signal> pending = new List<StepContext.Signal>{
      new StepContext.Signal(null, 'Approve:Order', '{"ok":true}', DateTime.now())
    };
    StepContext ctx = new StepContext(
      dummyInstanceId,
      'W',
      'S',
      null,
      null,
      null,
      null,
      1,
      pending
    );

    // Load the full list first (in-memory allLoaded path), then probe the name
    // with different casing. The source SOQL and lower-cased caches match names
    // case-insensitively, so the in-memory path must too -- a case-only mismatch
    // must not make an already-delivered signal look absent.
    ctx.getSignals();
    System.assertEquals(
      true,
      ctx.hasSignal('approve:order'),
      'Cached named lookup must match case-insensitively'
    );
    System.assertEquals(
      '{"ok":true}',
      ctx.getSignal('APPROVE:ORDER').payload
    );
    System.assertEquals(1, ctx.getSignals('approve:ORDER').size());
  }

  // Simulates a parallel claiming source: a read 'claims' the rows it returns so
  // they leave the still-Received view, and a later read no longer sees them.
  // readWasCapped() is fixed true to model a budget-truncated read.
  private class ClaimingFakeSource implements StepContext.SignalSource {
    private final List<StepContext.Signal> allRows;
    private final Set<Id> claimed = new Set<Id>();
    private ClaimingFakeSource(List<StepContext.Signal> allRows) {
      this.allRows = allRows;
    }
    public List<StepContext.Signal> getPendingSignals(String signalName) {
      List<StepContext.Signal> out = new List<StepContext.Signal>();
      for (StepContext.Signal s : allRows) {
        if (claimed.contains(s.signalId)) {
          continue;
        }
        if (
          String.isBlank(signalName) ||
          (s.name != null && s.name.equalsIgnoreCase(signalName))
        ) {
          out.add(s);
          claimed.add(s.signalId); // claim on read, leaving the Received view
        }
      }
      return out;
    }
    public StepContext.Signal getLatestSignal(String signalName) {
      StepContext.Signal latest = null;
      for (StepContext.Signal s : allRows) {
        if (claimed.contains(s.signalId)) {
          continue;
        }
        if (s.name != null && s.name.equalsIgnoreCase(signalName)) {
          latest = s;
        }
      }
      return latest;
    }
    public Boolean readWasCapped() {
      return true;
    }
  }

  @isTest
  static void testNamedListIncludesClaimedRowsFromCappedFullRead() {
    Id dummyInstanceId = '00D000000000001EAA';
    String prefix = Workflow_Signal__c.SObjectType.getDescribe().getKeyPrefix();
    List<StepContext.Signal> allRows = new List<StepContext.Signal>{
      new StepContext.Signal(prefix + '000000000001', 'Foo', '{"f":1}', DateTime.now().addMinutes(-2)),
      new StepContext.Signal(prefix + '000000000002', 'Bar', '{"b":1}', DateTime.now().addMinutes(-1))
    };
    StepContext ctx = new StepContext(
      dummyInstanceId,
      'W',
      'S',
      null,
      null,
      null,
      null,
      1,
      (StepContext.SignalSource) new ClaimingFakeSource(allRows)
    );

    // Capped full read claims both rows and marks them for consumption.
    System.assertEquals(2, ctx.getSignals().size());

    // 'Foo' was claimed out of the Received view by the full read, but this
    // branch owns it and already marked it -- it must still appear in the named
    // list, or the step would consume it without ever handling the payload.
    List<StepContext.Signal> foos = ctx.getSignals('Foo');
    System.assertEquals(
      1,
      foos.size(),
      'A row claimed by a capped full read must remain in the named list'
    );
    System.assertEquals('{"f":1}', foos[0].payload);
  }

  @isTest
  static void testLatestMergeUsesIdTieBreakOnEqualTimestamp() {
    Id dummyInstanceId = '00D000000000001EAA';
    DateTime ts = DateTime.now();
    String prefix = Workflow_Signal__c.SObjectType.getDescribe().getKeyPrefix();
    // Capped page row (claimed) shares the timestamp with the source's latest
    // but has a LOWER id, so the source row is the true latest (Id DESC).
    List<StepContext.Signal> page = new List<StepContext.Signal>{
      new StepContext.Signal(prefix + '000000000002', 'Foo', '{"seq":2}', ts, true)
    };
    StepContext.Signal sourceLatest = new StepContext.Signal(
      prefix + '000000000003',
      'Foo',
      '{"seq":3}',
      ts,
      false
    );
    StepContext ctx = new StepContext(
      dummyInstanceId,
      'W',
      'S',
      null,
      null,
      null,
      null,
      1,
      (StepContext.SignalSource) new FakeNameSource(page, sourceLatest, true)
    );

    ctx.getSignals('Foo');
    StepContext.Signal latest = ctx.getSignal('Foo');
    System.assertEquals(
      '{"seq":3}',
      latest.payload,
      'On equal CreatedDate the higher-Id source row is the true latest, not the cached page row'
    );
  }
}
