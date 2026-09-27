/**
 * Round-trip test for the payload codec (issue #99).
 *
 * Each test runs one shipped example scenario two times: one time with the
 * identity codec and one time with an AES test codec. The test then compares
 * the harness results: status, completed steps, compensated steps and the
 * resolved output. They must be the same.
 *
 * Each run uses its own correlation key, so start dedup does not join the runs.
 * The AES run also reads the stored root Output__c. It must be an envelope, not
 * the plaintext output.
 *
 * Not covered here: examples that read Workflow_Signal__c.Payload__c or a child
 * Output__c directly with SOQL (Onboarding VIP approval, BatchFanout, the cursor
 * fan-outs, AgentConversation and AiSupportTriage). These reads skip the codec,
 * so the results change under an encrypting codec.
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

  // Replaces run-specific values (key, instance Id, masked fields) with
  // placeholders, so two runs can have the same output text.
  private static String normalize(
    String output,
    String key,
    Id instanceId,
    Set<String> maskedKeys
  ) {
    if (String.isBlank(output)) {
      return output;
    }
    String text = output.replace(String.valueOf(instanceId), '<instanceId>')
      .replace(key, '<key>');
    if (maskedKeys.isEmpty()) {
      return text;
    }
    Map<String, Object> data = (Map<String, Object>) JSON.deserializeUntyped(
      text
    );
    for (String maskedKey : maskedKeys) {
      if (data.containsKey(maskedKey)) {
        data.put(maskedKey, MASK);
      }
    }
    return JSON.serialize(data);
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
    System.assert(aes.encodeCount > 0, 'The AES run must use the codec');
    assertStoredOutput(identity, false);
    assertStoredOutput(encoded, true);
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

  // Source: OnboardingWorkflowExampleTest, with an amount below the VIP limit.
  // The VIP approval step reads Payload__c with SOQL and skips the codec.
  private static Snapshot runOnboarding(PayloadCodec codec, String key) {
    useCodec(codec);
    Id instanceId = WorkflowEngine.start(
      'OnboardingWorkflowExample',
      key,
      new Map<String, Object>{
        'amount' => 5000.0,
        'customerName' => 'Acme Corp',
        'email' => 'admin@acme.com'
      }
    );
    WorkflowTestHarness.Result result = new WorkflowTestHarness(instanceId)
      .drive();
    // completedDate is the current time, so mask it.
    return snap(result, key, new Set<String>{ 'completedDate' });
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
      AesCodec aes = new AesCodec();
      Snapshot encoded = runApprovalSignal(aes, 'CodecApprovalSig_Aes');

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
      Snapshot identity = runParallelSaga(
        null,
        'CodecParallel_Identity',
        false
      );
      Test.startTest();
      AesCodec aes = new AesCodec();
      Snapshot encoded = runParallelSaga(aes, 'CodecParallel_Aes', false);
      Test.stopTest();

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
      Snapshot identity = runParallelSaga(null, 'CodecRollback_Identity', true);
      Test.startTest();
      AesCodec aes = new AesCodec();
      Snapshot encoded = runParallelSaga(aes, 'CodecRollback_Aes', true);
      Test.stopTest();

      System.assertEquals('Compensated', identity.status);
      assertRoundTrip(identity, encoded, aes);
    }
  }

  @IsTest
  static void onboardingParallelChildSleepRoundTrips() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Snapshot identity = runOnboarding(null, 'CodecOnboarding_Identity');
      Test.startTest();
      AesCodec aes = new AesCodec();
      Snapshot encoded = runOnboarding(aes, 'CodecOnboarding_Aes');
      Test.stopTest();

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
}
