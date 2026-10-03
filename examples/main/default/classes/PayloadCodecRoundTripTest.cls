/**
 * Round-trip test for the payload codec (issue #99).
 *
 * Each test runs one shipped example scenario two times: one time with the
 * identity codec and one time with an AES test codec. The test then compares
 * the harness results: status, completed steps, compensated steps and the
 * resolved output. They must be the same.
 *
 * Each run uses its own correlation key, so start dedup does not join the runs.
 * The AES run also reads the stored root Output__c and Input__c. They must be
 * envelopes, not plaintext. The identity run runs before Test.startTest(), and
 * the AES run runs in it, so each run has its own governor limits. A scenario
 * that needs more than 100 SOQL queries for one run is a queueable job instead
 * (RunJob). Test.stopTest() runs the jobs, each with its own limits.
 *
 * Some scenarios also compare a detail text: the resolved root input, the
 * error message and each step payload, in audit order.
 *
 * Not covered here:
 * - RevenantCursorFanoutExample. Its dependency is not in this checkout.
 * - CalloutTimeoutWorkflowExampleTest: testCalloutSuccess,
 *   testCalloutFailureAndRetry, testAsyncCalloutJobAndFinalizerDirectly. They
 *   need Test.stopTest() to run a Queueable, and a method can call it one time
 *   only. The harness scenarios below use the same resume paths.
 *   testTimeoutTriggersSagaCompensation writes a compensation stack of a
 *   different workflow on the instance. It is not a real run.
 * - CircuitBreakerWorkflowExampleTest runStep tests, and
 *   SagaStalledRollbackExampleTest.testResumeCompensationIsIdempotent. They
 *   insert instance rows by hand, with no payloads.
 * - PatchExampleWorkflowTest: the mocked-date variants and the adoption count
 *   test. They use the same payload paths as the patch scenarios below.
 * - ParallelSignalFanInWorkflowExampleTest: the partial and case-variant ack
 *   tests. They drive one branch through WorkflowOrchestrator. The full-set
 *   scenario below uses the same signal payloads.
 * - Tests with no workflow run, or that stop at the first suspend: the ReAct
 *   parser tests, the unknown-tool ReAct test, the trigger bridge bulk and
 *   inactive-process tests, and the Opportunity non-Closed-Won test.
 */
@IsTest
private class PayloadCodecRoundTripTest {
  private static final String MASK = '<masked>';

  /** AES-256 test codec. It counts the encode calls. */
  private class AesCodec implements PayloadCodec {
    private final Blob key = Crypto.generateAesKey(256);
    private Integer encodeCount = 0;

    public String encode(String plaintext, CodecContext ctx) {
      encodeCount++;
      return EncodingUtil.base64Encode(
        Crypto.encryptWithManagedIV('AES256', key, Blob.valueOf(plaintext))
      );
    }

    public String decode(String stored, CodecContext ctx) {
      return Crypto.decryptWithManagedIV(
          'AES256',
          key,
          EncodingUtil.base64Decode(stored)
        )
        .toString();
    }
  }

  /** The parts of a harness result that must not change with the codec. */
  private class Snapshot {
    Id instanceId;
    String rawOutput;
    String status;
    List<String> completedSteps;
    List<String> compensatedSteps;
    String output;
    // Resolved input, error and step payloads. Null when not recorded.
    String detail;
    // How many values the AES codec encoded. Zero for an identity run.
    Integer encodeCount = 0;
  }

  private class CodecTestException extends Exception {
  }

  // Some scenarios need more than 100 SOQL queries for one run. A queueable job
  // has its own limits, and runs at Test.stopTest(). So each run of those
  // scenarios is one job. A job runs in its own transaction, so static state
  // does not reach the test. The job saves its snapshot in a log record. The
  // test reads the record after Test.stopTest().
  private static final String SNAPSHOT_LOG_TYPE = 'CodecTestSnapshot';

  /** One scenario run (identity or AES) in its own governor limits. */
  private class RunJob implements Queueable {
    private final String scenario;
    private final String slot;
    private final Boolean useAes;
    private final String key;
    private Boolean flag = false;
    private Decimal amount;
    private Id recordId;
    private List<String> replies;
    private String question;

    private RunJob(String scenario, String slot, Boolean useAes, String key) {
      this.scenario = scenario;
      this.slot = slot;
      this.useAes = useAes;
      this.key = key;
    }

    public void execute(QueueableContext context) {
      // A job can add only one more job. The harness drives the steps itself.
      WorkflowEngine.disableQueueableInTest = true;
      AesCodec aesInJob = useAes ? new AesCodec() : null;
      PayloadCodec codec = aesInJob;
      Snapshot result;
      if (scenario == 'PARALLEL_SAGA') {
        result = runParallelSaga(codec, key, flag);
      } else if (scenario == 'ONBOARDING') {
        result = runOnboarding(codec, key, amount);
      } else if (scenario == 'OPPORTUNITY') {
        result = runOpportunityOnboarding(codec, recordId);
      } else if (scenario == 'REACT') {
        result = runReAct(codec, key, replies, question);
      } else {
        result = runStalledRollback(codec, key);
      }
      result.encodeCount = aesInJob == null ? 0 : aesInJob.encodeCount;
      insert new Workflow_Log__c(
        Fire_Key__c = SNAPSHOT_LOG_TYPE + ':' + slot,
        Log_Type__c = SNAPSHOT_LOG_TYPE,
        Message__c = JSON.serialize(result)
      );
    }
  }

  // Runs the identity job and the AES job. Each has its own limits.
  private static void runJobs(RunJob identityJob, RunJob aesJob) {
    Test.startTest();
    System.enqueueJob(identityJob);
    System.enqueueJob(aesJob);
    Test.stopTest();
  }

  // Reads the snapshot that a job saved.
  private static Snapshot loadSnapshot(String slot) {
    Workflow_Log__c row = [
      SELECT Message__c
      FROM Workflow_Log__c
      WHERE Fire_Key__c = :(SNAPSHOT_LOG_TYPE + ':' + slot)
    ];
    return (Snapshot) JSON.deserialize(row.Message__c, Snapshot.class);
  }

  // A codec that reports the encode count of a job run.
  private static AesCodec codecFor(Snapshot encoded) {
    AesCodec codec = new AesCodec();
    codec.encodeCount = encoded.encodeCount;
    return codec;
  }

  // ─── helpers ────────────────────────────────────────────────────────────

  // Null selects the identity codec.
  private static void useCodec(PayloadCodec codec) {
    WorkflowPayloadCodecs.setCodec(codec);
  }

  private static Snapshot snap(
    WorkflowTestHarness.Result result,
    String key,
    Set<String> maskedKeys
  ) {
    Snapshot s = new Snapshot();
    s.instanceId = result.instanceId;
    s.rawOutput = result.output;
    s.status = result.status;
    s.completedSteps = result.completedSteps;
    s.compensatedSteps = result.compensatedSteps;
    s.output = normalize(result.output, key, result.instanceId, maskedKeys);
    return s;
  }

  // Also records the detail text. Each record Id changes to a placeholder.
  private static Snapshot snap(
    WorkflowTestHarness.Result result,
    String key,
    Set<String> maskedKeys,
    List<Id> recordIds
  ) {
    Snapshot s = snap(result, key, maskedKeys);
    List<String> values = tokens(key, result.instanceId, recordIds);
    s.output = normalize(result.output, values, maskedKeys);
    s.detail = detail(result.instanceId, values, maskedKeys);
    return s;
  }

  // Joins the resolved root input, the error message and each step payload.
  private static String detail(
    Id instanceId,
    List<String> values,
    Set<String> maskedKeys
  ) {
    Workflow_Instance__c inst = [
      SELECT Input__c, Error_Message__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
      WITH SYSTEM_MODE
    ];
    List<Workflow_Step_Execution__c> execs = [
      SELECT Step_Name__c, Status__c, Output__c
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c = :instanceId
      WITH SYSTEM_MODE
      ORDER BY CreatedDate ASC, Id ASC
    ];
    List<String> raw = new List<String>{ inst.Input__c };
    for (Workflow_Step_Execution__c exec : execs) {
      raw.add(exec.Output__c);
    }
    List<String> resolved = WorkflowPayloadOffload.resolvePayloads(
      raw,
      instanceId
    );
    List<String> lines = new List<String>{
      'input: ' + normalize(resolved[0], values, maskedKeys),
      'error: ' + normalize(inst.Error_Message__c, values, maskedKeys)
    };
    for (Integer i = 0; i < execs.size(); i++) {
      lines.add(
        execs[i].Step_Name__c +
          ' ' +
          execs[i].Status__c +
          ': ' +
          normalize(resolved[i + 1], values, maskedKeys)
      );
    }
    return String.join(lines, '\n');
  }

  // Run-specific values, in replace order. The instance Id and the key come
  // first, because a key can contain a record Id.
  private static List<String> tokens(
    String key,
    Id instanceId,
    List<Id> recordIds
  ) {
    List<String> values = new List<String>{ String.valueOf(instanceId), key };
    for (Id recordId : recordIds) {
      values.add(String.valueOf(recordId));
    }
    return values;
  }

  private static String placeholder(Integer index) {
    if (index == 0) {
      return '<instanceId>';
    }
    return index == 1 ? '<key>' : '<record' + (index - 2) + '>';
  }

