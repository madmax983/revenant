@IsTest
public class StepContextTest {
  @IsTest
  static void testConstructorAndProperties() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id dummyInstanceId = TestIdFactory.generate(Organization.SObjectType);
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
  }

  @IsTest
  static void testConstructorWithVersion() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id dummyInstanceId = TestIdFactory.generate(Organization.SObjectType);
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
  }

  @IsTest
  static void testShouldYieldNormalConditions() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id dummyInstanceId = TestIdFactory.generate(Organization.SObjectType);
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
  }

  @IsTest
  static void testShouldYieldQueryRowsThresholdExceeded() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id dummyInstanceId = TestIdFactory.generate(Organization.SObjectType);
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
  }

  @IsTest
  static void testShouldYieldAsyncApexExecutionsLimit() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id dummyInstanceId = TestIdFactory.generate(Organization.SObjectType);
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
  }

  // --- Inbound signal payload accessors (issue #11) ---

  @IsTest
  static void testNoPendingSignalsReturnsCleanEmptyResult() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id dummyInstanceId = TestIdFactory.generate(Organization.SObjectType);
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
  }

  @IsTest
  static void testPendingSignalsExposedInArrivalOrder() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id dummyInstanceId = TestIdFactory.generate(Organization.SObjectType);
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
  }

  @IsTest
  static void testGetSignalReturnsMostRecentMatchingName() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id dummyInstanceId = TestIdFactory.generate(Organization.SObjectType);
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
  }

  @IsTest
  static void testConsumedSignalIdsTracksObservedNamesOnly() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
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
  }

  @IsTest
  static void testGetSignalsAllMarksEverythingObserved() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
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
  }

  @IsTest
  static void testBlankNamedLookupMatchesNothing() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id dummyInstanceId = TestIdFactory.generate(Organization.SObjectType);
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

  @IsTest
  static void testGetSignalUsesTrueLatestWhenListReadCapped() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id dummyInstanceId = TestIdFactory.generate(Organization.SObjectType);
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
  }

  @IsTest
  static void testGetSignalRecoversClaimedPageWhenSourceSeesNoneAfterCap() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id dummyInstanceId = TestIdFactory.generate(Organization.SObjectType);
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
  }

  @IsTest
  static void testGetSignalUsesListTailWhenListReadComplete() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id dummyInstanceId = TestIdFactory.generate(Organization.SObjectType);
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
  }

  @IsTest
  static void testNamedLookupFallsThroughWhenFullListReadCapped() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id dummyInstanceId = TestIdFactory.generate(Organization.SObjectType);
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
        (StepContext.SignalSource) new FakeNameSource(
          partialAll,
          important,
          true
        )
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
  }

  @IsTest
  static void testCachedNamedLookupIsCaseInsensitive() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id dummyInstanceId = TestIdFactory.generate(Organization.SObjectType);
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
      System.assertEquals(
        '{"ok":true}',
        ctx.getSignal('APPROVE:ORDER').payload
      );
      System.assertEquals(1, ctx.getSignals('approve:ORDER').size());
    }
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

  @IsTest
  static void testNamedListIncludesClaimedRowsFromCappedFullRead() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id dummyInstanceId = TestIdFactory.generate(Organization.SObjectType);
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
  }

  @IsTest
  static void testLatestMergeUsesIdTieBreakOnEqualTimestamp() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id dummyInstanceId = TestIdFactory.generate(Organization.SObjectType);
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
  }

  // ---------------------------------------------------------------------------
  // Idempotency key (issue #2)
  // ---------------------------------------------------------------------------

  @IsTest
  static void testIdempotencyKeyIsNonBlankAndStableAcrossAttempts() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Two contexts for the SAME logical (instance, step) but representing
      // different attempts: different previous output, step state, workflow
      // input, and even workflow version. A transient RetryPolicy retry, an
      // operator re-drive (#1), and an at-least-once Workflow_Event__e resume all
      // re-build a context like this -> the key must be identical every time.
      Id instanceId = TestIdFactory.generate(Organization.SObjectType);
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
  }

  @IsTest
  static void testIdempotencyKeyDistinctPerStep() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id instanceId = TestIdFactory.generate(Organization.SObjectType);
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
  }

  @IsTest
  static void testIdempotencyKeyDistinctPerInstance() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // The same step name across two different instances (e.g. two parallel
      // fan-out branch instances with different Parent_Instance__c, or the same
      // step in two separate runs) must observe different keys.
      StepContext branchOne = new StepContext(
        TestIdFactory.generate(Organization.SObjectType),
        'WF',
        'StepA',
        null,
        null,
        null,
        null
      );
      StepContext branchTwo = new StepContext(
        TestIdFactory.generate(Organization.SObjectType),
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
  }

  @IsTest
  static void testIdempotencyKeyCompensateDistinctAndStable() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // The engine builds a compensate() context with stepName "<step>_Compensate"
      // (see WorkflowEngine.runCompensationStep). So the compensation key is
      // distinct from the forward execution key yet stable across compensation
      // retries.
      Id instanceId = TestIdFactory.generate(Organization.SObjectType);
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
  }

  @IsTest
  static void testIdempotencyKeyDistinctPerVisit() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // When a workflow loops back to the same step in the same instance, each
      // completed visit must observe a different key so distinct side effects are
      // not wrongly deduped; the engine supplies an incrementing visit sequence.
      Id instanceId = TestIdFactory.generate(Organization.SObjectType);
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
  }

  @IsTest
  static void testIdempotencyKeyDefaultVisitMatchesExplicitZero() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // The additive visit param defaults to 0, so the 8-arg constructor and the
      // 9-arg constructor with stepVisit=0 must yield the identical key.
      Id instanceId = TestIdFactory.generate(Organization.SObjectType);
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
  }

  @IsTest
  static void testPreviousRunAtNullByDefault() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      StepContext ctx = new StepContext(
        TestIdFactory.generate(Organization.SObjectType),
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
  }

  @IsTest
  static void testPreviousRunAtSetViaFullConstructor() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Datetime ts = Datetime.now().addMinutes(-5);
      StepContext ctx = new StepContext(
        TestIdFactory.generate(Organization.SObjectType),
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

  @IsTest
  static void testOnceFirstCallInvokesProducerAndReturnsValue() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id instanceId = TestIdFactory.generate(Organization.SObjectType);
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
  }

  @IsTest
  static void testOnceSecondCallReturnsSameValueWithoutCallingProducer() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id instanceId = TestIdFactory.generate(Organization.SObjectType);
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
  }

  @IsTest
  static void testOnceDistinctKeysAreIndependent() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id instanceId = TestIdFactory.generate(Organization.SObjectType);
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
  }

  @IsTest
  static void testOnceWithPriorCapturesSkipsProducer() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id instanceId = TestIdFactory.generate(Organization.SObjectType);
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
  }

  @IsTest
  static void testGetCapturedValuesJsonRoundTrips() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id instanceId = TestIdFactory.generate(Organization.SObjectType);
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
  }

  @IsTest
  static void testGetCapturedValuesJsonNullWhenNoCaptures() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id instanceId = TestIdFactory.generate(Organization.SObjectType);
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
  }

  @IsTest
  static void testOnceValuesAreJsonRoundTripped() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Numbers and booleans JSON-round-trip to a consistent type so values are
      // byte-identical regardless of whether they come from in-memory or rehydrated.
      Id instanceId = TestIdFactory.generate(Organization.SObjectType);
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
  }

  @IsTest
  static void testExposedRetryPropertiesAndDefaults() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id instanceId = TestIdFactory.generate(Organization.SObjectType);
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
      System.assertEquals(
        1,
        ctx.maxAttempts,
        'Default maxAttempts should be 1'
      );
      System.assert(
        ctx.isFinalAttempt(),
        'Default context should be final attempt'
      );
    }
  }

  @IsTest
  static void testExposedRetryPropertiesOverloads() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id instanceId = TestIdFactory.generate(Organization.SObjectType);
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
  }

  @IsTest
  static void testExposedRetryPropertiesFromCapturedValues() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id instanceId = TestIdFactory.generate(Organization.SObjectType);
      String priorJson = JSON.serialize(
        new Map<String, Object>{
          'refNumber' => 'REF-001',
          '__maxAttempts' => 3
        }
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
      System.assertEquals(
        5,
        Integer.valueOf(ctx.once('__maxAttempts', new ObjectProducer(5))),
        'Should strip __maxAttempts from in-memory captured values'
      );
    }
  }

  @IsTest
  static void testExposedRetryPropertiesStatePreservationOnYield() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id instanceId = TestIdFactory.generate(Organization.SObjectType);
      String priorJson = JSON.serialize(
        new Map<String, Object>{
          'refNumber' => 'REF-001',
          '__maxAttempts' => 3
        }
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
        3 // maxAttempts
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
      Map<String, Object> deserialized = (Map<String, Object>) JSON.deserializeUntyped(
        outputJson
      );
      System.assertEquals(
        3,
        Integer.valueOf(deserialized.get('__maxAttempts'))
      );
    }
  }

  @IsTest
  static void testRetryRobustnessDecimalAndMalformedJson() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id instanceId = TestIdFactory.generate(Organization.SObjectType);

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
      System.assertEquals(
        3,
        ctx.maxAttempts,
        'Should parse double/decimal attempts safely'
      );

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
      System.assertEquals(
        1,
        ctx2.maxAttempts,
        'Should fallback to default 1 on malformed JSON'
      );
    }
  }

  @IsTest
  static void testReportProgress() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id dummyInstanceId = TestIdFactory.generate(Organization.SObjectType);
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
      Map<String, Object> progress = (Map<String, Object>) JSON.deserializeUntyped(
        ctx.getProgressJson()
      );
      System.assertEquals(42.5, (Decimal) progress.get('percentComplete'));
      System.assertEquals(
        'Processing batch 3',
        (String) progress.get('message')
      );

      ctx.reportProgress(new Map<String, Object>{ 'custom' => 'data' });
      System.assertEquals(true, ctx.isProgressReported());
      Map<String, Object> customProgress = (Map<String, Object>) JSON.deserializeUntyped(
        ctx.getProgressJson()
      );
      System.assertEquals('data', (String) customProgress.get('custom'));

      ctx.reportProgress(null);
      System.assertEquals(true, ctx.isProgressReported());
      System.assertEquals(null, ctx.getProgressJson());
    }
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

  @IsTest
  static void testAutoReplayAtYieldTime() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
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
      WorkflowEngine.redeliverMatchingSignalsForInstance(
        inst.Id,
        inst.Correlation_Key__c
      );

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
  }

  @IsTest
  static void testAutoReplayAtYieldTimeOldestFirst() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
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

      Test.startTest();
      WorkflowEngine.redeliverMatchingSignalsForInstance(
        inst.Id,
        inst.Correlation_Key__c
      );
      Test.stopTest();

      Workflow_Signal__c reloadedSig1 = [
        SELECT Status__c, Workflow_Instance__c
        FROM Workflow_Signal__c
        WHERE Id = :sig1.Id
      ];
      System.assertEquals(
        'Received',
        reloadedSig1.Status__c,
        'Oldest signal must be auto-delivered'
      );

      Workflow_Signal__c reloadedSig2 = [
        SELECT Status__c, Workflow_Instance__c
        FROM Workflow_Signal__c
        WHERE Id = :sig2.Id
      ];
      System.assertEquals(
        'Received',
        reloadedSig2.Status__c,
        'Newer signal must also be auto-delivered'
      );
    }
  }

  @IsTest
  static void testAutoReplayDrainsAllSignals() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
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
        signals.add(
          new Workflow_Signal__c(
            Correlation_Key__c = 'CorrKey-LargeBacklog',
            Signal_Name__c = 'Go',
            Payload__c = '{"val":' + i + '}',
            Status__c = 'Unrouted'
          )
        );
      }
      insert signals;

      Test.startTest();
      WorkflowEngine.redeliverMatchingSignalsForInstance(
        inst.Id,
        inst.Correlation_Key__c
      );
      Test.stopTest();

      List<Workflow_Signal__c> reloadedSignals = [
        SELECT Status__c, Workflow_Instance__c
        FROM Workflow_Signal__c
        WHERE Correlation_Key__c = 'CorrKey-LargeBacklog'
      ];
      System.assertEquals(120, reloadedSignals.size());
      for (Workflow_Signal__c sig : reloadedSignals) {
        System.assertEquals(
          'Received',
          sig.Status__c,
          'All signals in the large backlog must be auto-delivered'
        );
        System.assertEquals(
          inst.Id,
          sig.Workflow_Instance__c,
          'All signals must be bound to the correct instance'
        );
      }
    }
  }

  private class MapSignalSource implements StepContext.SignalSource {
    private final Map<String, StepContext.Signal> signals;
    private MapSignalSource(Map<String, StepContext.Signal> signals) {
      this.signals = signals;
    }
    public List<StepContext.Signal> getPendingSignals(String name) {
      if (String.isBlank(name)) {
        return signals.values();
      }
      StepContext.Signal s = signals.get(name.toLowerCase());
      return s != null
        ? new List<StepContext.Signal>{ s }
        : new List<StepContext.Signal>();
    }
    public StepContext.Signal getLatestSignal(String name) {
      if (String.isBlank(name)) {
        return null;
      }
      return signals.get(name.toLowerCase());
    }
    public Boolean readWasCapped() {
      return false;
    }
  }

  @IsTest
  static void testGetChildOutcomeNotPresent() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id dummyInstanceId = TestIdFactory.generate(Organization.SObjectType);
      MapSignalSource fakeSource = new MapSignalSource(
        new Map<String, StepContext.Signal>()
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
        fakeSource
      );

      StepContext.ChildOutcome outcome = ctx.getChildOutcome('CC_1');
      System.assertEquals(false, outcome.isPresent());
      System.assertEquals(false, outcome.isSuccess());
      System.assertEquals(null, outcome.status);
      System.assertEquals(null, outcome.errorMessage);
      System.assertEquals(null, outcome.output);
    }
  }

  @IsTest
  static void testGetChildOutcomeCompleted() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id dummyInstanceId = TestIdFactory.generate(Organization.SObjectType);
      Map<String, StepContext.Signal> sigs = new Map<String, StepContext.Signal>{
        'childcompleted:cc_1' => new StepContext.Signal(
          null,
          'ChildCompleted:CC_1',
          '{"score":700}'
        )
      };
      MapSignalSource fakeSource = new MapSignalSource(sigs);
      StepContext ctx = new StepContext(
        dummyInstanceId,
        'W',
        'S',
        null,
        null,
        null,
        null,
        1,
        fakeSource
      );

      StepContext.ChildOutcome outcome = ctx.getChildOutcome('CC_1');
      System.assertEquals(true, outcome.isPresent());
      System.assertEquals(true, outcome.isSuccess());
      System.assertEquals('Completed', outcome.status);
      System.assertEquals(null, outcome.errorMessage);
      System.assertEquals('{"score":700}', outcome.output);
    }
  }

  @IsTest
  static void testGetChildOutcomeFailedStructured() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id dummyInstanceId = TestIdFactory.generate(Organization.SObjectType);
      Map<String, StepContext.Signal> sigs = new Map<String, StepContext.Signal>{
        'childfailed:cc_1' => new StepContext.Signal(
          null,
          'ChildFailed:CC_1',
          '{"status":"Failed","errorMessage":"Step crashed","output":"partialData"}'
        )
      };
      MapSignalSource fakeSource = new MapSignalSource(sigs);
      StepContext ctx = new StepContext(
        dummyInstanceId,
        'W',
        'S',
        null,
        null,
        null,
        null,
        1,
        fakeSource
      );

      StepContext.ChildOutcome outcome = ctx.getChildOutcome('CC_1');
      System.assertEquals(true, outcome.isPresent());
      System.assertEquals(false, outcome.isSuccess());
      System.assertEquals('Failed', outcome.status);
      System.assertEquals('Step crashed', outcome.errorMessage);
      System.assertEquals('partialData', outcome.output);
    }
  }

  @IsTest
  static void testGetChildOutcomeFailedMalformed() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id dummyInstanceId = TestIdFactory.generate(Organization.SObjectType);
      Map<String, StepContext.Signal> sigs = new Map<String, StepContext.Signal>{
        'childfailed:cc_1' => new StepContext.Signal(
          null,
          'ChildFailed:CC_1',
          'Raw error message string'
        )
      };
      MapSignalSource fakeSource = new MapSignalSource(sigs);
      StepContext ctx = new StepContext(
        dummyInstanceId,
        'W',
        'S',
        null,
        null,
        null,
        null,
        1,
        fakeSource
      );

      StepContext.ChildOutcome outcome = ctx.getChildOutcome('CC_1');
      System.assertEquals(true, outcome.isPresent());
      System.assertEquals(false, outcome.isSuccess());
      System.assertEquals('Failed', outcome.status);
      System.assertEquals('Raw error message string', outcome.errorMessage);
      System.assertEquals(null, outcome.output);
    }
  }

  @IsTest
  static void testGetChildOutcomeConsumesBothSignals() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id dummyInstanceId = TestIdFactory.generate(Organization.SObjectType);
      Map<String, StepContext.Signal> sigs = new Map<String, StepContext.Signal>{
        'childcompleted:cc_1' => new StepContext.Signal(
          null,
          'ChildCompleted:CC_1',
          '{"score":700}'
        )
      };
      MapSignalSource fakeSource = new MapSignalSource(sigs);
      StepContext ctx = new StepContext(
        dummyInstanceId,
        'W',
        'S',
        null,
        null,
        null,
        null,
        1,
        fakeSource
      );

      StepContext.ChildOutcome outcome = ctx.getChildOutcome('CC_1');
      System.assertEquals(true, outcome.isPresent());
      System.assertEquals(true, outcome.isSuccess());

      Set<String> consumedNames = ctx.getConsumedSignalNames();
      System.assert(
        consumedNames.contains('ChildCompleted:CC_1'),
        'Must consume ChildCompleted signal name'
      );
      System.assert(
        consumedNames.contains('ChildFailed:CC_1'),
        'Must consume ChildFailed signal name unconditionally to clean up duplicate/delayed sibling signals'
      );
    }
  }

  @IsTest
  static void testGetChildOutcomeConsumesBothSignalsWhenFailed() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id dummyInstanceId = TestIdFactory.generate(Organization.SObjectType);
      Map<String, StepContext.Signal> sigs = new Map<String, StepContext.Signal>{
        'childfailed:cc_1' => new StepContext.Signal(
          null,
          'ChildFailed:CC_1',
          '{"status":"Failed"}'
        )
      };
      MapSignalSource fakeSource = new MapSignalSource(sigs);
      StepContext ctx = new StepContext(
        dummyInstanceId,
        'W',
        'S',
        null,
        null,
        null,
        null,
        1,
        fakeSource
      );

      StepContext.ChildOutcome outcome = ctx.getChildOutcome('CC_1');
      System.assertEquals(true, outcome.isPresent());
      System.assertEquals(false, outcome.isSuccess());

      Set<String> consumedNames = ctx.getConsumedSignalNames();
      System.assert(
        consumedNames.contains('ChildCompleted:CC_1'),
        'Must consume ChildCompleted signal name unconditionally'
      );
      System.assert(
        consumedNames.contains('ChildFailed:CC_1'),
        'Must consume ChildFailed signal name'
      );
    }
  }

  @IsTest
  static void testGetChildOutcomeDoesNotConsumeWhenAbsent() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id dummyInstanceId = TestIdFactory.generate(Organization.SObjectType);
      MapSignalSource fakeSource = new MapSignalSource(
        new Map<String, StepContext.Signal>()
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
        fakeSource
      );

      StepContext.ChildOutcome outcome = ctx.getChildOutcome('CC_1');
      System.assertEquals(false, outcome.isPresent());

      Set<String> consumedNames = ctx.getConsumedSignalNames();
      System.assert(
        !consumedNames.contains('ChildCompleted:CC_1'),
        'Must not consume ChildCompleted signal name when absent'
      );
      System.assert(
        !consumedNames.contains('ChildFailed:CC_1'),
        'Must not consume ChildFailed signal name when absent'
      );
    }
  }

  @IsTest
  static void testLogApiBuffering() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id dummyInstanceId = TestIdFactory.generate(Organization.SObjectType);
      StepContext ctx = new StepContext(
        dummyInstanceId,
        'TestWorkflow',
        'TestStep',
        null,
        null,
        null,
        null
      );

      ctx.log(StepContext.Level.INFO, 'Info message');
      Map<String, Object> context = new Map<String, Object>{
        'foo' => 'bar',
        'count' => 42
      };
      ctx.log(StepContext.Level.WARN, 'Warning message', context);
      ctx.log(StepContext.Level.ERROR, 'Error message');

      List<StepContext.Breadcrumb> crumbs = ctx.getBreadcrumbs();
      System.assertEquals(
        3,
        crumbs.size(),
        'Should store exactly 3 breadcrumbs'
      );

      System.assertEquals(StepContext.Level.INFO, crumbs[0].level);
      System.assertEquals('Info message', crumbs[0].message);
      System.assertNotEquals(null, crumbs[0].timestamp);

      System.assertEquals(StepContext.Level.WARN, crumbs[1].level);
      // context map serialized to JSON
      System.assert(
        crumbs[1].message.startsWith('Warning message | Context: '),
        'Should append context json'
      );
      System.assert(
        crumbs[1].message.contains('"foo":"bar"'),
        'Serialized JSON should contain foo'
      );
      System.assert(
        crumbs[1].message.contains('"count":42'),
        'Serialized JSON should contain count'
      );
      System.assertNotEquals(null, crumbs[1].timestamp);

      System.assertEquals(StepContext.Level.ERROR, crumbs[2].level);
      System.assertEquals('Error message', crumbs[2].message);
      System.assertNotEquals(null, crumbs[2].timestamp);
    }
  }

  @IsTest
  static void testLogCharacterTruncation() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id dummyInstanceId = TestIdFactory.generate(Organization.SObjectType);
      StepContext ctx = new StepContext(
        dummyInstanceId,
        'TestWorkflow',
        'TestStep',
        null,
        null,
        null,
        null
      );

      String message4000 = 'a'.repeat(4000);
      ctx.log(StepContext.Level.INFO, message4000);
      List<StepContext.Breadcrumb> crumbs = ctx.getBreadcrumbs();
      System.assertEquals(1, crumbs.size());
      System.assertEquals(
        4000,
        crumbs[0].message.length(),
        'Exact 4000 char message should not be truncated'
      );
      System.assertEquals(message4000, crumbs[0].message);

      ctx = new StepContext(dummyInstanceId, 'W', 'S', null, null, null, null);
      String message4001 = 'b'.repeat(4001);
      ctx.log(StepContext.Level.INFO, message4001);
      crumbs = ctx.getBreadcrumbs();
      System.assertEquals(1, crumbs.size());
      System.assertEquals(
        4000,
        crumbs[0].message.length(),
        'Should be truncated to 4000 characters total'
      );
      System.assertEquals(
        'b'.repeat(3985) + '... [TRUNCATED]',
        crumbs[0].message
      );

      // Test with context
      ctx = new StepContext(dummyInstanceId, 'W', 'S', null, null, null, null);
      Map<String, Object> context = new Map<String, Object>{ 'k' => 'v' };
      // base message + ' | Context: {"k":"v"}' has length: 3980 + 21 = 4001
      String msg3980 = 'c'.repeat(3980);
      ctx.log(StepContext.Level.INFO, msg3980, context);
      crumbs = ctx.getBreadcrumbs();
      System.assertEquals(1, crumbs.size());
      String expectedBase = msg3980 + ' | Context: {"k":"v"}';
      System.assertEquals(
        expectedBase.substring(0, 3985) + '... [TRUNCATED]',
        crumbs[0].message
      );
    }
  }

  @IsTest
  static void testLogEntriesTruncation() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id dummyInstanceId = TestIdFactory.generate(Organization.SObjectType);
      StepContext ctx = new StepContext(
        dummyInstanceId,
        'TestWorkflow',
        'TestStep',
        null,
        null,
        null,
        null
      );

      for (Integer i = 0; i < 100; i++) {
        ctx.log(StepContext.Level.INFO, 'Entry ' + i);
      }
      List<StepContext.Breadcrumb> crumbs = ctx.getBreadcrumbs();
      System.assertEquals(
        100,
        crumbs.size(),
        'Should allow exactly 100 entries'
      );

      // 101st log triggers single warning and discards the log
      ctx.log(StepContext.Level.INFO, 'Entry 100');
      crumbs = ctx.getBreadcrumbs();
      System.assertEquals(
        101,
        crumbs.size(),
        'Should have appended a warning and discarded entry 100'
      );
      System.assertEquals(StepContext.Level.WARN, crumbs[100].level);
      System.assertEquals(
        '[TRUNCATED] Log limit of 100 entries reached. Subsequent step logs are discarded.',
        crumbs[100].message
      );

      // 102nd log is discarded, count remains 101, no second warning
      ctx.log(StepContext.Level.INFO, 'Entry 101');
      crumbs = ctx.getBreadcrumbs();
      System.assertEquals(
        101,
        crumbs.size(),
        'Should not append more logs or warnings'
      );
    }
  }

  @IsTest
  static void testLogNullOrEmptyMessage() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id dummyInstanceId = TestIdFactory.generate(Organization.SObjectType);
      StepContext ctx = new StepContext(
        dummyInstanceId,
        'TestWorkflow',
        'TestStep',
        null,
        null,
        null,
        null
      );

      ctx.log(StepContext.Level.INFO, null);
      ctx.log(StepContext.Level.WARN, '');
      ctx.log(
        StepContext.Level.ERROR,
        null,
        new Map<String, Object>{ 'x' => 1 }
      );

      List<StepContext.Breadcrumb> crumbs = ctx.getBreadcrumbs();
      System.assertEquals(3, crumbs.size());

      System.assertEquals(null, crumbs[0].message);
      System.assertEquals('', crumbs[1].message);
      System.assertEquals('null | Context: {"x":1}', crumbs[2].message);
    }
  }

  @IsTest
  static void testLogContextSerializationSafety() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id dummyInstanceId = TestIdFactory.generate(Organization.SObjectType);
      StepContext ctx = new StepContext(
        dummyInstanceId,
        'W',
        'S',
        null,
        null,
        null,
        null
      );

      // Test circular reference catch
      Map<String, Object> circularMap = new Map<String, Object>();
      circularMap.put('self', circularMap);
      ctx.log(StepContext.Level.INFO, 'circular', circularMap);

      List<StepContext.Breadcrumb> crumbs = ctx.getBreadcrumbs();
      System.assertEquals(1, crumbs.size());
      System.assert(
        crumbs[0].message.contains('[TRUNCATED] JSON serialization failed'),
        'Error mismatch: ' + crumbs[0].message
      );

      // Test oversized value pre-check
      ctx = new StepContext(dummyInstanceId, 'W', 'S', null, null, null, null);
      Map<String, Object> oversizedMap = new Map<String, Object>{
        'payload' => 'x'.repeat(4001)
      };
      ctx.log(StepContext.Level.INFO, 'oversized', oversizedMap);
      crumbs = ctx.getBreadcrumbs();
      System.assertEquals(1, crumbs.size());
      System.assert(
        crumbs[0]
          .message.contains(
            '[TRUNCATED] JSON serialization bypassed due to oversized string value'
          ),
        'Message mismatch: ' + crumbs[0].message
      );
    }
  }

  @IsTest
  static void testNullLogLevelDefaulting() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id dummyInstanceId = TestIdFactory.generate(Organization.SObjectType);
      StepContext ctx = new StepContext(
        dummyInstanceId,
        'W',
        'S',
        null,
        null,
        null,
        null
      );
      ctx.log(null, 'null level message');
      List<StepContext.Breadcrumb> crumbs = ctx.getBreadcrumbs();
      System.assertEquals(1, crumbs.size());
      System.assertEquals(
        StepContext.Level.INFO,
        crumbs[0].level,
        'Should default null level to INFO'
      );
    }
  }

  @IsTest
  static void testPatchedBrandNewInstance() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id dummyInstanceId = TestIdFactory.generate(Organization.SObjectType);
      StepContext ctx = new StepContext(
        dummyInstanceId,
        'TestWorkflow',
        'TestStep',
        null,
        null,
        null,
        null
      );

      // First time decision is reached in a brand new instance
      Boolean isPatched = ctx.patched('change-1');
      System.assertEquals(
        true,
        isPatched,
        'New patch should default to true on first execution'
      );
      System.assertEquals(
        true,
        ctx.hasNewCaptures(),
        'Decision should be newly captured'
      );

      String capturedJson = ctx.getCapturedValuesJson();
      System.assertNotEquals(null, capturedJson);
      System.assert(
        capturedJson.contains('"__patch:change-1":true'),
        'Decision should be recorded in captures'
      );
    }
  }

  @IsTest
  static void testPatchedReplay() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id dummyInstanceId = TestIdFactory.generate(Organization.SObjectType);
      StepContext ctx = StepContext.withCapturedValues(
        dummyInstanceId,
        'TestWorkflow',
        'TestStep',
        null,
        null,
        null,
        null,
        1,
        1,
        null,
        null,
        '{"__patch:change-1":true}'
      );

      // Decision is replayed
      Boolean isPatched = ctx.patched('change-1');
      System.assertEquals(
        true,
        isPatched,
        'Replayed patch should match recorded value'
      );
      System.assertEquals(
        false,
        ctx.hasNewCaptures(),
        'Replayed decision should not be marked as new capture'
      );
    }
  }

  @IsTest
  static void testPatchedReplayOffloaded() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'TestWorkflow',
        Status__c = 'Running',
        Correlation_Key__c = 'PatchKeyOffloaded',
        Current_Step__c = 'TestStep'
      );
      insert inst;

      // Save the patch decision JSON to ContentVersion
      String capturesJson = '{"__patch:change-offloaded":true}';
      String marker = WorkflowEngine.savePayloadIfNeeded(
        inst.Id,
        capturesJson,
        'CapturedValues'
      );

      // Insert a completed step execution with the offloaded marker
      insert new Workflow_Step_Execution__c(
        Workflow_Instance__c = inst.Id,
        Step_Name__c = 'PredecessorStep',
        Status__c = 'Completed',
        Captured_Values__c = marker
      );

      StepContext ctx = new StepContext(
        inst.Id,
        'TestWorkflow',
        'TestStep',
        null,
        null,
        null,
        null
      );

      // The offloaded patch decision should be resolved and read successfully as true
      Boolean isPatched = ctx.patched('change-offloaded');
      System.assertEquals(
        true,
        isPatched,
        'Should resolve and read offloaded patch decision'
      );
    }
  }

  @IsTest
  static void testPatchedReExecutionCompletedInPast() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Insert a workflow instance and step execution that completed in the past
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'TestWorkflow',
        Status__c = 'Running',
        Correlation_Key__c = 'PatchKey1',
        Current_Step__c = 'TestStep'
      );
      insert inst;

      // Insert a completed step execution for TestStep with no patch decision
      insert new Workflow_Step_Execution__c(
        Workflow_Instance__c = inst.Id,
        Step_Name__c = 'TestStep',
        Status__c = 'Completed'
      );

      StepContext ctx = new StepContext(
        inst.Id,
        'TestWorkflow',
        'TestStep',
        null,
        null,
        null,
        null
      );

      // The step has already completed in the past, so the patch decision should be false (not flipped retroactively)
      Boolean isPatched = ctx.patched('change-1');
      System.assertEquals(
        false,
        isPatched,
        'Should return false when step already completed in past without patch'
      );
      System.assertEquals(
        true,
        ctx.hasNewCaptures(),
        'Should capture decision as false'
      );

      String capturedJson = ctx.getCapturedValuesJson();
      System.assert(
        capturedJson.contains('"__patch:change-1":false'),
        'Recorded decision should be false'
      );
    }
  }

  @IsTest
  static void testPatchedDownstreamFirstExecutionLegacy() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      StepContext.mockInstanceCreatedDate = DateTime.newInstance(2026, 1, 1);
      StepContext.mockClassLastModified = DateTime.newInstance(2026, 1, 2);
      try {
        // 1. Insert a workflow instance and a completed predecessor step
        Workflow_Instance__c inst = new Workflow_Instance__c(
          Workflow_Name__c = 'TestWorkflow',
          Status__c = 'Running',
          Correlation_Key__c = 'PatchKey2',
          Current_Step__c = 'DownstreamStep'
        );
        insert inst;

        // Completed predecessor step has no patch decision recorded
        insert new Workflow_Step_Execution__c(
          Workflow_Instance__c = inst.Id,
          Step_Name__c = 'PredecessorStep',
          Status__c = 'Completed',
          Captured_Values__c = '{"someValue":true}'
        );

        StepContext ctx = new StepContext(
          inst.Id,
          'TestWorkflow',
          'DownstreamStep',
          null,
          null,
          null,
          null
        );

        // DownstreamStep is running for the first time. Since instanceCreatedDate < classLastModified,
        // it must default to false (legacy).
        Boolean isPatched = ctx.patched('change-1');
        System.assertEquals(
          false,
          isPatched,
          'Downstream step running for first time on legacy instance must default to false'
        );
      } finally {
        StepContext.mockInstanceCreatedDate = null;
        StepContext.mockClassLastModified = null;
      }
    }
  }

  @IsTest
  static void testPatchedDownstreamFirstExecutionNewInstance() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      StepContext.mockInstanceCreatedDate = DateTime.newInstance(2026, 1, 3);
      StepContext.mockClassLastModified = DateTime.newInstance(2026, 1, 2);
      try {
        Workflow_Instance__c inst = new Workflow_Instance__c(
          Workflow_Name__c = 'TestWorkflow',
          Status__c = 'Running',
          Correlation_Key__c = 'PatchKey3',
          Current_Step__c = 'DownstreamStep'
        );
        insert inst;

        insert new Workflow_Step_Execution__c(
          Workflow_Instance__c = inst.Id,
          Step_Name__c = 'PredecessorStep',
          Status__c = 'Completed',
          Captured_Values__c = '{"someValue":true}'
        );

        StepContext ctx = new StepContext(
          inst.Id,
          'TestWorkflow',
          'DownstreamStep',
          null,
          null,
          null,
          null
        );

        // Since instanceCreatedDate >= classLastModified, it is a brand-new instance, so it must default to true!
        Boolean isPatched = ctx.patched('change-1');
        System.assertEquals(
          true,
          isPatched,
          'Downstream step running for first time on brand-new instance must default to true'
        );
      } finally {
        StepContext.mockInstanceCreatedDate = null;
        StepContext.mockClassLastModified = null;
      }
    }
  }

  @IsTest
  static void testPatchedWithIntroducedAtDate() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Class was last modified on Day 3 (e.g. 2026-01-03) due to unrelated changes
      StepContext.mockClassLastModified = DateTime.newInstance(2026, 1, 3);

      // Patch was introduced on Day 2 (e.g. 2026-01-02)
      DateTime introducedAt = DateTime.newInstance(2026, 1, 2);

      try {
        // Instance A was created on Day 1 (2026-01-01), before patch was introduced
        StepContext.mockInstanceCreatedDate = DateTime.newInstance(2026, 1, 1);
        Workflow_Instance__c instA = new Workflow_Instance__c(
          Workflow_Name__c = 'TestWorkflow',
          Status__c = 'Running',
          Correlation_Key__c = 'DateKey1'
        );
        insert instA;

        StepContext ctxA = new StepContext(
          instA.Id,
          'TestWorkflow',
          'StepA',
          null,
          null,
          null,
          null
        );

        // Since instanceCreatedDate < introducedAt, it must default to false (legacy)!
        System.assertEquals(false, ctxA.patched('change-date', introducedAt));

        // Instance B was created on Day 2.5 (2026-01-02 12:00:00), after patch was introduced but before Day 3 redeploy
        StepContext.mockInstanceCreatedDate = DateTime.newInstance(
          2026,
          1,
          2,
          12,
          0,
          0
        );
        Workflow_Instance__c instB = new Workflow_Instance__c(
          Workflow_Name__c = 'TestWorkflow',
          Status__c = 'Running',
          Correlation_Key__c = 'DateKey2'
        );
        insert instB;

        StepContext ctxB = new StepContext(
          instB.Id,
          'TestWorkflow',
          'StepA',
          null,
          null,
          null,
          null
        );

        // Since instanceCreatedDate >= introducedAt, it must default to true, even though instanceCreatedDate < classLastModified!
        System.assertEquals(true, ctxB.patched('change-date', introducedAt));
      } finally {
        StepContext.mockInstanceCreatedDate = null;
        StepContext.mockClassLastModified = null;
      }
    }
  }

  @IsTest
  static void testDeprecatedPatch() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id dummyInstanceId = TestIdFactory.generate(Organization.SObjectType);

      // Case 1: Patched is true, deprecated should pass silently
      StepContext ctxTrue = StepContext.withCapturedValues(
        dummyInstanceId,
        'TestWorkflow',
        'TestStep',
        null,
        null,
        null,
        null,
        1,
        1,
        null,
        null,
        '{"__patch:change-1":true}'
      );
      try {
        ctxTrue.deprecated('change-1');
        // Pass
      } catch (Exception e) {
        System.assert(false, 'Should not throw exception when patch is active');
      }

      // Case 2: Patched is false, deprecated should throw WorkflowException
      StepContext ctxFalse = StepContext.withCapturedValues(
        dummyInstanceId,
        'TestWorkflow',
        'TestStep',
        null,
        null,
        null,
        null,
        1,
        1,
        null,
        null,
        '{"__patch:change-1":false}'
      );
      try {
        ctxFalse.deprecated('change-1');
        System.assert(
          false,
          'Should throw exception when patch is deprecated and inactive'
        );
      } catch (WorkflowEngine.WorkflowException e) {
        System.assert(
          e.getMessage().contains('retired code path for patch: change-1')
        );
      } catch (Exception e) {
        System.assert(
          false,
          'Should throw WorkflowException, got: ' + e.getTypeName()
        );
      }
    }
  }

  @IsTest
  static void testCallingClassNameResolution() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'TestWorkflow',
        Status__c = 'Running',
        Correlation_Key__c = 'CallingClassKey'
      );
      insert inst;

      StepContext ctx = new StepContext(
        inst.Id,
        'TestWorkflow',
        'TestStep',
        null,
        null,
        null,
        null
      );

      // Call patched. It will call loadExecutions(getCallingClassName())
      // which resolves the calling class to 'StepContextTest'.
      // Since 'StepContextTest' is a real class in the org, it will query its LastModifiedDate.
      ctx.patched('calling-class-change');

      System.assertNotEquals(null, ctx.getCapturedValuesJson());
    }
  }
}
