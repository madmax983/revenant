/**
 * @description Tests for {@link WorkflowWaitDescriptorService}: the awaited-signal
 * descriptor derived at dashboard read time for a Suspended instance parked on an
 * approval, child-completion, or generic signal wait. Covers the three classifications,
 * the unchanged-null case for a timer/sleep wait, offloaded-payload rehydration, and the
 * end-to-end exposure on both the list ({@code getFilteredInstances}) and detail
 * ({@code getInstanceDetails}) read paths. The pure-classification cases build the
 * instance/step rows in memory (0 DML, 0 SOQL); the offload and read-path cases seed rows.
 */
@IsTest
public class WorkflowWaitDescriptorServiceTest {
  // An AsyncApexJob-shaped id string (built from the live key prefix, not hardcoded) used to
  // represent a resume job attached to a sleep/retry wait.
  private static final String ASYNC_JOB_ID =
    AsyncApexJob.SObjectType.getDescribe(SObjectDescribeOptions.DEFERRED)
      .getKeyPrefix() + '000000000000';

  private static Workflow_Instance__c suspendedInstance(String asyncJobId) {
    return new Workflow_Instance__c(
      Workflow_Name__c = 'WaitDescTest.Workflow',
      Status__c = 'Suspended',
      Async_Job_Id__c = asyncJobId
    );
  }

  private static Workflow_Step_Execution__c pendingStep(
    String stepName,
    String output
  ) {
    return new Workflow_Step_Execution__c(
      Step_Name__c = stepName,
      Status__c = 'Pending',
      Output__c = output,
      Retry_Count__c = 0
    );
  }

  private static List<Workflow_Step_Execution__c> oneStep(
    Workflow_Step_Execution__c se
  ) {
    return new List<Workflow_Step_Execution__c>{ se };
  }

  // ── Pure classification (0 DML / 0 SOQL) ────────────────────────────────────