  private static String normalize(
    String output,
    String key,
    Id instanceId,
    Set<String> maskedKeys
  ) {
    return normalize(
      output,
      tokens(key, instanceId, new List<Id>()),
      maskedKeys
    );
  }

  // Replaces run-specific values (key, instance Id, record Ids, masked fields)
  // with placeholders, so two runs can have the same output text. It also sorts
  // the JSON keys, because a child query can return rows in a different order.
  private static String normalize(
    String output,
    List<String> values,
    Set<String> maskedKeys
  ) {
    if (String.isBlank(output)) {
      return output;
    }
    String text = output;
    for (Integer i = 0; i < values.size(); i++) {
      text = text.replace(values[i], placeholder(i));
    }
    Object data;
    try {
      data = JSON.deserializeUntyped(text);
    } catch (JSONException e) {
      return text;
    }
    return JSON.serialize(canonical(data, maskedKeys));
  }

  // Sorts map keys and masks the named fields at all levels.
  private static Object canonical(Object value, Set<String> maskedKeys) {
    if (value instanceof Map<String, Object>) {
      Map<String, Object> source = (Map<String, Object>) value;
      List<String> keys = new List<String>(source.keySet());
      keys.sort();
      Map<String, Object> sorted = new Map<String, Object>();
      for (String k : keys) {
        sorted.put(
          k,
          maskedKeys.contains(k) ? MASK : canonical(source.get(k), maskedKeys)
        );
      }
      return sorted;
    }
    if (value instanceof List<Object>) {
      List<Object> items = new List<Object>();
      for (Object item : (List<Object>) value) {
        items.add(canonical(item, maskedKeys));
      }
      return items;
    }
    return value;
  }

  private static void assertRoundTrip(
    Snapshot identity,
    Snapshot encoded,
    AesCodec aes
  ) {
    System.assertEquals(
      identity.status,
      encoded.status,
      'Status must not change with the codec'
    );
    System.assertEquals(
      identity.completedSteps,
      encoded.completedSteps,
      'Completed steps must not change with the codec'
    );
    System.assertEquals(
      identity.compensatedSteps,
      encoded.compensatedSteps,
      'Compensated steps must not change with the codec'
    );
    System.assertEquals(
      identity.output,
      encoded.output,
      'Resolved output must not change with the codec'
    );
    System.assertEquals(
      identity.detail,
      encoded.detail,
      'Resolved input, error and step payloads must not change with the codec'
    );
    System.assert(aes.encodeCount > 0, 'The AES run must use the codec');
    assertStoredOutput(identity, false);
    assertStoredOutput(encoded, true);
    assertStoredInput(identity, false);
    assertStoredInput(encoded, true);
  }

  // Checks the stored root Input__c. It does not check an offload marker.
  private static void assertStoredInput(Snapshot s, Boolean expectEncoded) {
    String stored = [
      SELECT Input__c
      FROM Workflow_Instance__c
      WHERE Id = :s.instanceId
      WITH SYSTEM_MODE
    ]
    .Input__c;
    if (String.isBlank(stored) || stored.startsWith('{"$attachmentId":')) {
      return;
    }
    System.assertEquals(
      expectEncoded,
      WorkflowPayloadCodecs.isEncoded(stored),
      (expectEncoded
        ? 'The AES run must store an encoded input, got: '
        : 'The identity run must store a plaintext input, got: ') + stored
    );
  }

  // Returns the one instance with this correlation key.
  private static Id instanceIdFor(String key) {
    List<Workflow_Instance__c> rows = [
      SELECT Id
      FROM Workflow_Instance__c
      WHERE Correlation_Key__c = :key
      WITH SYSTEM_MODE
    ];
    System.assertEquals(1, rows.size(), 'One instance must have key ' + key);
    return rows[0].Id;
  }

  // Compares the stored root Output__c with the resolved output.
  private static void assertStoredOutput(Snapshot s, Boolean expectEncoded) {
    if (String.isBlank(s.rawOutput)) {
      return;
    }
    String stored = [
      SELECT Output__c
      FROM Workflow_Instance__c
      WHERE Id = :s.instanceId
      WITH SYSTEM_MODE
    ]
    .Output__c;
    if (expectEncoded) {
      System.assertNotEquals(
        s.rawOutput,
        stored,
        'The AES run must not store plaintext output'
      );
      System.assert(
        WorkflowPayloadCodecs.isEncoded(stored),
        'The AES run must store an envelope, got: ' + stored
      );
    } else {
      System.assertEquals(
        s.rawOutput,
        stored,
        'The identity run must store the output unchanged'
      );
    }
  }

  // ─── scenarios ──────────────────────────────────────────────────────────

  // Source: SagaWorkflowExampleTest.
  private static Snapshot runSaga(PayloadCodec codec, String key) {
    useCodec(codec);
    Id instanceId = WorkflowEngine.start(
      'SagaWorkflowExample.SagaWorkflow',
      key,
      '{"email":"test@example.com"}'
    );
    WorkflowTestHarness harness = new WorkflowTestHarness(instanceId);
    harness.failStep(
      'SagaWorkflowExample.SendWelcomeEmailStep',
      'SMTP Server Down'
    );
    return snap(harness.drive(), key, new Set<String>());
  }

  // Source: ApprovalWorkflowExampleTest (rejected round trip).
  private static Snapshot runApprovalReject(PayloadCodec codec, String key) {
    useCodec(codec);
    Id instanceId = WorkflowEngine.start(
      'ApprovalWorkflowExample',
      key,
      new Map<String, Object>{ 'purchaseAmount' => 9000 }
    );
    WorkflowTestHarness harness = new WorkflowTestHarness(instanceId);
    WorkflowTestHarness.Result suspended = harness.drive();
    System.assertEquals('Suspended', suspended.status);
    WorkflowTestHarness.Result done = harness.injectSignal(
      key,
      ApprovalWorkflowExample.DECISION_SIGNAL,
      '{"approved":false,"reason":"over budget"}'
    );
    return snap(done, key, new Set<String>());
  }

  // Source: ApprovalSignalWorkflowExampleTest (reject with a redelivered signal).
  private static Snapshot runApprovalSignal(PayloadCodec codec, String key) {
    useCodec(codec);
    Id instanceId = WorkflowEngine.start(
      'ApprovalSignalWorkflowExample',
      key,
      new Map<String, Object>{ 'amount' => 500 }
    );
    WorkflowTestHarness harness = new WorkflowTestHarness(instanceId);
    WorkflowTestHarness.Result suspended = harness.drive();
    System.assertEquals('Suspended', suspended.status);
    String decision = '{"approved":false,"reason":"budget"}';
    WorkflowEngine.signal(
      key,
      ApprovalSignalWorkflowExample.DECISION_SIGNAL,
      decision
    );
    WorkflowTestHarness.Result done = harness.injectSignal(
      key,
      ApprovalSignalWorkflowExample.DECISION_SIGNAL,
      decision
    );
    return snap(done, key, new Set<String>());
  }

  // Source: ChildWorkflowCompositionExampleTest (approve branch).
  private static Snapshot runChildComposition(PayloadCodec codec, String key) {
    useCodec(codec);
    Id parentId = WorkflowEngine.start(
      'ChildWorkflowCompositionExample',
      key,
      new Map<String, Object>{
        'applicant' => 'Alice',
        'annualIncome' => 100000,
        'requestedAmount' => 50000
      }
    );
    return snap(
      new WorkflowTestHarness(parentId).drive(),
      key,
      new Set<String>()
    );
  }

  // Source: ChildWorkflowFanOutExampleTest.
  private static Snapshot runChildFanOut(PayloadCodec codec, String key) {
    useCodec(codec);
    Id parentId = WorkflowEngine.start(
      'ChildWorkflowFanOutExample',
      key,
      new List<Map<String, Object>>{
        new Map<String, Object>{ 'id' => 'itemA', 'value' => 15 },
        new Map<String, Object>{ 'id' => 'itemB', 'value' => 25 },
        new Map<String, Object>{ 'id' => 'itemC', 'value' => 5 }
      }
    );
    return snap(
      new WorkflowTestHarness(parentId).drive(),
      key,
      new Set<String>()
    );
  }

  // Source: ContinueAsNewWorkflowExampleTest. The snapshot joins the status and
  // completed steps of each run in the chain. The output is from the last run.
  private static Snapshot runContinueAsNew(PayloadCodec codec, String key) {
    useCodec(codec);
    Id runId = WorkflowEngine.start(
      'ContinueAsNewWorkflowExample.PollerWorkflow',
      key,
      0
    );
    List<String> statuses = new List<String>();
    List<String> completed = new List<String>();
    WorkflowTestHarness.Result result;
    for (Integer run = 1; run <= 4; run++) {
      result = new WorkflowTestHarness(runId).drive();
      statuses.add(result.status);
      completed.addAll(result.completedSteps);
      if (result.status != 'ContinuedAsNew') {
        break;
      }
      runId = [
        SELECT Id
        FROM Workflow_Instance__c
        WHERE Previous_Instance__c = :runId
        WITH SYSTEM_MODE
      ]
      .Id;
    }
    Snapshot s = snap(result, key, new Set<String>());
    s.status = String.join(statuses, '>');
    s.completedSteps = completed;
    return s;
  }

