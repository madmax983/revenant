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
      new StepContext.Signal(
        null,
        'Evt',
        '{"seq":1}',
        DateTime.now().addMinutes(-5)
      ),
      new StepContext.Signal(
        null,
        'Evt',
        '{"seq":2}',
        DateTime.now().addMinutes(-4)
      )
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
      (StepContext.SignalSource) new FakeNameSource(
        oldestPage,
        trueLatest,
        true
      )
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
      new StepContext.Signal(
        null,
        'Foo',
        '{"seq":1}',
        DateTime.now().addMinutes(-2),
        true
      ),
      new StepContext.Signal(
        null,
        'Foo',
        '{"seq":2}',
        DateTime.now().addMinutes(-1),
        true
      )
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
      new StepContext.Signal(
        null,
        'Evt',
        '{"seq":1}',
        DateTime.now().addMinutes(-2)
      ),
      new StepContext.Signal(
        null,
        'Evt',
        '{"seq":2}',
        DateTime.now().addMinutes(-1)
      )
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
      new StepContext.Signal(
        null,
        'Noise',
        '{"n":1}',
        DateTime.now().addMinutes(-3)
      ),
      new StepContext.Signal(
        null,
        'Noise',
        '{"n":2}',
        DateTime.now().addMinutes(-2)
      )
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
      new StepContext.Signal(
        null,
        'Approve:Order',
        '{"ok":true}',
        DateTime.now()
      )
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
    System.assertEquals('{"ok":true}', ctx.getSignal('APPROVE:ORDER').payload);
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
    String prefix = Workflow_Signal__c.SObjectType.getDescribe(
        SObjectDescribeOptions.DEFERRED
      )
      .getKeyPrefix();
    List<StepContext.Signal> allRows = new List<StepContext.Signal>{
      new StepContext.Signal(
        prefix + '000000000001',
        'Foo',
        '{"f":1}',
        DateTime.now().addMinutes(-2)
      ),
      new StepContext.Signal(
        prefix + '000000000002',
        'Bar',
        '{"b":1}',
        DateTime.now().addMinutes(-1)
      )
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
    String prefix = Workflow_Signal__c.SObjectType.getDescribe(
        SObjectDescribeOptions.DEFERRED
      )
      .getKeyPrefix();
    // Capped page row (claimed) shares the timestamp with the source's latest
    // but has a LOWER id, so the source row is the true latest (Id DESC).
    List<StepContext.Signal> page = new List<StepContext.Signal>{
      new StepContext.Signal(
        prefix + '000000000002',
        'Foo',
        '{"seq":2}',
        ts,
        true
      )
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

  // ---------------------------------------------------------------------------
  // Idempotency key (issue #2)
  // ---------------------------------------------------------------------------

  @isTest
  static void testIdempotencyKeyIsNonBlankAndStableAcrossAttempts() {
    // Two contexts for the SAME logical (instance, step) but representing
    // different attempts: different previous output, step state, workflow
    // input, and even workflow version. A transient RetryPolicy retry, an
    // operator re-drive (#1), and an at-least-once Workflow_Event__e resume all
    // re-build a context like this -> the key must be identical every time.
    Id instanceId = '00D000000000001';
    StepContext attemptA = new StepContext(
      instanceId,
      'WF',
      'StepA',
      '{"input":1}',
      null,
      null,
      '{"wf":1}'
    );
    StepContext attemptB = new StepContext(
      instanceId,
      'WF',
      'StepA',
      '{"input":1}',
      '{"prev":"changed"}',
      '{"state":"changed"}',
      '{"wf":1}',
      9
    );

    System.assert(
      String.isNotBlank(attemptA.idempotencyKey),
      'idempotencyKey must be exposed and non-blank inside execute()'
    );
    System.assertEquals(
      attemptA.idempotencyKey,
      attemptB.idempotencyKey,
      'idempotencyKey must be stable across retries/re-drives of the same logical (instance, step)'
    );
  }

  @isTest
  static void testIdempotencyKeyDistinctPerStep() {
    Id instanceId = '00D000000000001';
    StepContext stepA = new StepContext(
      instanceId,
      'WF',
      'StepA',
      null,
      null,
      null,
      null
    );
    StepContext stepB = new StepContext(
      instanceId,
      'WF',
      'StepB',
      null,
      null,
      null,
      null
    );
    System.assertNotEquals(
      stepA.idempotencyKey,
      stepB.idempotencyKey,
      'Two different steps in one instance must observe different keys'
    );
  }

  @isTest
  static void testIdempotencyKeyDistinctPerInstance() {
    // The same step name across two different instances (e.g. two parallel
    // fan-out branch instances with different Parent_Instance__c, or the same
    // step in two separate runs) must observe different keys.
    StepContext branchOne = new StepContext(
      '00D000000000001',
      'WF',
      'StepA',
      null,
      null,
      null,
      null
    );
    StepContext branchTwo = new StepContext(
      '00D000000000002',
      'WF',
      'StepA',
      null,
      null,
      null,
      null
    );
    System.assertNotEquals(
      branchOne.idempotencyKey,
      branchTwo.idempotencyKey,
      'The same step in two different instances must observe different keys'
    );
  }

  @isTest
  static void testIdempotencyKeyCompensateDistinctAndStable() {
    // The engine builds a compensate() context with stepName "<step>_Compensate"
    // (see WorkflowEngine.runCompensationStep). So the compensation key is
    // distinct from the forward execution key yet stable across compensation
    // retries.
    Id instanceId = '00D000000000001';
    StepContext forward = new StepContext(
      instanceId,
      'WF',
      'ChargeStep',
      null,
      null,
      null,
      null
    );
    StepContext compensate = new StepContext(
      instanceId,
      'WF',
      'ChargeStep_Compensate',
      null,
      null,
      null,
      null
    );
    StepContext compensateRetry = new StepContext(
      instanceId,
      'WF',
      'ChargeStep_Compensate',
      '{"different":"state"}',
      null,
      null,
      null
    );

    System.assertNotEquals(
      forward.idempotencyKey,
      compensate.idempotencyKey,
      'compensate() must observe a key distinct from the forward execution key'
    );
    System.assertEquals(
      compensate.idempotencyKey,
      compensateRetry.idempotencyKey,
      'compensate() key must be stable across compensation retries'
    );
  }

  @isTest
  static void testIdempotencyKeyDistinctPerVisit() {
    // When a workflow loops back to the same step in the same instance, each
    // completed visit must observe a different key so distinct side effects are
    // not wrongly deduped; the engine supplies an incrementing visit sequence.
    Id instanceId = '00D000000000001';
    StepContext visitZero = new StepContext(
      instanceId,
      'WF',
      'PollStep',
      null,
      null,
      null,
      null,
      1,
      0
    );
    StepContext visitOne = new StepContext(
      instanceId,
      'WF',
      'PollStep',
      null,
      null,
      null,
      null,
      1,
      1
    );
    // A retry/re-drive/resume of the SAME visit rebuilds the context with the
    // same visit sequence even though other state differs.
    StepContext visitOneRetry = new StepContext(
      instanceId,
      'WF',
      'PollStep',
      '{"changed":true}',
      null,
      null,
      null,
      1,
      1
    );

    System.assertNotEquals(
      visitZero.idempotencyKey,
      visitOne.idempotencyKey,
      'Two different completed visits of the same step must observe different keys'
    );
    System.assertEquals(
      visitOne.idempotencyKey,
      visitOneRetry.idempotencyKey,
      'Retries/re-drives of the same visit must observe the identical key'
    );
  }

  @isTest
  static void testIdempotencyKeyDefaultVisitMatchesExplicitZero() {
    // The additive visit param defaults to 0, so the 8-arg constructor and the
    // 9-arg constructor with stepVisit=0 must yield the identical key.
    Id instanceId = '00D000000000001';
    StepContext defaulted = new StepContext(
      instanceId,
      'WF',
      'StepA',
      null,
      null,
      null,
      null,
      1
    );
    StepContext explicitZero = new StepContext(
      instanceId,
      'WF',
      'StepA',
      null,
      null,
      null,
      null,
      1,
      0
    );
    System.assertEquals(
      defaulted.idempotencyKey,
      explicitZero.idempotencyKey,
      'Default visit (0) must match an explicit stepVisit of 0'
    );
  }

  @isTest
  static void testPreviousRunAtNullByDefault() {
    StepContext ctx = new StepContext(
      '00D000000000001',
      'WF',
      'StepA',
      null,
      null,
      null,
      null,
      1
    );
    System.assertNotEquals(null, ctx, 'Context should be constructed');
    System.assertEquals(
      null,
      ctx.previousRunAt,
      'Non-continuation context must have null previousRunAt'
    );
  }

  @isTest
  static void testPreviousRunAtSetViaFullConstructor() {
    Datetime ts = Datetime.now().addMinutes(-5);
    StepContext ctx = new StepContext(
      '00D000000000001',
      'WF',
      'StepA',
      null,
      null,
      null,
      null,
      1,
      0,
      null,
      ts
    );
    System.assertEquals(
      ts,
      ctx.previousRunAt,
      'previousRunAt should match the value passed to the full constructor'
    );
  }

  // ---------------------------------------------------------------------------
  // capture-once / once() (issue #44)
  // ---------------------------------------------------------------------------

  private class StringProducer implements CaptureProducer {
    public String value;
    public Integer callCount = 0;
    public StringProducer(String value) {
      this.value = value;
    }
    public Object produce() {
      callCount++;
      return value;
    }
  }

  @isTest
  static void testOnceFirstCallInvokesProducerAndReturnsValue() {
    Id instanceId = '00D000000000001EAA';
    StepContext ctx = new StepContext(
      instanceId,
      'WF',
      'StepA',
      null,
      null,
      null,
      null
    );
    StringProducer p = new StringProducer('hello');
    Object result = ctx.once('myKey', p);
    System.assertEquals(
      'hello',
      result,
      'once() must return the produced value on first call'
    );
    System.assertEquals(
      1,
      p.callCount,
      'Producer must be called exactly once on first access'
    );
  }

  @isTest
  static void testOnceSecondCallReturnsSameValueWithoutCallingProducer() {
    Id instanceId = '00D000000000001EAA';
    StepContext ctx = new StepContext(
      instanceId,
      'WF',
      'StepA',
      null,
      null,
      null,
      null
    );
    StringProducer p = new StringProducer('stable');
    ctx.once('k', p);
    Object second = ctx.once('k', p);
    System.assertEquals(
      'stable',
      second,
      'once() must return the same value on subsequent calls'
    );
    System.assertEquals(
      1,
      p.callCount,
      'Producer must NOT be called again after the first capture'
    );
  }

  @isTest
  static void testOnceDistinctKeysAreIndependent() {
    Id instanceId = '00D000000000001EAA';
    StepContext ctx = new StepContext(
      instanceId,
      'WF',
      'StepA',
      null,
      null,
      null,
      null
    );
    StringProducer pA = new StringProducer('alpha');
    StringProducer pB = new StringProducer('beta');
    Object a = ctx.once('keyA', pA);
    Object b = ctx.once('keyB', pB);
    System.assertEquals('alpha', a);
    System.assertEquals('beta', b);
    System.assertEquals(1, pA.callCount);
    System.assertEquals(1, pB.callCount);
  }

  @isTest
  static void testOnceWithPriorCapturesSkipsProducer() {
    Id instanceId = '00D000000000001EAA';
    // Seed a prior-capture JSON as if loaded from Workflow_Step_Execution__c.Captured_Values__c
    String priorJson = JSON.serialize(
      new Map<String, Object>{ 'refNumber' => 'REF-001' }
    );
    StepContext ctx = StepContext.withCapturedValues(
      instanceId,
      'WF',
      'StepA',
      null,
      null,
      null,
      null,
      1,
      0,
      null,
      null,
      priorJson
    );
    StringProducer p = new StringProducer('SHOULD-NOT-BE-CALLED');
    Object result = ctx.once('refNumber', p);
    System.assertEquals(
      'REF-001',
      result,
      'once() must return the durably stored value, not a new one'
    );
    System.assertEquals(
      0,
      p.callCount,
      'Producer must NOT be called when the key was already captured'
    );
  }

  @isTest
  static void testGetCapturedValuesJsonRoundTrips() {
    Id instanceId = '00D000000000001EAA';
    StepContext ctx = new StepContext(
      instanceId,
      'WF',
      'StepA',
      null,
      null,
      null,
      null
    );
    ctx.once('k1', new StringProducer('v1'));
    ctx.once('k2', new StringProducer('v2'));
    String capturedJson = ctx.getCapturedValuesJson();
    Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(
      capturedJson
    );
    System.assertEquals('v1', parsed.get('k1'));
    System.assertEquals('v2', parsed.get('k2'));
  }

  @isTest
  static void testGetCapturedValuesJsonNullWhenNoCaptures() {
    Id instanceId = '00D000000000001EAA';
    StepContext ctx = new StepContext(
      instanceId,
      'WF',
      'StepA',
      null,
      null,
      null,
      null
    );
    System.assertEquals(
      null,
      ctx.getCapturedValuesJson(),
      'getCapturedValuesJson() must return null when nothing was captured'
    );
  }

  @isTest
  static void testOnceValuesAreJsonRoundTripped() {
    // Numbers and booleans JSON-round-trip to a consistent type so values are
    // byte-identical regardless of whether they come from in-memory or rehydrated.
    Id instanceId = '00D000000000001EAA';
    StepContext ctx = new StepContext(
      instanceId,
      'WF',
      'StepA',
      null,
      null,
      null,
      null
    );
    ctx.once('num', new StringProducer('42'));
    String captured = ctx.getCapturedValuesJson();
    // Rehydrate into a new context
    StepContext ctx2 = StepContext.withCapturedValues(
      instanceId,
      'WF',
      'StepA',
      null,
      null,
      null,
      null,
      1,
      0,
      null,
      null,
      captured
    );
    StringProducer p2 = new StringProducer('different');
    Object v = ctx2.once('num', p2);
    System.assertEquals(
      '42',
      v,
      'Rehydrated value must match the originally captured value'
    );
    System.assertEquals(
      0,
      p2.callCount,
      'Producer must not be called on rehydration'
    );
  }

  @isTest
  static void testExposedRetryPropertiesAndDefaults() {
    Id instanceId = '00D000000000001EAA';
    StepContext ctx = new StepContext(
      instanceId,
      'WF',
      'StepA',
      null,
      null,
      null,
      null
    );
    System.assertEquals(1, ctx.attempt, 'Default attempt should be 1');
    System.assertEquals(1, ctx.maxAttempts, 'Default maxAttempts should be 1');
    System.assert(ctx.isFinalAttempt(), 'Default context should be final attempt');
  }

  @isTest
  static void testExposedRetryPropertiesOverloads() {
    Id instanceId = '00D000000000001EAA';
    StepContext ctx = StepContext.withCapturedValues(
      instanceId,
      'WF',
      'StepA',
      null,
      null,
      null,
      null,
      1,
      0,
      null,
      null,
      null,
      2,
      5
    );
    System.assertEquals(2, ctx.attempt);
    System.assertEquals(5, ctx.maxAttempts);
    System.assert(!ctx.isFinalAttempt());
  }

  @isTest
  static void testExposedRetryPropertiesFromCapturedValues() {
    Id instanceId = '00D000000000001EAA';
    String priorJson = JSON.serialize(
      new Map<String, Object>{ 'refNumber' => 'REF-001', '__maxAttempts' => 3 }
    );
    StepContext ctx = StepContext.withCapturedValues(
      instanceId,
      'WF',
      'StepA',
      null,
      null,
      null,
      null,
      1,
      0,
      null,
      null,
      priorJson
    );
    System.assertEquals(1, ctx.attempt);
    System.assertEquals(3, ctx.maxAttempts);
    System.assert(!ctx.isFinalAttempt());
    // Verify that '__maxAttempts' was stripped from the in-memory captured values map (so a once() check executes the producer)
    System.assertEquals(5, Integer.valueOf(ctx.once('__maxAttempts', new ObjectProducer(5))), 'Should strip __maxAttempts from in-memory captured values');
  }

  @isTest
  static void testExposedRetryPropertiesStatePreservationOnYield() {
    Id instanceId = '00D000000000001EAA';
    String priorJson = JSON.serialize(
      new Map<String, Object>{ 'refNumber' => 'REF-001', '__maxAttempts' => 3 }
    );
    // Hydrate
    StepContext ctx = StepContext.withCapturedValues(
      instanceId,
      'WF',
      'StepA',
      null,
      null,
      null,
      null,
      1,
      0,
      null,
      null,
      priorJson,
      1, // attempt
      3  // maxAttempts
    );
    System.assertEquals(3, ctx.maxAttempts);
    
    // Simulate step execution yielding and capturing a new value
    ctx.once('newValue', new ObjectProducer('val'));
    System.assert(ctx.hasNewCaptures());
    
    // Get serialized JSON to write back to db
    String outputJson = ctx.getCapturedValuesJson();
    System.assert(outputJson.contains('newValue'));
    System.assert(outputJson.contains('REF-001'));
    System.assert(outputJson.contains('__maxAttempts')); // MUST contain max attempts!
    
    // De-serialize and verify
    Map<String, Object> deserialized = (Map<String, Object>) JSON.deserializeUntyped(outputJson);
    System.assertEquals(3, Integer.valueOf(deserialized.get('__maxAttempts')));
  }

  @isTest
  static void testRetryRobustnessDecimalAndMalformedJson() {
    Id instanceId = '00D000000000001EAA';
    
    // 1. Double/Decimal value parsed from JSON
    String decimalJson = '{"__maxAttempts":3.0}';
    StepContext ctx = StepContext.withCapturedValues(
      instanceId,
      'WF',
      'StepA',
      null,
      null,
      null,
      null,
      1,
      0,
      null,
      null,
      decimalJson
    );
    System.assertEquals(3, ctx.maxAttempts, 'Should parse double/decimal attempts safely');
    
    // 2. Malformed JSON should not crash
    StepContext ctx2 = StepContext.withCapturedValues(
      instanceId,
      'WF',
      'StepA',
      null,
      null,
      null,
      null,
      1,
      0,
      null,
      null,
      '{"__maxAttempts":'
    );
    System.assertEquals(1, ctx2.maxAttempts, 'Should fallback to default 1 on malformed JSON');
  }

  @isTest
  static void testReportProgress() {
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

    System.assertEquals(false, ctx.isProgressReported());
    System.assertEquals(null, ctx.getProgressJson());

    ctx.reportProgress(42.5, 'Processing batch 3');
    System.assertEquals(true, ctx.isProgressReported());
    Map<String, Object> progress = (Map<String, Object>) JSON.deserializeUntyped(ctx.getProgressJson());
    System.assertEquals(42.5, (Decimal) progress.get('percentComplete'));
    System.assertEquals('Processing batch 3', (String) progress.get('message'));

    ctx.reportProgress(new Map<String, Object>{ 'custom' => 'data' });
    System.assertEquals(true, ctx.isProgressReported());
    Map<String, Object> customProgress = (Map<String, Object>) JSON.deserializeUntyped(ctx.getProgressJson());
    System.assertEquals('data', (String) customProgress.get('custom'));

    ctx.reportProgress(null);
    System.assertEquals(true, ctx.isProgressReported());
    System.assertEquals(null, ctx.getProgressJson());
  }

  private class ObjectProducer implements CaptureProducer {
    private Object value;
    public ObjectProducer(Object value) {
      this.value = value;
    }
    public Object produce() {
      return this.value;
    }
  }

  @isTest
  static void testAutoReplayAtYieldTime() {
    WorkflowEngine.disableQueueableInTest = true;

    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = 'TestWorkflow',
      Status__c = 'Running',
      Correlation_Key__c = 'CorrKey-123'
    );
    insert inst;

    Workflow_Signal__c sig = new Workflow_Signal__c(
      Correlation_Key__c = 'CorrKey-123',
      Signal_Name__c = 'Go',
      Payload__c = '{"val":42}',
      Status__c = 'Unrouted'
    );
    insert sig;

    StepContext ctx = new StepContext(
      inst.Id,
      'TestWorkflow',
      'TestStep',
      null,
      null,
      null,
      null,
      1,
      new WorkflowEngine.PendingSignalSource(inst.Id)
    );

    // Call getSignal first to populate cache with empty result (no signals present yet in the context cache)
    System.assertEquals(false, ctx.getSignal('Go').isPresent());

    Test.startTest();
    WorkflowEngine.redeliverMatchingSignalsForInstance(inst.Id, inst.Correlation_Key__c);
    
    // Create a new context since the old one cached the empty signal list
    ctx = new StepContext(
      inst.Id,
      'TestWorkflow',
      'TestStep',
      null,
      null,
      null,
      null,
      1,
      new WorkflowEngine.PendingSignalSource(inst.Id)
    );
    Test.stopTest();

    Workflow_Signal__c reloadedSig = [
      SELECT Status__c, Workflow_Instance__c
      FROM Workflow_Signal__c
      WHERE Id = :sig.Id
    ];
    System.assertEquals('Received', reloadedSig.Status__c);
    System.assertEquals(inst.Id, reloadedSig.Workflow_Instance__c);

    // Cache should be cleared and the new signal should be returned
    StepContext.Signal fetched = ctx.getSignal('Go');
    System.assertEquals(true, fetched.isPresent());
    System.assertEquals('{"val":42}', fetched.payload);
  }

  @isTest
  static void testAutoReplayAtYieldTimeOldestFirst() {
    WorkflowEngine.disableQueueableInTest = true;

    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = 'TestWorkflow',
      Status__c = 'Running',
      Correlation_Key__c = 'CorrKey-456'
    );
    insert inst;

    Workflow_Signal__c sig1 = new Workflow_Signal__c(
      Correlation_Key__c = 'CorrKey-456',
      Signal_Name__c = 'Go',
      Payload__c = '{"val":1}',
      Status__c = 'Unrouted'
    );
    insert sig1;

    Workflow_Signal__c sig2 = new Workflow_Signal__c(
      Correlation_Key__c = 'CorrKey-456',
      Signal_Name__c = 'Go',
      Payload__c = '{"val":2}',
      Status__c = 'Unrouted'
    );
    insert sig2;

    StepContext ctx = new StepContext(
      inst.Id,
      'TestWorkflow',
      'TestStep',
      null,
      null,
      null,
      null,
      1,
      new WorkflowEngine.PendingSignalSource(inst.Id)
    );

    Test.startTest();
    WorkflowEngine.redeliverMatchingSignalsForInstance(inst.Id, inst.Correlation_Key__c);
    Test.stopTest();

    Workflow_Signal__c reloadedSig1 = [
      SELECT Status__c, Workflow_Instance__c
      FROM Workflow_Signal__c
      WHERE Id = :sig1.Id
    ];
    System.assertEquals('Received', reloadedSig1.Status__c, 'Oldest signal must be auto-delivered');

    Workflow_Signal__c reloadedSig2 = [
      SELECT Status__c, Workflow_Instance__c
      FROM Workflow_Signal__c
      WHERE Id = :sig2.Id
    ];
    System.assertEquals('Received', reloadedSig2.Status__c, 'Newer signal must also be auto-delivered');
  }

  @isTest
  static void testAutoReplayDrainsAllSignals() {
    WorkflowEngine.disableQueueableInTest = true;

    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = 'TestWorkflow',
      Status__c = 'Running',
      Correlation_Key__c = 'CorrKey-LargeBacklog'
    );
    insert inst;

    List<Workflow_Signal__c> signals = new List<Workflow_Signal__c>();
    // Insert 120 signals to exceed any previous 100-limit cap
    for (Integer i = 0; i < 120; i++) {
      signals.add(new Workflow_Signal__c(
        Correlation_Key__c = 'CorrKey-LargeBacklog',
        Signal_Name__c = 'Go',
        Payload__c = '{"val":' + i + '}',
        Status__c = 'Unrouted'
      ));
    }
    insert signals;

    Test.startTest();
    WorkflowEngine.redeliverMatchingSignalsForInstance(inst.Id, inst.Correlation_Key__c);
    Test.stopTest();

    List<Workflow_Signal__c> reloadedSignals = [
      SELECT Status__c, Workflow_Instance__c
      FROM Workflow_Signal__c
      WHERE Correlation_Key__c = 'CorrKey-LargeBacklog'
    ];
    System.assertEquals(120, reloadedSignals.size());
    for (Workflow_Signal__c sig : reloadedSignals) {
      System.assertEquals('Received', sig.Status__c, 'All signals in the large backlog must be auto-delivered');
      System.assertEquals(inst.Id, sig.Workflow_Instance__c, 'All signals must be bound to the correct instance');
    }
  }
}