  @IsTest
  static void testApprovalDescriptor() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      String output = JSON.serialize(
        new Map<String, Object>{
          'waitingForApproval' => true,
          'approvalKey' => 'PurchaseApproval',
          'approvalRole' => 'CFO_Approver'
        }
      );
      Map<String, Object> d = WorkflowWaitDescriptorService.describeSignalWait(
        suspendedInstance(null),
        oneStep(pendingStep('WaitDescTest.ApproveStep', output))
      );
      System.assertNotEquals(null, d, 'An approval wait yields a descriptor');
      System.assertEquals(
        WorkflowWaitDescriptorService.TYPE_APPROVAL,
        d.get('type'),
        'Type is approval'
      );
      System.assertEquals(
        'Approve:PurchaseApproval',
        d.get('signalName'),
        'Signal name is the operator-injectable Approve:<key> form'
      );
      System.assertEquals(
        'Approve:PurchaseApproval',
        d.get('label'),
        'Label equals the injectable signal name for copy/paste'
      );
      System.assertEquals(
        'WaitDescTest.ApproveStep',
        d.get('stepName'),
        'Parked step name is surfaced'
      );
    }
  }

  @IsTest
  static void testChildCompletionDescriptor() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      String output = JSON.serialize(
        new Map<String, Object>{
          'childWorkflowName' => 'WaitDescTest.ChildWorkflow',
          'childCorrelationKey' => 'order-42'
        }
      );
      Map<String, Object> d = WorkflowWaitDescriptorService.describeSignalWait(
        suspendedInstance(null),
        oneStep(pendingStep('WaitDescTest.ChildStep', output))
      );
      System.assertNotEquals(null, d, 'A child wait yields a descriptor');
      System.assertEquals(
        WorkflowWaitDescriptorService.TYPE_CHILD,
        d.get('type'),
        'Type is child-completion'
      );
      System.assertEquals(
        'ChildCompleted:order-42',
        d.get('signalName'),
        'Signal name is the awaited ChildCompleted:<key> form'
      );
      System.assertEquals(
        'ChildCompleted:order-42',
        d.get('label'),
        'Label equals the injectable signal name'
      );
    }
  }

  @IsTest
  static void testBulkChildrenDescriptor() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      String output = JSON.serialize(
        new Map<String, Object>{
          'childCorrelationKeys' => new List<String>{ 'k1', 'k2' }
        }
      );
      Map<String, Object> d = WorkflowWaitDescriptorService.describeSignalWait(
        suspendedInstance(null),
        oneStep(pendingStep('WaitDescTest.FanOutStep', output))
      );
      System.assertNotEquals(
        null,
        d,
        'A bulk-children wait yields a descriptor'
      );
      System.assertEquals(
        WorkflowWaitDescriptorService.TYPE_CHILD,
        d.get('type'),
        'Type is child-completion'
      );
      // Issue #84: with >1 awaited key the parked state cannot tell which child is still
      // outstanding, so the single pre-fill is intentionally blank (never the possibly-stale
      // first key). The full list is surfaced for the operator to choose the outstanding one.
      System.assertEquals(
        null,
        d.get('signalName'),
        'A multi-child join leaves the pre-fill blank rather than suggest a possibly-stale key'
      );
      System.assertEquals(
        'Awaiting child completion — choose the outstanding child key',
        d.get('label'),
        'Label directs the operator to pick the still-outstanding child key'
      );
      List<String> names = (List<String>) d.get('childSignalNames');
      System.assertEquals(
        2,
        names.size(),
        'All awaited child keys are surfaced'
      );
      System.assertEquals('ChildCompleted:k1', names[0]);
      System.assertEquals('ChildCompleted:k2', names[1]);
    }
  }

  @IsTest
  static void testSingleKeyChildrenListStillInjectable() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // A START_CHILDREN join with exactly one awaited key is unambiguous: that lone key IS
      // the outstanding child, so it stays directly injectable as the pre-filled signal.
      String output = JSON.serialize(
        new Map<String, Object>{
          'childCorrelationKeys' => new List<String>{ 'only-child' }
        }
      );
      Map<String, Object> d = WorkflowWaitDescriptorService.describeSignalWait(
        suspendedInstance(null),
        oneStep(pendingStep('WaitDescTest.SingleFanOutStep', output))
      );
      System.assertEquals(
        'ChildCompleted:only-child',
        d.get('signalName'),
        'A single awaited child key is unambiguous and directly injectable'
      );
      System.assertEquals(
        'ChildCompleted:only-child',
        d.get('label'),
        'Label equals the injectable signal name for a single-child join'
      );
    }
  }

  @IsTest
  static void testStaleFirstChildKeyIsNotSuggested() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Scenario: the join spawned k1 and k2; k1 already completed but the join is still gated
      // on k2. The parked Output still holds the ORIGINAL full [k1, k2] list, so pre-filling
      // ChildCompleted:k1 would inject an already-satisfied key that cannot unblock the flow.
      // Path (b): the read side cannot derive outstanding keys, so it must NOT suggest k1.
      String output = JSON.serialize(
        new Map<String, Object>{
          'childCorrelationKeys' => new List<String>{ 'k1', 'k2' }
        }
      );
      Map<String, Object> d = WorkflowWaitDescriptorService.describeSignalWait(
        suspendedInstance(null),
        oneStep(pendingStep('WaitDescTest.GatedJoinStep', output))
      );
      System.assertNotEquals(
        'ChildCompleted:k1',
        d.get('signalName'),
        'The already-completed first key must not be pre-filled as the injectable signal'
      );
      System.assertEquals(
        null,
        d.get('signalName'),
        'A multi-child join with an ambiguous outstanding set pre-fills nothing'
      );
    }
  }

  @IsTest
  static void testGenericSignalDescriptorForOpaqueState() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Opaque author state, no marker, no resume job => generic signal wait.
      Map<String, Object> d = WorkflowWaitDescriptorService.describeSignalWait(
        suspendedInstance(null),
        oneStep(pendingStep('WaitDescTest.WaitStep', '{"cursor":123}'))
      );
      System.assertNotEquals(null, d, 'A generic suspend yields a descriptor');
      System.assertEquals(
        WorkflowWaitDescriptorService.TYPE_GENERIC,
        d.get('type'),
        'Type is generic-signal'
      );
      System.assertEquals(
        null,
        d.get('signalName'),
        'Generic waits have no derivable injectable name'
      );
      System.assertEquals(
        'Awaiting signal at step WaitDescTest.WaitStep',
        d.get('label'),
        'Label names the step and marks it as awaiting an inbound signal'
      );
    }
  }

  @IsTest
  static void testGenericSignalDescriptorForNullOutput() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // A no-arg suspend() nulls Output; still a signal wait when no resume job is attached.
      Map<String, Object> d = WorkflowWaitDescriptorService.describeSignalWait(
        suspendedInstance(null),
        oneStep(pendingStep('WaitDescTest.BareWaitStep', null))
      );
      System.assertNotEquals(
        null,
        d,
        'A null-output suspend still yields a descriptor'
      );
      System.assertEquals(
        WorkflowWaitDescriptorService.TYPE_GENERIC,
        d.get('type'),
        'Type is generic-signal'
      );
      System.assertEquals(
        'Awaiting signal at step WaitDescTest.BareWaitStep',
        d.get('label')
      );
    }
  }

  @IsTest
  static void testTimerWaitYieldsNoDescriptor() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // A sleep/retry parks a Pending step too but carries a resume job on the instance;
      // it must NOT be classified as a signal wait (unchanged-null, no regression).
      Map<String, Object> d = WorkflowWaitDescriptorService.describeSignalWait(
        suspendedInstance(ASYNC_JOB_ID),
        oneStep(pendingStep('WaitDescTest.SleepStep', '{"cursor":7}'))
      );
      System.assertEquals(
        null,
        d,
        'A timer/sleep wait (opaque state + resume job) yields no signal descriptor'
      );
    }
  }

  @IsTest
  static void testTimedApprovalStillClassifiedWithResumeJob() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // A timed approval carries a fallback timer yet is unambiguously a signal wait: its
      // marker must win even when a resume job is present.
      String output = JSON.serialize(
        new Map<String, Object>{
          'waitingForApproval' => true,
          'approvalKey' => 'TimedGate',
          'approvalRole' => null,
          '$timeoutStep' => 'WaitDescTest.Fallback'
        }
      );
      Map<String, Object> d = WorkflowWaitDescriptorService.describeSignalWait(
        suspendedInstance(ASYNC_JOB_ID),
        oneStep(pendingStep('WaitDescTest.TimedApproveStep', output))
      );
      System.assertNotEquals(
        null,
        d,
        'A timed approval is still a signal wait despite the fallback timer'
      );
      System.assertEquals('Approve:TimedGate', d.get('signalName'));
    }
  }

  @IsTest
  static void testOpaqueChildKeyWithoutWorkflowNameIsGeneric() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Issue #84 (Bug 1): opaque author state can legitimately carry a childCorrelationKey
      // without being a START_CHILD wait. WorkflowStepSuspension.handleStartChildOutcome writes
      // childWorkflowName alongside a REAL START_CHILD key, so its absence means this is a GENERIC
      // signal wait — a ChildCompleted:<key> suggestion (which could not unblock the generic wait)
      // must NOT be offered.
      String output = JSON.serialize(
        new Map<String, Object>{ 'childCorrelationKey' => 'order-42' }
      );
      Map<String, Object> d = WorkflowWaitDescriptorService.describeSignalWait(
        suspendedInstance(null),
        oneStep(pendingStep('WaitDescTest.OpaqueStep', output))
      );
      System.assertNotEquals(
        null,
        d,
        'An opaque suspend still yields a descriptor'
      );
      System.assertEquals(
        WorkflowWaitDescriptorService.TYPE_GENERIC,
        d.get('type'),
        'A childCorrelationKey without the START_CHILD childWorkflowName marker is a generic wait'
      );
      System.assertEquals(
        null,
        d.get('signalName'),
        'No child-completion name is suggested for opaque state'
      );
      System.assertEquals(
        null,
        d.get('childSignalNames'),
        'No child signal names are surfaced for opaque state'
      );
    }
  }

  @IsTest
  static void testRealStartChildStateStillChildCompletion() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // The counterpart to the opaque-key case: a REAL START_CHILD state carries the
      // childWorkflowName marker WorkflowStepSuspension writes, so it stays a child-completion wait.
      String output = JSON.serialize(
        new Map<String, Object>{
          'childWorkflowName' => 'WaitDescTest.ChildWorkflow',
          'childCorrelationKey' => 'order-99'
        }
      );
      Map<String, Object> d = WorkflowWaitDescriptorService.describeSignalWait(
        suspendedInstance(null),
        oneStep(pendingStep('WaitDescTest.ChildStep', output))
      );
      System.assertEquals(
        WorkflowWaitDescriptorService.TYPE_CHILD,
        d.get('type'),
        'A START_CHILD state with childWorkflowName is a child-completion wait'
      );
      System.assertEquals(
        'ChildCompleted:order-99',
        d.get('signalName'),
        'The awaited ChildCompleted:<key> stays injectable for a real START_CHILD wait'
      );
    }
  }

  @IsTest
  static void testSleepUntilTimerWithBlankAsyncYieldsNoDescriptorOnDetail() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Issue #84 (Bug 2): with dynamic scheduling off / limit-capped, scheduleSleepResume
      // returns null, so a sleep/admission/transient-retry park has a Pending step + BLANK async
      // id yet an armed Sleep_Until__c. With no explicit signal marker that is a pure TIMER wait,
      // not a signal wait, so it yields no signal descriptor (keying off the blank async id alone
      // would have mislabeled it "Awaiting signal").
      Workflow_Instance__c inst = suspendedInstance(null);
      inst.Sleep_Until__c = DateTime.now().addMinutes(5);
      Map<String, Object> d = WorkflowWaitDescriptorService.describeSignalWait(
        inst,
        oneStep(pendingStep('WaitDescTest.SleepNoJobStep', '{"cursor":9}'))
      );
      System.assertEquals(
        null,
        d,
        'A Sleep_Until__c timer with a blank async id is a timer wait, not a signal wait'
      );
    }
  }

  @IsTest
  static void testTimedApprovalWithSleepUntilStillClassifiedOnDetail() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // A timed approval (issue #35) persists the approval marker plus $timeoutStep and arms
      // Sleep_Until__c. Its explicit signal marker must win on the detail path: it stays an
      // approval descriptor even though a fallback timer is set.
      Workflow_Instance__c inst = suspendedInstance(null);
      inst.Sleep_Until__c = DateTime.now().addMinutes(10);
      String output = JSON.serialize(
        new Map<String, Object>{
          'waitingForApproval' => true,
          'approvalKey' => 'TimedSleepGate',
          'approvalRole' => null,
          '$timeoutStep' => 'WaitDescTest.Fallback'
        }
      );
      Map<String, Object> d = WorkflowWaitDescriptorService.describeSignalWait(
        inst,
        oneStep(pendingStep('WaitDescTest.TimedApproveStep', output))
      );
      System.assertNotEquals(
        null,
        d,
        'A timed approval is a signal wait despite the armed Sleep_Until__c'
      );
      System.assertEquals(
        WorkflowWaitDescriptorService.TYPE_APPROVAL,
        d.get('type'),
        'The approval marker wins over the armed Sleep_Until__c timer'
      );
      System.assertEquals('Approve:TimedSleepGate', d.get('signalName'));
    }
  }

  @IsTest
  static void testTimedSuspendMarkerStaysSignalOnDetail() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // A timed suspend persists {"$timeoutStep":...} and arms Sleep_Until__c. The $timeoutStep
      // marker is an explicit signal wait, so detail keeps a generic signal descriptor rather
      // than treating the armed deadline as a bare sleep timer.
      Workflow_Instance__c inst = suspendedInstance(null);
      inst.Sleep_Until__c = DateTime.now().addMinutes(10);
      String output = JSON.serialize(
        new Map<String, Object>{ '$timeoutStep' => 'WaitDescTest.Fallback' }
      );
      Map<String, Object> d = WorkflowWaitDescriptorService.describeSignalWait(
        inst,
        oneStep(pendingStep('WaitDescTest.TimedSuspendStep', output))
      );
      System.assertNotEquals(
        null,
        d,
        'A timed suspend marker is a signal wait despite the armed Sleep_Until__c'
      );
      System.assertEquals(
        WorkflowWaitDescriptorService.TYPE_GENERIC,
        d.get('type'),
        'A $timeoutStep-marked timed suspend stays a generic signal wait'
      );
    }
  }

  @IsTest
  static void testNonSuspendedYieldsNull() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = suspendedInstance(null);
      inst.Status__c = 'Completed';
      Map<String, Object> d = WorkflowWaitDescriptorService.describeSignalWait(
        inst,
        oneStep(pendingStep('WaitDescTest.Step', null))
      );
      System.assertEquals(
        null,
        d,
        'A non-Suspended instance has no wait descriptor'
      );
    }
  }

  @IsTest
  static void testNoPendingStepYieldsNull() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Step_Execution__c completed = pendingStep(
        'WaitDescTest.Done',
        null
      );
      completed.Status__c = 'Completed';
      Map<String, Object> d = WorkflowWaitDescriptorService.describeSignalWait(
        suspendedInstance(null),
        oneStep(completed)
      );
      System.assertEquals(
        null,
        d,
        'With no Pending step there is no parked signal wait'
      );
    }
  }

  @IsTest
  static void testMostRecentPendingStepWins() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      String older = JSON.serialize(
        new Map<String, Object>{ 'childCorrelationKey' => 'old-key' }
      );
      String newer = JSON.serialize(
        new Map<String, Object>{
          'waitingForApproval' => true,
          'approvalKey' => 'NewGate'
        }
      );
      // steps are supplied in CreatedDate-ascending order; the later Pending step wins.
      Map<String, Object> d = WorkflowWaitDescriptorService.describeSignalWait(
        suspendedInstance(null),
        new List<Workflow_Step_Execution__c>{
          pendingStep('WaitDescTest.OldStep', older),
          pendingStep('WaitDescTest.NewStep', newer)
        }
      );
      System.assertEquals(
        'Approve:NewGate',
        d.get('signalName'),
        'The most recent Pending step is the representative wait'
      );
    }
  }

  // ── Offloaded-payload rehydration ───────────────────────────────────────────

  @IsTest
  static void testOffloadedApprovalStateIsRehydrated() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = suspendedInstance(null);
      insert as system inst;

      String approvalState = JSON.serialize(
        new Map<String, Object>{
          'waitingForApproval' => true,
          'approvalKey' => 'OffloadedGate'
        }
      );
      // Store the state as a ContentVersion and reference it with the same offload marker
      // shape the engine writes, so the service must rehydrate to read the key.
      ContentVersion cv = new ContentVersion(
        Title = 'State_Approval_Offloaded',
        PathOnClient = 'State_Approval_Offloaded.json',
        VersionData = Blob.valueOf(approvalState)
      );
      insert as system cv;
      Id docId = [
        SELECT ContentDocumentId
        FROM ContentVersion
        WHERE Id = :cv.Id
      ]
      .ContentDocumentId;
      insert as system new ContentDocumentLink(
        ContentDocumentId = docId,
        LinkedEntityId = inst.Id,
        ShareType = 'V',
        Visibility = 'AllUsers'
      );
      String marker = JSON.serialize(
        new Map<String, String>{ '$attachmentId' => docId }
      );

      Test.startTest();
      Map<String, Object> d = WorkflowWaitDescriptorService.describeSignalWait(
        inst,
        oneStep(pendingStep('WaitDescTest.OffloadStep', marker))
      );
      Test.stopTest();

      System.assertNotEquals(
        null,
        d,
        'The offloaded approval state is rehydrated and classified'
      );
      System.assertEquals(
        'Approve:OffloadedGate',
        d.get('signalName'),
        'Signal name is derived from the rehydrated ContentVersion body'
      );
    }
  }

  @IsTest
  static void testListPathDoesNotRehydrateOffloadedBody() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Issue #84 / Option A: the bulk LIST path never selects Output__c and so never pulls an
      // offloaded ContentVersion body either (a page of such rows would blow the Apex heap).
      // Here the offloaded body is a full approval state: were it read + rehydrated, the
      // descriptor would classify as 'Approve:<key>'. Because the list reads no Output at all, it
      // emits only the lightweight, detail-deferred generic indicator and issues no body fetch.
      Workflow_Instance__c inst = suspendedInstance(null);
      insert as system inst;

      String approvalState = JSON.serialize(
        new Map<String, Object>{
          'waitingForApproval' => true,
          'approvalKey' => 'ListOffloadedGate'
        }
      );
      ContentVersion cv = new ContentVersion(
        Title = 'State_Approval_ListOffloaded',
        PathOnClient = 'State_Approval_ListOffloaded.json',
        VersionData = Blob.valueOf(approvalState)
      );
      insert as system cv;
      Id docId = [
        SELECT ContentDocumentId
        FROM ContentVersion
        WHERE Id = :cv.Id
      ]
      .ContentDocumentId;
      insert as system new ContentDocumentLink(
        ContentDocumentId = docId,
        LinkedEntityId = inst.Id,
        ShareType = 'V',
        Visibility = 'AllUsers'
      );
      String marker = JSON.serialize(
        new Map<String, String>{ '$attachmentId' => docId }
      );
      Workflow_Step_Execution__c step = pendingStepFor(
        inst.Id,
        'WaitDescTest.ListOffloadStep',
        marker
      );
      insert as system step;

      Test.startTest();
      Integer queriesBefore = Limits.getQueries();
      Map<Id, Map<String, Object>> byInstance = WorkflowWaitDescriptorService.describeSignalWaits(
        new List<Workflow_Instance__c>{ inst }
      );
      Integer queriesUsed = Limits.getQueries() - queriesBefore;
      Test.stopTest();

      Map<String, Object> d = byInstance.get(inst.Id);
      System.assertNotEquals(
        null,
        d,
        'The offloaded Suspended row still surfaces a wait descriptor'
      );
      System.assertEquals(
        WorkflowWaitDescriptorService.TYPE_GENERIC,
        d.get('type'),
        'The list did NOT rehydrate the offloaded approval body; it stays a generic descriptor'
      );
      System.assertEquals(
        null,
        d.get('signalName'),
        'A deferred list descriptor carries no injectable name (that is derived in detail)'
      );
      System.assertEquals(
        'Awaiting signal at step WaitDescTest.ListOffloadStep',
        d.get('label'),
        'The offloaded row gets the generic awaiting-signal label; detail derives the exact name'
      );
      // The definitive no-rehydration proof: a single pending-step query only — the offloaded
      // approval body was never fetched (a rehydration would add a ContentVersion query).
      System.assertEquals(
        1,
        queriesUsed,
        'The list path issues only the pending-step query, never a ContentVersion body fetch'
      );
    }
  }

  @IsTest
  static void testListPathDoesNotSelectOrClassifyOutput() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Option A (issue #84): the bulk LIST path must NOT select Output__c (a LongTextArea) at
      // all — even a small INLINE approval state. This is the query-shape proof: were Output__c
      // selected and classified, this row would come back as an 'Approve:InlineGate' approval
      // descriptor. Because the list query omits Output__c entirely, it can only emit the
      // lightweight generic "Awaiting signal" indicator; the exact type + name are derived in
      // detail. (The offloaded-body variant is covered by testListPathDoesNotRehydrateOffloadedBody.)
      Workflow_Instance__c inst = suspendedInstance(null);
      insert as system inst;
      insert as system pendingStepFor(
        inst.Id,
        'WaitDescTest.InlineApproveStep',
        JSON.serialize(
          new Map<String, Object>{
            'waitingForApproval' => true,
            'approvalKey' => 'InlineGate'
          }
        )
      );

      Test.startTest();
      Map<Id, Map<String, Object>> byInstance = WorkflowWaitDescriptorService.describeSignalWaits(
        new List<Workflow_Instance__c>{ inst }
      );
      Test.stopTest();

      Map<String, Object> d = byInstance.get(inst.Id);
      System.assertEquals(
        WorkflowWaitDescriptorService.TYPE_GENERIC,
        d.get('type'),
        'The list never selects/classifies Output__c, so even an inline approval stays generic'
      );
      System.assertEquals(
        null,
        d.get('signalName'),
        'A lightweight list descriptor carries no injectable name (that is derived in detail)'
      );
      System.assertEquals(
        'Awaiting signal at step WaitDescTest.InlineApproveStep',
        d.get('label'),
        'The list shows only the lightweight awaiting-signal indicator for the parked step'
      );
    }
  }

  @IsTest
  static void testListPathStaysHeapLightForLargeInlineOutput() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Heap proxy for the #84 fix: a large (~100KB) inline parked Output on a Suspended row
      // must not be materialized by the list path. The behavioral tell is that the row still
      // classifies as the lightweight generic indicator (Output was never read) while the whole
      // bulk resolution issues exactly ONE query (the pending-step label query) — no per-row or
      // Output-driven fan-out. A 100-row page of such states is what would otherwise blow heap.
      Workflow_Instance__c inst = suspendedInstance(null);
      insert as system inst;
      // A large inline approval state: if the list DID select + classify Output__c, this would
      // come back as an approval descriptor with a signalName. It must not.
      String bigApprovalState =
        '{"waitingForApproval":true,"approvalKey":"BigInlineGate","pad":"' +
        'x'.repeat(90000) +
        '"}';
      insert as system pendingStepFor(
        inst.Id,
        'WaitDescTest.BigInlineStep',
        bigApprovalState
      );

      Test.startTest();
      Integer queriesBefore = Limits.getQueries();
      Map<Id, Map<String, Object>> byInstance = WorkflowWaitDescriptorService.describeSignalWaits(
        new List<Workflow_Instance__c>{ inst }
      );
      Integer queriesUsed = Limits.getQueries() - queriesBefore;
      Test.stopTest();

      Map<String, Object> d = byInstance.get(inst.Id);
      System.assertEquals(
        WorkflowWaitDescriptorService.TYPE_GENERIC,
        d.get('type'),
        'A large inline Output is never read by the list path; the row stays a generic indicator'
      );
      System.assertEquals(
        1,
        queriesUsed,
        'The list resolves the whole page in one Output-free pending-step query'
      );
    }
  }

  @IsTest
  static void testSleepUntilTimerWithBlankAsyncYieldsNoDescriptorOnList() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Issue #84 (Bug 2), list path: an armed Sleep_Until__c with a blank async id (dynamic
      // scheduling off / limit-capped) is a sleep/retry/admission TIMER wait. The list reads the
      // parent Sleep_Until__c (no Output read) and must NOT show the lightweight "Awaiting signal"
      // indicator for it.
      Workflow_Instance__c inst = suspendedInstance(null);
      inst.Sleep_Until__c = DateTime.now().addMinutes(5);
      insert as system inst;
      insert as system pendingStepFor(
        inst.Id,
        'WaitDescTest.SleepListStep',
        '{"cursor":9}'
      );

      Test.startTest();
      Map<Id, Map<String, Object>> byInstance = WorkflowWaitDescriptorService.describeSignalWaits(
        new List<Workflow_Instance__c>{ inst }
      );
      Test.stopTest();

      System.assertEquals(
        null,
        byInstance.get(inst.Id),
        'A Sleep_Until__c timer with a blank async id shows no Awaiting-signal indicator on the list'
      );
    }
  }

  // ── End-to-end exposure on the read paths ───────────────────────────────────

  @IsTest
  static void testDescriptorOnListPath() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = suspendedInstance(null);
      inst.Correlation_Key__c = 'WaitDesc-List';
      insert as system inst;
      insert as system pendingStepFor(
        inst.Id,
        'WaitDescTest.ApproveStep',
        JSON.serialize(
          new Map<String, Object>{
            'waitingForApproval' => true,
            'approvalKey' => 'ListGate'
          }
        )
      );

      Test.startTest();
      List<Map<String, Object>> rows = WorkflowDashboardController.getFilteredInstances(
        WorkflowDashboardQueryBuilders.instanceQuery()
          .filter('', 'Suspended', '')
          .page(10, 0, '')
          .build()
      );
      Test.stopTest();

      System.assertEquals(1, rows.size(), 'The Suspended instance is listed');
      Map<String, Object> descriptor = (Map<String, Object>) rows[0]
        .get('waitDescriptor');
      System.assertNotEquals(
        null,
        descriptor,
        'The list row carries the lightweight wait indicator'
      );
      // Option A (issue #84): the list no longer selects/classifies Output__c, so even an
      // approval wait surfaces only the generic "Awaiting signal" indicator with no injectable
      // name. The exact Approve:<key> name is derived on the detail path (see
      // testDescriptorOnDetailPath) and is what the Send Signal modal pre-fills from.
      System.assertEquals(
        WorkflowWaitDescriptorService.TYPE_GENERIC,
        descriptor.get('type'),
        'The list indicator is the lightweight generic wait, not a full approval classification'
      );
      System.assertEquals(
        null,
        descriptor.get('signalName'),
        'The list indicator carries no awaited name (the detail view derives it)'
      );
      System.assertEquals(
        'Awaiting signal at step WaitDescTest.ApproveStep',
        descriptor.get('label'),
        'The list shows the lightweight awaiting-signal indicator for the parked step'
      );
    }
  }

  @IsTest
  static void testDescriptorOnDetailPath() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = suspendedInstance(null);
      inst.Correlation_Key__c = 'WaitDesc-Detail';
      insert as system inst;
      insert as system pendingStepFor(
        inst.Id,
        'WaitDescTest.ChildStep',
        JSON.serialize(
          new Map<String, Object>{
            'childWorkflowName' => 'WaitDescTest.Child',
            'childCorrelationKey' => 'detail-key'
          }
        )
      );

      Test.startTest();
      Map<String, Object> details = WorkflowDashboardController.getInstanceDetails(
        inst.Id
      );
      Test.stopTest();

      Map<String, Object> descriptor = (Map<String, Object>) details.get(
        'waitDescriptor'
      );
      System.assertNotEquals(
        null,
        descriptor,
        'The detail payload carries the awaited-signal descriptor'
      );
      System.assertEquals(
        'ChildCompleted:detail-key',
        descriptor.get('signalName'),
        'Detail descriptor names the awaited ChildCompleted signal'
      );
    }
  }

  @IsTest
  static void testTimerWaitHasNoDescriptorOnDetailPath() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // A Suspended instance on a sleep timer (resume job + opaque step state) must not
      // gain a signal descriptor — its existing waitingOn mechanism is unchanged.
      Workflow_Instance__c inst = suspendedInstance(ASYNC_JOB_ID);
      inst.Correlation_Key__c = 'WaitDesc-Timer';
      insert as system inst;
      insert as system pendingStepFor(
        inst.Id,
        'WaitDescTest.SleepStep',
        '{"cursor":1}'
      );

      Test.startTest();
      Map<String, Object> details = WorkflowDashboardController.getInstanceDetails(
        inst.Id
      );
      Test.stopTest();

      System.assertEquals(
        null,
        details.get('waitDescriptor'),
        'A timer/sleep wait yields no signal descriptor'
      );
    }
  }

  private static Workflow_Step_Execution__c pendingStepFor(
    Id instanceId,
    String stepName,
    String output
  ) {
    Workflow_Step_Execution__c se = pendingStep(stepName, output);
    se.Workflow_Instance__c = instanceId;
    return se;
  }
}