  // Source: CaptureOnceWorkflowExampleTest.
  private static Snapshot runCaptureOnce(PayloadCodec codec, String key) {
    useCodec(codec);
    CaptureOnceWorkflowExample.resetProducerCounters();
    Id instanceId = WorkflowEngine.start(
      'CaptureOnceWorkflowExample.CaptureOnceWorkflow',
      key,
      null
    );
    WorkflowTestHarness.Result result = new WorkflowTestHarness(instanceId)
      .drive();
    System.assertEquals(
      1,
      CaptureOnceWorkflowExample.refNumberCalls,
      'Captures must survive the codec: one producer call'
    );
    System.assertEquals(1, CaptureOnceWorkflowExample.startedAtCalls);
    // refNumber and startedAt are random or time values, so mask them.
    return snap(result, key, new Set<String>{ 'refNumber', 'startedAt' });
  }

  // Source: ParallelSagaFanoutWorkflowExampleTest.
  private static Snapshot runParallelSaga(
    PayloadCodec codec,
    String key,
    Boolean failBranch3
  ) {
    useCodec(codec);
    ParallelSagaFanoutWorkflowExample.failBranch3 = failBranch3;
    ParallelSagaFanoutWorkflowExample.executionAudit.clear();
    ParallelSagaFanoutWorkflowExample.compensationAudit.clear();
    Id instanceId = WorkflowEngine.start(
      'ParallelSagaFanoutWorkflowExample.ParallelSagaWorkflow',
      key,
      '{}'
    );
    WorkflowTestHarness harness = new WorkflowTestHarness(instanceId);
    WorkflowTestHarness.Result suspended = harness.drive();
    System.assertEquals('Suspended', suspended.status);

    List<WorkflowEngine.SignalRequest> signals = new List<WorkflowEngine.SignalRequest>{
      new WorkflowEngine.SignalRequest(instanceId, 'Branch1_Complete', '{}'),
      new WorkflowEngine.SignalRequest(instanceId, 'Branch2_Complete', '{}'),
      new WorkflowEngine.SignalRequest(instanceId, 'Branch3_Complete', '{}')
    };
    if (!failBranch3) {
      signals.add(
        new WorkflowEngine.SignalRequest(instanceId, 'Branch4_Complete', '{}')
      );
    }
    WorkflowEngine.signal(signals);
    return snap(harness.drive(), key, new Set<String>());
  }

  // Source: OnboardingWorkflowExampleTest. An amount of 10000 or more waits for
  // the VIP approval signal. A smaller amount does not wait.
  private static Snapshot runOnboarding(
    PayloadCodec codec,
    String key,
    Decimal amount
  ) {
    useCodec(codec);
    Id instanceId = WorkflowEngine.start(
      'OnboardingWorkflowExample',
      key,
      new Map<String, Object>{
        'amount' => amount,
        'customerName' => 'Acme Corp',
        'email' => 'admin@acme.com'
      }
    );
    WorkflowTestHarness harness = new WorkflowTestHarness(instanceId);
    WorkflowTestHarness.Result result = harness.drive();
    if (amount >= 10000) {
      System.assertEquals('Suspended', result.status);
      result = harness.injectSignal(
        key,
        'Approve:VIPOrderApproval',
        '{"approved":true,"comments":"Approved VIP Customer"}'
      );
    }
    // completedDate is the current time, so mask it.
    return snap(result, key, new Set<String>{ 'completedDate' });
  }

  // Source: AgentConversationWorkflowExampleTest. The agent call uses the
  // mock responses of the example.
  private static Snapshot runAgentConversation(PayloadCodec codec, String key) {
    useCodec(codec);
    AgentConversationWorkflowExample.mockAgentResponses = new List<String>{
      'Thanks for reaching out. Could you tell me more about your account?',
      'I found your account. Your subscription has been renewed successfully.'
    };
    Id instanceId = WorkflowEngine.start(
      'AgentConversationWorkflowExample.AgentConversationWorkflow',
      key,
      new Map<String, Object>{
        'agentDeveloperName' => 'Support_Agent',
        'userMessage' => 'I need help with my subscription renewal.'
      }
    );
    WorkflowTestHarness harness = new WorkflowTestHarness(instanceId);
    WorkflowTestHarness.Result suspended = harness.drive();
    System.assertEquals('Suspended', suspended.status);
    WorkflowTestHarness.Result done = harness.injectSignal(
      key,
      'FollowUp',
      '{"message":"My account number is ACC-12345"}'
    );
    return snap(done, key, new Set<String>());
  }

  // Source: AiSupportTriageWorkflowExampleTest (human review path).
  private static Snapshot runTriageEscalation(PayloadCodec codec, String key) {
    useCodec(codec);
    AiSupportTriageWorkflowExample.mockAiClassification = 'escalate';
    Id instanceId = WorkflowEngine.start(
      'AiSupportTriageWorkflowExample.TriageWorkflow',
      key,
      new Map<String, Object>{
        'inquiryText' => 'This is an urgent legal matter, please contact me immediately.'
      }
    );
    WorkflowTestHarness harness = new WorkflowTestHarness(instanceId);
    WorkflowTestHarness.Result suspended = harness.drive();
    System.assertEquals('Suspended', suspended.status);
    WorkflowTestHarness.Result done = harness.injectSignal(
      key,
      'Approve:EscalationReview',
      '{"approved":true,"comments":"Escalation reviewed and resolved","approver":"Jane Smith"}'
    );
    return snap(done, key, new Set<String>());
  }

  // Source: BatchFanoutWorkflowExampleTest. Both runs use the same accounts.
  private static Snapshot runBatchFanout(PayloadCodec codec, String key) {
    useCodec(codec);
    Id parentId = WorkflowEngine.start(
      'BatchFanoutWorkflowExample.BatchFanoutWorkflow',
      key,
      null
    );
    // Each child output has the current time, so mask it.
    return snap(
      new WorkflowTestHarness(parentId).drive(),
      key,
      new Set<String>{ 'timestamp' }
    );
  }

  // Source: CursorFanoutWorkflowExampleTest. Both runs use the same accounts.
  private static Snapshot runCursorFanout(PayloadCodec codec, String key) {
    useCodec(codec);
    Id instanceId = WorkflowEngine.start(
      'CursorFanoutWorkflowExample.CursorFanoutWorkflow',
      key,
      null
    );
    return snap(
      new WorkflowTestHarness(instanceId).drive(),
      key,
      new Set<String>()
    );
  }

  // Source: OrderChoreographyWorkflowExampleTest. The order Id is the key, so
  // the downstream refund key is different for each run.
  private static Snapshot runOrderChoreography(PayloadCodec codec, String key) {
    useCodec(codec);
    WorkflowOutboundEventPublisher.publishedEvents.clear();
    OrderChoreographyWorkflowExample.resetCounters();
    Id shipmentId = WorkflowEngine.start(
      'OrderChoreographyWorkflowExample.ShipmentWorkflow',
      key,
      new Map<String, Object>{ 'orderId' => key }
    );
    WorkflowTestHarness.Result result = new WorkflowTestHarness(shipmentId)
      .drive();
    System.assertEquals(
      1,
      WorkflowOutboundEventPublisher.publishedEvents.size(),
      'One Order_Shipped__e must publish'
    );
    System.assertEquals(1, OrderChoreographyWorkflowExample.refundStartCount);
    return snap(result, key, new Set<String>());
  }

  // Source: AutoRetryWorkflowExampleTest. Without a receipt outage, the
  // gateway fails two times and the charge is retried. With a receipt outage,
  // the receipt fails fast, and the refund reads the charge id from the stored
  // charge output.
  private static Snapshot runAutoRetry(
    PayloadCodec codec,
    String key,
    Boolean receiptOutage
  ) {
    useCodec(codec);
    MockFlakyOrderServices.reset();
    MockFlakyOrderServices.gatewayOutagesLeft = receiptOutage ? 0 : 2;
    MockFlakyOrderServices.receiptOutagesLeft = receiptOutage ? 1 : 0;
    Id instanceId = WorkflowEngine.start(
      'AutoRetryWorkflowExample.OrderSaga',
      key,
      new Map<String, Object>{ 'orderId' => 'O-1001', 'amountCents' => 4200 }
    );
    WorkflowTestHarness.Result result = new WorkflowTestHarness(instanceId)
      .drive();
    System.assertEquals(
      1,
      MockFlakyOrderServices.effectiveCharges,
      'One effective charge'
    );
    return snap(result, key, new Set<String>(), new List<Id>());
  }

  // Source: RetryConfigWorkflowExampleTest. The partner API fails three
  // times. The operator record paces the retries.
  private static Snapshot runRetryConfig(PayloadCodec codec, String key) {
    useCodec(codec);
    MockPartnerApi.reset();
    MockPartnerApi.outagesLeft = 3;
    WorkflowRetryConfigResolver.mockRecords = new List<Workflow_Retry_Config__mdt>{
      new Workflow_Retry_Config__mdt(
        DeveloperName = 'PartnerSync',
        Workflow_Definition__c = 'RetryConfigWorkflowExample.PartnerSyncWorkflow',
        Maximum_Attempts__c = 6
      )
    };
    Id instanceId = WorkflowEngine.start(
      'RetryConfigWorkflowExample.PartnerSyncWorkflow',
      key,
      new Map<String, Object>{ 'orderId' => 'O-2001' }
    );
    WorkflowTestHarness.Result result = new WorkflowTestHarness(instanceId)
      .drive();
    System.assertEquals(4, MockPartnerApi.calls, 'Three retries, then 200');
    return snap(result, key, new Set<String>());
  }

