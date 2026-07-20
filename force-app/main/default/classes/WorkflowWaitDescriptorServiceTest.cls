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
      // Issue #84: the bulk LIST path must NOT pull an offloaded ContentVersion body (a page of
      // such rows would blow the Apex heap). Here the offloaded body is a full approval state:
      // if the list rehydrated it, the descriptor would classify as 'Approve:<key>'. Because the
      // list refuses to rehydrate, it instead emits the lightweight, detail-deferred descriptor.
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
  static void testListPathClassifiesInlineStateInFull() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // A small, non-offloaded (inline) approval state on the list path is still classified in
      // full — the heap-safe change only defers OFFLOADED states, not inline ones.
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
        WorkflowWaitDescriptorService.TYPE_APPROVAL,
        d.get('type'),
        'An inline approval state is fully classified on the list path'
      );
      System.assertEquals(
        'Approve:InlineGate',
        d.get('signalName'),
        'The inline approval yields the operator-injectable Approve:<key> signal'
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
        'The list row carries the awaited-signal descriptor'
      );
      System.assertEquals('Approve:ListGate', descriptor.get('signalName'));
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