  // Source: IdempotentChargeWorkflowExampleTest.
  private static Snapshot runIdempotentCharge(PayloadCodec codec, String key) {
    useCodec(codec);
    MockIdempotentPaymentGateway.reset();
    Id instanceId = WorkflowEngine.start(
      'IdempotentChargeWorkflowExample.ChargeWorkflow',
      key,
      new Map<String, Object>{ 'amountCents' => 4200 }
    );
    WorkflowTestHarness.Result result = new WorkflowTestHarness(instanceId)
      .drive();
    System.assertEquals(
      1,
      MockIdempotentPaymentGateway.effectiveSideEffectCount,
      'One effective charge'
    );
    return snap(result, key, new Set<String>());
  }

  // Source: VersionedWorkflowExampleTest (v2 routing).
  private static Snapshot runVersioned(PayloadCodec codec, String key) {
    useCodec(codec);
    Id instanceId = WorkflowEngine.start(
      'VersionedWorkflowExample.VersionedWorkflowImpl',
      key,
      null
    );
    return snap(
      new WorkflowTestHarness(instanceId).drive(),
      key,
      new Set<String>()
    );
  }

  // Source: CalloutTimeoutWorkflowExampleTest (async callout path). The step
  // suspends. The finalizer resumes it with an error, so the step retries and
  // suspends again. Then the callout job resumes it with the 200 response.
  private static Snapshot runCalloutAsyncResume(
    PayloadCodec codec,
    String key
  ) {
    useCodec(codec);
    CalloutTimeoutWorkflowExample.forceAsyncInTest = true;
    Id instanceId = WorkflowEngine.start(
      'CalloutTimeoutWorkflowExample.CalloutWorkflow',
      key,
      new Map<String, Object>{ 'endpoint' => 'https://httpbin.org/status/200' }
    );
    WorkflowTestHarness harness = new WorkflowTestHarness(instanceId);
    System.assertEquals('Suspended', harness.drive().status);

    new CalloutTimeoutWorkflowExample.ResumeFinalizer(instanceId)
      .handleResult(
        System.ParentJobResult.UNHANDLED_EXCEPTION,
        new CodecTestException('async job died')
      );
    System.assertEquals(
      'Suspended',
      harness.drive().status,
      'The retry must suspend for a new callout'
    );

    WorkflowResumeService.resumeInstance(
      instanceId,
      JSON.serialize(
        new Map<String, Object>{
          'status' => 200,
          'body' => '{"success": true}'
        }
      )
    );
    return snap(harness.drive(), key, new Set<String>(), new List<Id>());
  }

  // Source: CalloutTimeoutWorkflowExampleTest (watchdog timeout). The harness
  // fires the shipped timeout job. It does not write the status by hand.
  private static Snapshot runCalloutTimeout(PayloadCodec codec, String key) {
    useCodec(codec);
    Id instanceId = WorkflowEngine.start(
      'CalloutTimeoutWorkflowExample.CalloutWorkflow',
      key,
      new Map<String, Object>{ 'endpoint' => 'https://httpbin.org/status/500' }
    );
    // The step has a 60 second deadline, so the watchdog skips it. Expire the
    // deadline. The step makes no real callout in a test.
    Workflow_Step_Execution__c armed = [
      SELECT Id
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :instanceId
        AND Step_Name__c = 'CalloutTimeoutWorkflowExample.MakeHttpCalloutStep'
        AND Status__c = 'Pending'
        AND Timeout_At__c != NULL
      WITH SYSTEM_MODE
      LIMIT 1
    ];
    armed.Timeout_At__c = DateTime.now().addSeconds(-10);
    update as system armed;
    return snap(
      new WorkflowTestHarness(instanceId)
        .fireTimeout('CalloutTimeoutWorkflowExample.MakeHttpCalloutStep'),
      key,
      new Set<String>(),
      new List<Id>()
    );
  }

  // Source: CaseDebounceTriggerHandlerTest. Three Case edits start one
  // instance. The key has the Case Id, so each run has its own key.
  private static Snapshot runCaseDebounce(PayloadCodec codec) {
    useCodec(codec);
    WorkflowEngine.disableQueueableInTest = true;
    WorkflowEngine.mockNow = Datetime.now();
    Case c = new Case(
      Subject = 'Initial Subject',
      Description = 'Initial Description'
    );
    insert c;
    for (
      String subject : new List<String>{ 'Edit 1', 'Edit 2', 'Final Edit' }
    ) {
      c.Subject = subject;
      update c;
    }
    WorkflowEngine.mockNow = WorkflowEngine.mockNow.addSeconds(6);
    WorkflowEngine.processWatchdogHeartbeat();
    WorkflowEngine.mockNow = null;

    String key = 'Case_Debounce_' + c.Id;
    return snap(
      new WorkflowTestHarness(instanceIdFor(key)).drive(),
      key,
      new Set<String>(),
      new List<Id>{ c.Id }
    );
  }

  // Source: CircuitBreakerWorkflowExampleTest (started fleet). Two failures
  // open the breaker, the next instance parks, and a half-open probe completes
  // it. Each run starts with no breaker state.
  private static Snapshot runCircuitBreaker(PayloadCodec codec, String key) {
    useCodec(codec);
    CircuitBreakerWorkflowExample.reset();
    CircuitBreakerGate.mockConfigs.put(
      CircuitBreakerWorkflowExample.DEPENDENCY_KEY,
      (Circuit_Breaker_Config__mdt) JSON.deserialize(
        '{"DeveloperName":"ExternalPaymentsApi","Failure_Threshold__c":2,' +
          '"Rolling_Window_Seconds__c":300,"Open_Duration_Seconds__c":30,' +
          '"Half_Open_Probe_Count__c":1}',
        Circuit_Breaker_Config__mdt.class
      )
    );
    delete as system [
      SELECT Id
      FROM Circuit_Breaker_State__c
      WITH SYSTEM_MODE
    ];

    String wf = 'CircuitBreakerWorkflowExample.CircuitBreakerWorkflow';
    Id trip1 = WorkflowEngine.start(wf, key + '-trip1', null);
    Id trip2 = WorkflowEngine.start(wf, key + '-trip2', null);
    Id parked = WorkflowEngine.start(wf, key, null);
    System.assertEquals(
      'Failed',
      new WorkflowTestHarness(trip1).drive().status
    );
    System.assertEquals(
      'Failed',
      new WorkflowTestHarness(trip2).drive().status
    );

    WorkflowTestHarness harness = new WorkflowTestHarness(parked);
    harness.disableAutoTimeSkip = true;
    System.assert(
      harness.drive().isSleeping,
      'The open breaker must park the instance'
    );

    // The dependency heals, the open time ends and the sleep is due.
    CircuitBreakerWorkflowExample.dependencyHealthy = true;
    Circuit_Breaker_State__c breaker = [
      SELECT Id
      FROM Circuit_Breaker_State__c
      WHERE Dependency_Key__c = :CircuitBreakerWorkflowExample.DEPENDENCY_KEY
      WITH SYSTEM_MODE
    ];
    breaker.Opened_At__c = Datetime.now().addSeconds(-120);
    update as system breaker;
    Workflow_Instance__c sleeper = new Workflow_Instance__c(
      Id = parked,
      Sleep_Until__c = Datetime.now().addSeconds(-60)
    );
    update as system sleeper;

    harness.disableAutoTimeSkip = false;
    WorkflowEngine.processWatchdogHeartbeat();
    return snap(harness.drive(), key, new Set<String>(), new List<Id>());
  }

  // Source: DeadlineWorkflowExampleTest. The step suspends with a step state.
  // The watchdog fails the instance after the deadline.
  private static Snapshot runDeadline(PayloadCodec codec, String key) {
    useCodec(codec);
    WorkflowEngine.disableQueueableInTest = true;
    Id instanceId = WorkflowEngine.start('DeadlineWorkflowExample', key, null);
    WorkflowTestHarness harness = new WorkflowTestHarness(instanceId);
    System.assertEquals('Suspended', harness.drive().status);

    Workflow_Instance__c inst = [
      SELECT Id, Deadline_At__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
      WITH SYSTEM_MODE
    ];
    System.assertNotEquals(null, inst.Deadline_At__c);
    inst.Deadline_At__c = Datetime.now().addSeconds(-15);
    update as system inst;
    WorkflowEngine.processWatchdogHeartbeat();
    return snap(harness.inspect(), key, new Set<String>(), new List<Id>());
  }

  // Source: EventAggregationWorkflowExampleTest. Three events go to one
  // instance through signalOrStart. The step state keys are signal Ids, so
  // this scenario does not record the detail text.
  private static Snapshot runEventAggregation(PayloadCodec codec, String key) {
    useCodec(codec);
    WorkflowEngine.disableQueueableInTest = true;
    WorkflowEngine.StartRequest startReq = new WorkflowEngine.StartRequest(
      'EventAggregationWorkflowExample',
      key,
      null
    );
    Id instanceId;
    List<String> items = new List<String>{ '"Item-A"', '"Item-B"', '"Item-C"' };
    for (Integer i = 0; i < items.size(); i++) {
      instanceId = WorkflowEngine.signalOrStart(
          new WorkflowEngine.SignalOrStartRequest(
              startReq,
              EventAggregationWorkflowExample.EVENT_SIGNAL,
              items[i]
            )
            .withIdempotencyKey(key + '-E' + i)
        )
        .instanceId;
      WorkflowEngine.runStep(instanceId);
    }
    // The third event completes the accumulate step. Run the batch step.
    WorkflowEngine.runStep(instanceId);
    return snap(
      new WorkflowTestHarness(instanceId).inspect(),
      key,
      new Set<String>()
    );
  }

  // Source: IncrementalSyncWorkflowExampleTest. The snapshot joins the status
  // of two runs. The detail text is from the first run, because the second
  // run count depends on the clock.
  private static Snapshot runIncrementalSync(PayloadCodec codec, String key) {
    useCodec(codec);
    IncrementalSyncWorkflowExample.coldStartLookbackHours = 1;
    Id run1Id = WorkflowEngine.start(
      'IncrementalSyncWorkflowExample.SyncPollerWorkflow',
      key,
      null
    );
    Snapshot s = snap(
      new WorkflowTestHarness(run1Id).drive(),
      key,
      new Set<String>{ 'since' },
      new List<Id>()
    );
    Workflow_Instance__c run2 = [
      SELECT Id, Previous_Run_At__c
      FROM Workflow_Instance__c
      WHERE Previous_Instance__c = :run1Id
      WITH SYSTEM_MODE
    ];
    System.assertNotEquals(null, run2.Previous_Run_At__c);
    s.status += '>' + new WorkflowTestHarness(run2.Id).drive().status;
    return s;
  }

  // Source: NativeApprovalWorkflowExampleTest. Approve, or reject with a
  // redelivered decision signal.
  private static Snapshot runNativeApproval(
    PayloadCodec codec,
    String key,
    Boolean approve
  ) {
    useCodec(codec);
    Id instanceId = WorkflowEngine.start(
      'NativeApprovalWorkflowExample',
      key,
      new Map<String, Object>{ 'amount' => approve ? 500 : 1000 }
    );
    WorkflowTestHarness harness = new WorkflowTestHarness(instanceId);
    System.assertEquals('Suspended', harness.drive().status);
    WorkflowTestHarness.Result done;
    if (approve) {
      done = harness.injectSignal(
        key,
        NativeApprovalWorkflowExample.DECISION_SIGNAL,
        '{"approved":true,"approver":"manager@example.com"}'
      );
    } else {
      String decision = '{"approved":false,"comments":"duplicate test"}';
      WorkflowEngine.signal(
        key,
        NativeApprovalWorkflowExample.DECISION_SIGNAL,
        decision
      );
      WorkflowEngine.signal(
        key,
        NativeApprovalWorkflowExample.DECISION_SIGNAL,
        decision
      );
      done = harness.drive();
    }
    return snap(done, key, new Set<String>(), new List<Id>());
  }

  // Source: NativeApprovalTriggerBridgeExampleTest. The Case trigger starts the
  // workflow and sends the decision signal. The key is the Case Id.
  private static Snapshot runTriggerBridge(
    PayloadCodec codec,
    String approvalStatus
  ) {
    useCodec(codec);
    Case cse = new Case(Subject = 'Codec trigger bridge test');
    insert cse;
    String key = String.valueOf(cse.Id);
    WorkflowTestHarness harness = new WorkflowTestHarness(instanceIdFor(key));
    System.assertEquals('Suspended', harness.drive().status);
    cse.Approval_Status__c = approvalStatus;
    update cse;
    return snap(
      harness.drive(),
      key,
      new Set<String>(),
      new List<Id>{ cse.Id }
    );
  }

  // Source: OpportunityTriggerHandlerTest. Closed Won starts the onboarding
  // workflow. The amount is 25000, so it waits for the VIP approval signal.
  private static Snapshot runOpportunityOnboarding(
    PayloadCodec codec,
    Id accountId
  ) {
    useCodec(codec);
    Opportunity opp = new Opportunity(
      Name = 'Codec Onboarding Opp',
      AccountId = accountId,
      StageName = 'Prospecting',
      CloseDate = Date.today().addDays(30),
      Amount = 25000.00
    );
    insert opp;
    opp.StageName = 'Closed Won';
    update opp;

    String key = 'Opp_Onboarding_' + opp.Id;
    WorkflowTestHarness harness = new WorkflowTestHarness(instanceIdFor(key));
    System.assertEquals('Suspended', harness.drive().status);
    WorkflowTestHarness.Result done = harness.injectSignal(
      key,
      'Approve:VIPOrderApproval',
      '{"approved":true,"comments":"Approved VIP Customer"}'
    );
    // These values are random or time values, so mask them.
    return snap(
      done,
      key,
      new Set<String>{ 'completedDate', 'sandboxOrgId', 'billingAccountId' },
      new List<Id>{ opp.Id }
    );
  }

  // Source: ParallelSignalFanInWorkflowExampleTest. Kick and three acks are
  // buffered. The collector branch reads all acks with one getSignals() call.
  private static Snapshot runParallelSignalFanIn(
    PayloadCodec codec,
    String key
  ) {
    useCodec(codec);
    Id instanceId = WorkflowEngine.start(
      'ParallelSignalFanInWorkflowExample',
      key,
      null
    );
    WorkflowTestHarness harness = new WorkflowTestHarness(instanceId);
    System.assertEquals('Suspended', harness.drive().status);
    WorkflowEngine.signal(key, 'Kick', '{}');
    WorkflowEngine.signal(key, 'Ack:US', '{"ok":true}');
    WorkflowEngine.signal(key, 'Ack:EU', '{"ok":true}');
    return snap(
      harness.injectSignal(key, 'Ack:APAC', '{"ok":true}'),
      key,
      new Set<String>(),
      new List<Id>()
    );
  }

  // Source: PatchExampleWorkflowTest (brand-new instance takes the patch).
  private static Snapshot runPatchNew(PayloadCodec codec, String key) {
    useCodec(codec);
    Id instanceId = WorkflowEngine.start(
      'PatchExampleWorkflow.PatchSagaWorkflow',
      key,
      null
    );
    return snap(
      new WorkflowTestHarness(instanceId).drive(),
      key,
      new Set<String>(),
      new List<Id>()
    );
  }

  // Source: PatchExampleWorkflowTest (in-flight instance with a recorded false
  // decision). The seeded captures are plaintext, as rows from before a codec.
  private static Snapshot runPatchInFlight(PayloadCodec codec, String key) {
    useCodec(codec);
    Id instanceId = WorkflowEngine.start(
      'PatchExampleWorkflow.PatchSagaWorkflow',
      key,
      null
    );
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Id = instanceId,
      Current_Step__c = 'PatchExampleWorkflow.BookCar'
    );
    update as system inst;
    Workflow_Step_Execution__c hotel = new Workflow_Step_Execution__c(
      Workflow_Instance__c = instanceId,
      Step_Name__c = 'PatchExampleWorkflow.BookHotel',
      Status__c = 'Completed',
      Captured_Values__c = '{"hotelBooked":true,"__patch:insert-flight":false}'
    );
    insert as system hotel;
    return snap(
      new WorkflowTestHarness(instanceId).drive(),
      key,
      new Set<String>(),
      new List<Id>()
    );
  }

  // Source: PatchExampleWorkflowTest (retired patch fails the step). The
  // seeded step input and captures are plaintext.
  private static Snapshot runPatchRetired(PayloadCodec codec, String key) {
    useCodec(codec);
    Id instanceId = WorkflowEngine.start(
      'PatchExampleWorkflow.PatchSagaWorkflow',
      key,
      'triggerRetiredError'
    );
    Workflow_Step_Execution__c hotel = new Workflow_Step_Execution__c(
      Workflow_Instance__c = instanceId,
      Step_Name__c = 'PatchExampleWorkflow.BookHotel',
      Status__c = 'Running',
      Input__c = '"triggerRetiredError"',
      Captured_Values__c = '{"__patch:retired-patch":false}'
    );
    insert as system hotel;
    WorkflowTestHarness harness = new WorkflowTestHarness(instanceId);
    harness.step();
    return snap(harness.inspect(), key, new Set<String>(), new List<Id>());
  }

  // Source: ReActLoopWorkflowExampleTest. The model replies are mocks.
  private static Snapshot runReAct(
    PayloadCodec codec,
    String key,
    List<String> replies,
    String question
  ) {
    useCodec(codec);
    ReActLoopWorkflowExample.mockLlmResponses = replies;
    Id instanceId = WorkflowEngine.start(
      'ReActLoopWorkflowExample.ReActLoopWorkflow',
      key,
      new Map<String, Object>{ 'question' => question }
    );
    return snap(
      new WorkflowTestHarness(instanceId).drive(),
      key,
      new Set<String>(),
      new List<Id>()
    );
  }

  // Source: SagaStalledRollbackExampleTest. One compensation fails, the
  // rollback stops, and the operator resumes it. The snapshot joins the
  // stalled status and the last status.
  private static Snapshot runStalledRollback(PayloadCodec codec, String key) {
    useCodec(codec);
    WorkflowEngine.disableQueueableInTest = true;
    SagaStalledRollbackExample.failShipmentCompensation = true;
    Id instanceId = WorkflowEngine.start(
      'SagaStalledRollbackExample.StalledSagaWorkflow',
      key,
      '{"orderId":"ord_777"}'
    );
    // Charge, reserve, ship, book courier.
    for (Integer i = 0; i < 4; i++) {
      WorkflowEngine.runStep(instanceId, null);
    }
    try {
      WorkflowEngine.runStep(instanceId, null);
      System.assert(false, 'ConfirmDeliveryStep must throw');
    } catch (Exception ex) {
      WorkflowEngine.handleCrash(instanceId, ex);
    }
    // Courier compensation passes. Shipment compensation fails.
    WorkflowEngine.runStep(instanceId, null);
    WorkflowEngine.runStep(instanceId, null);
    String stalled = [
      SELECT Status__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
      WITH SYSTEM_MODE
    ]
    .Status__c;

    SagaStalledRollbackExample.failShipmentCompensation = false;
    WorkflowCompensation.resumeCompensation(instanceId);
    // Ship, reserve, charge, then the empty stack.
    for (Integer i = 0; i < 4; i++) {
      WorkflowEngine.runStep(instanceId, null);
    }
    Snapshot s = snap(
      new WorkflowTestHarness(instanceId).inspect(),
      key,
      new Set<String>(),
      new List<Id>()
    );
    s.status = stalled + '>' + s.status;
    return s;
  }

  // Source: ThrottledCalloutWorkflowExampleTest. The bucket holds one token,
  // so the second instance sleeps until the refill. Each run starts with no
  // limiter state.
  private static Snapshot runThrottledCallout(PayloadCodec codec, String key) {
    useCodec(codec);
    MockThrottledApi.reset();
    RateLimiter.mockConfigs.put(
      'ThrottledService',
      (Rate_Limit_Config__mdt) JSON.deserialize(
        '{"DeveloperName":"ThrottledService","Capacity__c":1.0,"Refill_Rate_Per_Second__c":0.001}',
        Rate_Limit_Config__mdt.class
      )
    );
    delete as system [SELECT Id FROM Rate_Limit_State__c WITH SYSTEM_MODE];

    String wf = 'ThrottledCalloutWorkflowExample.ThrottledCalloutWorkflow';
    Id first = WorkflowEngine.start(wf, key + '-first', null);
    Id second = WorkflowEngine.start(wf, key, null);
    System.assertEquals(
      'Completed',
      new WorkflowTestHarness(first).drive().status
    );
    WorkflowTestHarness harness = new WorkflowTestHarness(second);
    harness.disableAutoTimeSkip = true;
    System.assert(
      harness.drive().isSleeping,
      'The empty bucket must park the second instance'
    );

    Rate_Limit_State__c state = [
      SELECT Id, Last_Refill_Time_Ms__c
      FROM Rate_Limit_State__c
      WHERE Integration_Key__c = 'ThrottledService'
      WITH SYSTEM_MODE
      LIMIT 1
    ];
    state.Last_Refill_Time_Ms__c = state.Last_Refill_Time_Ms__c - 2000000;
    update as system state;

    harness.disableAutoTimeSkip = false;
    WorkflowTestHarness.Result done = harness.drive();
    System.assertEquals(2, MockThrottledApi.effects);
    System.assertEquals(2, MockThrottledApi.calls);
    return snap(done, key, new Set<String>(), new List<Id>());
  }

  // ─── tests ──────────────────────────────────────────────────────────────

  @IsTest
  static void sagaCompensationRoundTrips() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Snapshot identity = runSaga(null, 'CodecSaga_Identity');
      Test.startTest();
      AesCodec aes = new AesCodec();
      Snapshot encoded = runSaga(aes, 'CodecSaga_Aes');
      Test.stopTest();

      System.assertEquals('Compensated', identity.status);
      assertRoundTrip(identity, encoded, aes);
    }
  }

  @IsTest
  static void approvalRejectCompensationRoundTrips() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Snapshot identity = runApprovalReject(null, 'CodecApproval_Identity');
      Test.startTest();
      AesCodec aes = new AesCodec();
      Snapshot encoded = runApprovalReject(aes, 'CodecApproval_Aes');
      Test.stopTest();

      System.assertEquals('Compensated', identity.status);
      assertRoundTrip(identity, encoded, aes);
    }
  }

  @IsTest
  static void approvalSignalPayloadRoundTrips() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Snapshot identity = runApprovalSignal(null, 'CodecApprovalSig_Identity');
      Test.startTest();
      AesCodec aes = new AesCodec();
      Snapshot encoded = runApprovalSignal(aes, 'CodecApprovalSig_Aes');
      Test.stopTest();

      System.assertEquals('Completed', identity.status);
      System.assert(
        identity.output.contains('"reason":"budget"'),
        'The output must carry the signal payload, got: ' + identity.output
      );
      assertRoundTrip(identity, encoded, aes);
    }
  }

  @IsTest
  static void childWorkflowCompositionRoundTrips() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Snapshot identity = runChildComposition(null, 'CodecLoan_Identity');
      Test.startTest();
      AesCodec aes = new AesCodec();
      Snapshot encoded = runChildComposition(aes, 'CodecLoan_Aes');
      Test.stopTest();

      System.assertEquals('Completed', identity.status);
      System.assert(
        identity.output.contains('690'),
        'The output must carry the child credit score, got: ' + identity.output
      );
      assertRoundTrip(identity, encoded, aes);
    }
  }

  @IsTest
  static void childWorkflowFanOutRoundTrips() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Snapshot identity = runChildFanOut(null, 'CodecFanOut_Identity');
      Test.startTest();
      AesCodec aes = new AesCodec();
      Snapshot encoded = runChildFanOut(aes, 'CodecFanOut_Aes');
      Test.stopTest();

      System.assertEquals('Completed', identity.status);
      System.assert(
        identity.output.contains('"totalScore":90'),
        'The output must add the child scores, got: ' + identity.output
      );
      assertRoundTrip(identity, encoded, aes);
    }
  }

  @IsTest
  static void continueAsNewChainRoundTrips() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Snapshot identity = runContinueAsNew(null, 'CodecPoller_Identity');
      Test.startTest();
      AesCodec aes = new AesCodec();
      Snapshot encoded = runContinueAsNew(aes, 'CodecPoller_Aes');
      Test.stopTest();

      System.assertEquals(
        'ContinuedAsNew>ContinuedAsNew>ContinuedAsNew>Completed',
        identity.status
      );
      assertRoundTrip(identity, encoded, aes);
    }
  }

  @IsTest
  static void captureOnceRoundTrips() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Snapshot identity = runCaptureOnce(null, 'CodecCapture_Identity');
      Test.startTest();
      AesCodec aes = new AesCodec();
      Snapshot encoded = runCaptureOnce(aes, 'CodecCapture_Aes');
      Test.stopTest();

      System.assertEquals('Completed', identity.status);
      assertRoundTrip(identity, encoded, aes);
    }
  }

  @IsTest
  static void parallelSagaJoinRoundTrips() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      RunJob identityJob = new RunJob(
        'PARALLEL_SAGA',
        'identity',
        false,
        'CodecParallel_Identity'
      );
      RunJob aesJob = new RunJob(
        'PARALLEL_SAGA',
        'aes',
        true,
        'CodecParallel_Aes'
      );
      runJobs(identityJob, aesJob);
      Snapshot identity = loadSnapshot('identity');
      Snapshot encoded = loadSnapshot('aes');
      AesCodec aes = codecFor(encoded);

      System.assertEquals('Completed', identity.status);
      System.assert(
        identity.output.contains(
          'ParallelSagaFanoutWorkflowExample.Branch1Step'
        ),
        'The join output must carry the branch outputs, got: ' + identity.output
      );
      assertRoundTrip(identity, encoded, aes);
    }
  }

  @IsTest
  static void parallelSagaRollbackRoundTrips() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      RunJob identityJob = new RunJob(
        'PARALLEL_SAGA',
        'identity',
        false,
        'CodecRollback_Identity'
      );
      identityJob.flag = true;
      RunJob aesJob = new RunJob(
        'PARALLEL_SAGA',
        'aes',
        true,
        'CodecRollback_Aes'
      );
      aesJob.flag = true;
      runJobs(identityJob, aesJob);
      Snapshot identity = loadSnapshot('identity');
      Snapshot encoded = loadSnapshot('aes');
      AesCodec aes = codecFor(encoded);

      System.assertEquals('Compensated', identity.status);
      assertRoundTrip(identity, encoded, aes);
    }
  }

  @IsTest
  static void onboardingParallelChildSleepRoundTrips() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      RunJob identityJob = new RunJob(
        'ONBOARDING',
        'identity',
        false,
        'CodecOnboarding_Identity'
      );
      identityJob.amount = 5000;
      RunJob aesJob = new RunJob(
        'ONBOARDING',
        'aes',
        true,
        'CodecOnboarding_Aes'
      );
      aesJob.amount = 5000;
      runJobs(identityJob, aesJob);
      Snapshot identity = loadSnapshot('identity');
      Snapshot encoded = loadSnapshot('aes');
      AesCodec aes = codecFor(encoded);

      System.assertEquals('Completed', identity.status);
      assertRoundTrip(identity, encoded, aes);
    }
  }

  @IsTest
  static void orderChoreographyRoundTrips() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Snapshot identity = runOrderChoreography(null, 'CodecOrder_Identity');
      Test.startTest();
      AesCodec aes = new AesCodec();
      Snapshot encoded = runOrderChoreography(aes, 'CodecOrder_Aes');
      Test.stopTest();

      System.assertEquals('Completed', identity.status);
      assertRoundTrip(identity, encoded, aes);
    }
  }

  @IsTest
  static void idempotentChargeRoundTrips() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Snapshot identity = runIdempotentCharge(null, 'CodecCharge_Identity');
      Test.startTest();
      AesCodec aes = new AesCodec();
      Snapshot encoded = runIdempotentCharge(aes, 'CodecCharge_Aes');
      Test.stopTest();

      System.assertEquals('Completed', identity.status);
      System.assert(
        identity.output.contains('"amountCents":4200'),
        'The output must carry the input amount, got: ' + identity.output
      );
      assertRoundTrip(identity, encoded, aes);
    }
  }

  @IsTest
  static void versionedWorkflowRoundTrips() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Snapshot identity = runVersioned(null, 'CodecVersion_Identity');
      Test.startTest();
      AesCodec aes = new AesCodec();
      Snapshot encoded = runVersioned(aes, 'CodecVersion_Aes');
      Test.stopTest();

      System.assertEquals('Completed', identity.status);
      System.assert(identity.output.contains('"legacy":false'));
      assertRoundTrip(identity, encoded, aes);
    }
  }

  @IsTest
  static void onboardingVipApprovalRoundTrips() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      RunJob identityJob = new RunJob(
        'ONBOARDING',
        'identity',
        false,
        'CodecVip_Identity'
      );
      identityJob.amount = 15000;
      RunJob aesJob = new RunJob('ONBOARDING', 'aes', true, 'CodecVip_Aes');
      aesJob.amount = 15000;
      runJobs(identityJob, aesJob);
      Snapshot identity = loadSnapshot('identity');
      Snapshot encoded = loadSnapshot('aes');
      AesCodec aes = codecFor(encoded);

      System.assertEquals('Completed', identity.status);
      System.assert(
        identity.completedSteps.contains(
          'OnboardingWorkflowExample.VIPApprovalStep'
        ),
        'The VIP approval step must complete'
      );
      assertRoundTrip(identity, encoded, aes);
    }
  }

  @IsTest
  static void agentConversationRoundTrips() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Snapshot identity = runAgentConversation(null, 'CodecAgent_Identity');
      Test.startTest();
      AesCodec aes = new AesCodec();
      Snapshot encoded = runAgentConversation(aes, 'CodecAgent_Aes');
      Test.stopTest();

      System.assertEquals('Completed', identity.status);
      System.assert(
        identity.output.contains('renewed successfully'),
        'The output must carry the second agent turn, got: ' + identity.output
      );
      assertRoundTrip(identity, encoded, aes);
    }
  }

  @IsTest
  static void triageHumanReviewRoundTrips() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Snapshot identity = runTriageEscalation(null, 'CodecTriage_Identity');
      Test.startTest();
      AesCodec aes = new AesCodec();
      Snapshot encoded = runTriageEscalation(aes, 'CodecTriage_Aes');
      Test.stopTest();

      System.assertEquals('Completed', identity.status);
      System.assert(
        identity.output.contains('"reviewedBy":"Jane Smith"'),
        'The output must carry the signal payload, got: ' + identity.output
      );
      assertRoundTrip(identity, encoded, aes);
    }
  }

  @IsTest
  static void batchFanoutRoundTrips() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      insert new List<Account>{
        new Account(Name = 'Acme Corp'),
        new Account(Name = 'Stark Industries'),
        new Account(Name = 'Wayne Enterprises')
      };
      Snapshot identity = runBatchFanout(null, 'CodecBatch_Identity');
      Test.startTest();
      AesCodec aes = new AesCodec();
      Snapshot encoded = runBatchFanout(aes, 'CodecBatch_Aes');
      Test.stopTest();

      System.assertEquals('Completed', identity.status);
      System.assert(
        identity.output.contains('"totalProcessed":3'),
        'The output must count the child outputs, got: ' + identity.output
      );
      System.assert(
        identity.output.contains('Audited & Updated'),
        'The output must carry the child outputs, got: ' + identity.output
      );
      assertRoundTrip(identity, encoded, aes);
    }
  }

  @IsTest
  static void cursorFanoutRoundTrips() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      insert new List<Account>{
        new Account(Name = 'Account A'),
        new Account(Name = 'Account B'),
        new Account(Name = 'Account C'),
        new Account(Name = 'Account D'),
        new Account(Name = 'Account E')
      };
      Snapshot identity = runCursorFanout(null, 'CodecCursor_Identity');
      Test.startTest();
      AesCodec aes = new AesCodec();
      Snapshot encoded = runCursorFanout(aes, 'CodecCursor_Aes');
      Test.stopTest();

      System.assertEquals('Completed', identity.status);
      System.assert(
        identity.output.contains('"totalProcessed":5'),
        'The output must add the chunk counts, got: ' + identity.output
      );
      assertRoundTrip(identity, encoded, aes);
    }
  }

  @IsTest
  static void calloutAsyncResumeRoundTrips() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Snapshot identity = runCalloutAsyncResume(null, 'CodecCallout_Identity');
      Test.startTest();
      AesCodec aes = new AesCodec();
      Snapshot encoded = runCalloutAsyncResume(aes, 'CodecCallout_Aes');
      Test.stopTest();

      System.assertEquals('Completed', identity.status);
      System.assert(
        identity.output.contains('"status":200'),
        'The output must carry the resume payload, got: ' + identity.output
      );
      assertRoundTrip(identity, encoded, aes);
    }
  }

  @IsTest
  static void calloutWatchdogTimeoutRoundTrips() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Snapshot identity = runCalloutTimeout(null, 'CodecTimeout_Identity');
      Test.startTest();
      AesCodec aes = new AesCodec();
      Snapshot encoded = runCalloutTimeout(aes, 'CodecTimeout_Aes');
      Test.stopTest();

      System.assertEquals('Failed', identity.status);
      System.assert(
        identity.detail.contains('timed out'),
        'The error must name the timeout, got: ' + identity.detail
      );
      assertRoundTrip(identity, encoded, aes);
    }
  }

  @IsTest
  static void caseDebounceRoundTrips() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Snapshot identity = runCaseDebounce(null);
      Test.startTest();
      AesCodec aes = new AesCodec();
      Snapshot encoded = runCaseDebounce(aes);
      Test.stopTest();

      System.assertEquals('Completed', identity.status);
      System.assert(
        identity.detail.contains('"subject":"Final Edit"'),
        'The input must carry the last edit, got: ' + identity.detail
      );
      assertRoundTrip(identity, encoded, aes);
    }
  }

  @IsTest
  static void circuitBreakerRecoveryRoundTrips() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Snapshot identity = runCircuitBreaker(null, 'CodecBreaker_Identity');
      Test.startTest();
      AesCodec aes = new AesCodec();
      Snapshot encoded = runCircuitBreaker(aes, 'CodecBreaker_Aes');
      Test.stopTest();

      System.assertEquals('Completed', identity.status);
      assertRoundTrip(identity, encoded, aes);
    }
  }

  @IsTest
  static void deadlineRoundTrips() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Snapshot identity = runDeadline(null, 'CodecDeadline_Identity');
      Test.startTest();
      AesCodec aes = new AesCodec();
      Snapshot encoded = runDeadline(aes, 'CodecDeadline_Aes');
      Test.stopTest();

      System.assertEquals('Failed', identity.status);
      assertRoundTrip(identity, encoded, aes);
    }
  }

  @IsTest
  static void eventAggregationRoundTrips() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Snapshot identity = runEventAggregation(null, 'CodecCart_Identity');
      Test.startTest();
      AesCodec aes = new AesCodec();
      Snapshot encoded = runEventAggregation(aes, 'CodecCart_Aes');
      Test.stopTest();

      System.assertEquals('Completed', identity.status);
      System.assert(
        identity.output.contains('Processed 3 events: Item-A, Item-B, Item-C'),
        'The output must carry the three events, got: ' + identity.output
      );
      assertRoundTrip(identity, encoded, aes);
    }
  }

  @IsTest
  static void incrementalSyncRoundTrips() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      insert new Account(Name = 'Revenant Codec Account');
      Snapshot identity = runIncrementalSync(null, 'CodecSync_Identity');
      Test.startTest();
      AesCodec aes = new AesCodec();
      Snapshot encoded = runIncrementalSync(aes, 'CodecSync_Aes');
      Test.stopTest();

      System.assertEquals('ContinuedAsNew>ContinuedAsNew', identity.status);
      System.assert(
        identity.detail.contains('"processedCount":1'),
        'The first run must count the new account, got: ' + identity.detail
      );
      assertRoundTrip(identity, encoded, aes);
    }
  }

  @IsTest
  static void nativeApprovalApproveRoundTrips() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Snapshot identity = runNativeApproval(
        null,
        'CodecNativeOk_Identity',
        true
      );
      Test.startTest();
      AesCodec aes = new AesCodec();
      Snapshot encoded = runNativeApproval(aes, 'CodecNativeOk_Aes', true);
      Test.stopTest();

      System.assertEquals('Completed', identity.status);
      System.assert(
        identity.output.contains('"result":"approved"'),
        'The output must confirm the approval, got: ' + identity.output
      );
      assertRoundTrip(identity, encoded, aes);
    }
  }

  @IsTest
  static void nativeApprovalDuplicateRejectRoundTrips() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Snapshot identity = runNativeApproval(
        null,
        'CodecNativeNo_Identity',
        false
      );
      Test.startTest();
      AesCodec aes = new AesCodec();
      Snapshot encoded = runNativeApproval(aes, 'CodecNativeNo_Aes', false);
      Test.stopTest();

      System.assertEquals('Compensated', identity.status);
      System.assertEquals(
        new List<String>{
          'NativeApprovalWorkflowExample.ReserveBudgetStep_Compensate'
        },
        identity.compensatedSteps
      );
      System.assert(
        identity.detail.contains('duplicate test'),
        'The error must carry the signal comment, got: ' + identity.detail
      );
      assertRoundTrip(identity, encoded, aes);
    }
  }

  @IsTest
  static void triggerBridgeApproveRoundTrips() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Snapshot identity = runTriggerBridge(null, 'Approved');
      Test.startTest();
      AesCodec aes = new AesCodec();
      Snapshot encoded = runTriggerBridge(aes, 'Approved');
      Test.stopTest();

      System.assertEquals('Completed', identity.status);
      System.assert(
        identity.output.contains('"result":"approved"'),
        'The output must confirm the approval, got: ' + identity.output
      );
      assertRoundTrip(identity, encoded, aes);
    }
  }

  @IsTest
  static void triggerBridgeRejectRoundTrips() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Snapshot identity = runTriggerBridge(null, 'Rejected');
      Test.startTest();
      AesCodec aes = new AesCodec();
      Snapshot encoded = runTriggerBridge(aes, 'Rejected');
      Test.stopTest();

      System.assertEquals('Compensated', identity.status);
      assertRoundTrip(identity, encoded, aes);
    }
  }

  @IsTest
  static void opportunityOnboardingRoundTrips() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Account acc = new Account(Name = 'Test Account');
      insert acc;
      RunJob identityJob = new RunJob('OPPORTUNITY', 'identity', false, null);
      identityJob.recordId = acc.Id;
      RunJob aesJob = new RunJob('OPPORTUNITY', 'aes', true, null);
      aesJob.recordId = acc.Id;
      runJobs(identityJob, aesJob);
      Snapshot identity = loadSnapshot('identity');
      Snapshot encoded = loadSnapshot('aes');
      AesCodec aes = codecFor(encoded);

      System.assertEquals('Completed', identity.status);
      System.assert(
        identity.detail.contains('"email":"customer@testaccount.com"'),
        'The input must come from the Opportunity, got: ' + identity.detail
      );
      assertRoundTrip(identity, encoded, aes);
    }
  }

  @IsTest
  static void parallelSignalFanInRoundTrips() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Snapshot identity = runParallelSignalFanIn(null, 'CodecFanIn_Identity');
      Test.startTest();
      AesCodec aes = new AesCodec();
      Snapshot encoded = runParallelSignalFanIn(aes, 'CodecFanIn_Aes');
      Test.stopTest();

      System.assertEquals('Completed', identity.status);
      System.assert(
        identity.detail.contains('"count":3'),
        'The collector must see three acks, got: ' + identity.detail
      );
      assertRoundTrip(identity, encoded, aes);
    }
  }

  @IsTest
  static void patchNewInstanceRoundTrips() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Snapshot identity = runPatchNew(null, 'CodecPatchNew_Identity');
      Test.startTest();
      AesCodec aes = new AesCodec();
      Snapshot encoded = runPatchNew(aes, 'CodecPatchNew_Aes');
      Test.stopTest();

      System.assertEquals('Completed', identity.status);
      System.assert(
        identity.output.contains('"carType":"Luxury SUV"'),
        'A new instance must take the patch, got: ' + identity.output
      );
      assertRoundTrip(identity, encoded, aes);
    }
  }

  @IsTest
  static void patchInFlightRoundTrips() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Snapshot identity = runPatchInFlight(null, 'CodecPatchOld_Identity');
      Test.startTest();
      AesCodec aes = new AesCodec();
      Snapshot encoded = runPatchInFlight(aes, 'CodecPatchOld_Aes');
      Test.stopTest();

      System.assertEquals('Completed', identity.status);
      System.assert(
        identity.output.contains('"carType":"Economy Sedan"'),
        'The plaintext false decision must hold, got: ' + identity.output
      );
      assertRoundTrip(identity, encoded, aes);
    }
  }

  @IsTest
  static void patchRetiredRoundTrips() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Snapshot identity = runPatchRetired(null, 'CodecPatchRetired_Identity');
      Test.startTest();
      AesCodec aes = new AesCodec();
      Snapshot encoded = runPatchRetired(aes, 'CodecPatchRetired_Aes');
      Test.stopTest();

      System.assertEquals('Failed', identity.status);
      System.assert(
        identity.detail.contains('retired code path for patch: retired-patch'),
        'The error must name the retired patch, got: ' + identity.detail
      );
      assertRoundTrip(identity, encoded, aes);
    }
  }

  @IsTest
  static void reActToolLoopRoundTrips() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      List<String> replies = new List<String>{
        'Thought: I should look up Salesforce\'s FY2025 revenue.\nAction: Search[sfdc revenue]',
        'Thought: That is about $38 billion; the question asks for double that.\nAction: Calculator[38 * 2]',
        'Thought: I have computed the final answer.\nAction: Finish[76]'
      };
      String question = 'Roughly double Salesforce\'s FY2025 revenue in billions.';
      Snapshot identity = runReAct(
        null,
        'CodecReAct_Identity',
        replies,
        question
      );
      Test.startTest();
      AesCodec aes = new AesCodec();
      Snapshot encoded = runReAct(aes, 'CodecReAct_Aes', replies, question);
      Test.stopTest();

      System.assertEquals('Completed', identity.status);
      System.assert(
        identity.output.contains('"finalAnswer":"76"'),
        'The output must carry the answer, got: ' + identity.output
      );
      assertRoundTrip(identity, encoded, aes);
    }
  }

  @IsTest
  static void reActLoopGuardRoundTrips() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      List<String> replies = new List<String>();
      for (Integer i = 0; i < ReActLoopWorkflowExample.maxIterations; i++) {
        replies.add('Thought: Still looking.\nAction: Search[sfdc revenue]');
      }
      String question = 'A question the model can never answer.';
      RunJob identityJob = new RunJob(
        'REACT',
        'identity',
        false,
        'CodecReActGuard_Identity'
      );
      identityJob.replies = replies;
      identityJob.question = question;
      RunJob aesJob = new RunJob('REACT', 'aes', true, 'CodecReActGuard_Aes');
      aesJob.replies = replies;
      aesJob.question = question;
      runJobs(identityJob, aesJob);
      Snapshot identity = loadSnapshot('identity');
      Snapshot encoded = loadSnapshot('aes');
      AesCodec aes = codecFor(encoded);

      System.assertEquals('Completed', identity.status);
      System.assert(
        identity.output.contains('Could not reach a final answer'),
        'The loop guard must finish the run, got: ' + identity.output
      );
      assertRoundTrip(identity, encoded, aes);
    }
  }

  @IsTest
  static void stalledRollbackResumeRoundTrips() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      RunJob identityJob = new RunJob(
        'STALLED',
        'identity',
        false,
        'CodecStalled_Identity'
      );
      RunJob aesJob = new RunJob('STALLED', 'aes', true, 'CodecStalled_Aes');
      runJobs(identityJob, aesJob);
      Snapshot identity = loadSnapshot('identity');
      Snapshot encoded = loadSnapshot('aes');
      AesCodec aes = codecFor(encoded);

      System.assertEquals('CompensationFailed>Compensated', identity.status);
      assertRoundTrip(identity, encoded, aes);
    }
  }

  @IsTest
  static void throttledCalloutRoundTrips() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Snapshot identity = runThrottledCallout(null, 'CodecThrottle_Identity');
      Test.startTest();
      AesCodec aes = new AesCodec();
      Snapshot encoded = runThrottledCallout(aes, 'CodecThrottle_Aes');
      Test.stopTest();

      System.assertEquals('Completed', identity.status);
      assertRoundTrip(identity, encoded, aes);
    }
  }

  @IsTest
  static void autoRetryOutageRoundTrips() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Snapshot identity = runAutoRetry(null, 'CodecAutoRetry_Identity', false);
      Test.startTest();
      AesCodec aes = new AesCodec();
      Snapshot encoded = runAutoRetry(aes, 'CodecAutoRetry_Aes', false);
      Test.stopTest();

      System.assertEquals('Completed', identity.status);
      System.assertEquals(
        3,
        MockFlakyOrderServices.chargeAttempts,
        'The AES run retries the charge two times'
      );
      assertRoundTrip(identity, encoded, aes);
    }
  }

  @IsTest
  static void autoRetryReceiptRefundRoundTrips() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Snapshot identity = runAutoRetry(null, 'CodecRefund_Identity', true);
      Test.startTest();
      AesCodec aes = new AesCodec();
      Snapshot encoded = runAutoRetry(aes, 'CodecRefund_Aes', true);
      Test.stopTest();

      System.assertEquals('Compensated', identity.status);
      System.assertEquals(
        'ch_1',
        MockFlakyOrderServices.lastRefundedChargeId,
        'The AES refund reads the decoded charge id'
      );
      assertRoundTrip(identity, encoded, aes);
    }
  }

  @IsTest
  static void retryConfigOutageRoundTrips() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Snapshot identity = runRetryConfig(null, 'CodecRetryCfg_Identity');
      Test.startTest();
      AesCodec aes = new AesCodec();
      Snapshot encoded = runRetryConfig(aes, 'CodecRetryCfg_Aes');
      Test.stopTest();

      System.assertEquals('Completed', identity.status);
      assertRoundTrip(identity, encoded, aes);
    }
  }
}
