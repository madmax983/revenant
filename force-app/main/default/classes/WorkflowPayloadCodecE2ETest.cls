/**
 * End-to-end tests for the payload codec (issue #99). A workflow moves a
 * sensitive value through workflow input, step output (inline and offloaded),
 * step state, captures, progress, inbound signals and child-completion
 * signals. The tests scan every persistence surface for plaintext.
 */
@IsTest
public class WorkflowPayloadCodecE2ETest {
  public static final String SECRET = 'SSN-987-65-4321';
  public static final String SIGNAL = 'Approve';
  private static final String ENVELOPE_PREFIX = '{"$codec":';
  private static Blob aesKey;

  /** AES-256 codec. Tests load it by name, so it is public. */
  public class AesCodec implements PayloadCodec {
    private Blob key() {
      if (aesKey == null) {
        aesKey = Crypto.generateAesKey(256);
      }
      return aesKey;
    }

    public String encode(String plaintext, CodecContext ctx) {
      return EncodingUtil.base64Encode(
        Crypto.encryptWithManagedIV('AES256', key(), Blob.valueOf(plaintext))
      );
    }

    public String decode(String stored, CodecContext ctx) {
      return Crypto.decryptWithManagedIV(
          'AES256',
          key(),
          EncodingUtil.base64Decode(stored)
        )
        .toString();
    }
  }

  /** Parent workflow: receive, then start a child, then finish. */
  public class SecretWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{
        'WorkflowPayloadCodecE2ETest.ReceiveStep',
        'WorkflowPayloadCodecE2ETest.ChildWaitStep',
        'WorkflowPayloadCodecE2ETest.FinishStep'
      };
    }

    public String getInitialStep() {
      return 'WorkflowPayloadCodecE2ETest.ReceiveStep';
    }

    public String getNextStep(String currentStepName, StepResult result) {
      if (currentStepName == 'WorkflowPayloadCodecE2ETest.ReceiveStep') {
        return 'WorkflowPayloadCodecE2ETest.ChildWaitStep';
      }
      if (currentStepName == 'WorkflowPayloadCodecE2ETest.ChildWaitStep') {
        return 'WorkflowPayloadCodecE2ETest.FinishStep';
      }
      return null;
    }
  }

  /** Produces a capture value that holds the secret. */
  public class SecretProducer implements CaptureProducer {
    public Object produce() {
      return 'captured:' + SECRET;
    }
  }

  /**
   * Writes the secret to captures, progress and step state. Waits for the
   * signal. Then completes with a large output, so the engine offloads it.
   */
  public class ReceiveStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      Object captured = ctx.captures().once('secret', new SecretProducer());
      ctx.progress()
        .reportProgress(new Map<String, Object>{ 'note' => SECRET });
      StepContext.Signal sig = ctx.signals().getSignal(SIGNAL);
      if (!sig.isPresent()) {
        return StepResult.suspend()
          .withStepState(
            JSON.serialize(new Map<String, Object>{ 'waiting' => SECRET })
          );
      }
      return StepResult.complete(
        null,
        new Map<String, Object>{
          'input' => ctx.workflowInputJson,
          'signal' => sig.payload,
          'captured' => captured,
          'big' => SECRET + 'x'.repeat(100001)
        }
      );
    }
  }

  /** Starts the child. Then reads the child outcome. */
  public class ChildWaitStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      String childKey = 'codec-child-' + ctx.workflowInstanceId;
      StepContext.ChildOutcome outcome = ctx.signals()
        .getChildOutcome(childKey);
      if (!outcome.isPresent()) {
        return StepResult.startChild(
          'WorkflowPayloadCodecE2ETest.ChildWorkflow',
          childKey,
          new Map<String, Object>{ 'secret' => SECRET }
        );
      }
      Map<String, Object> prev = (Map<String, Object>) JSON.deserializeUntyped(
        ctx.previousStepOutput
      );
      return StepResult.complete(
        null,
        new Map<String, Object>{
          'child' => outcome.output,
          'signal' => prev.get('signal'),
          'bigHasSecret' => ((String) prev.get('big')).startsWith(SECRET),
          'captured' => prev.get('captured'),
          'input' => prev.get('input')
        }
      );
    }
  }

  /** Completes with the previous output, so the workflow output holds it. */
  public class FinishStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(
        null,
        JSON.deserializeUntyped(ctx.previousStepOutput)
      );
    }
  }

  /** One-step child workflow. It returns the secret. */
  public class ChildWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowPayloadCodecE2ETest.ChildStep' };
    }

    public String getInitialStep() {
      return 'WorkflowPayloadCodecE2ETest.ChildStep';
    }

    public String getNextStep(String currentStepName, StepResult result) {
      return null;
    }
  }

  /** Returns the child input. */
  public class ChildStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(
        null,
        new Map<String, Object>{ 'childInput' => ctx.workflowInputJson }
      );
    }
  }

  // ─── helpers ────────────────────────────────────────────────────────────

  private static WorkflowTestHarness.Result runSecretWorkflow(String key) {
    Id instanceId = WorkflowEngine.start(
      'WorkflowPayloadCodecE2ETest.SecretWorkflow',
      key,
      new Map<String, Object>{ 'ssn' => SECRET }
    );
    WorkflowTestHarness harness = new WorkflowTestHarness(instanceId);
    WorkflowTestHarness.Result waiting = harness.drive();
    System.assertEquals('Suspended', waiting.status, 'Waits for the signal');
    return harness.injectSignal(
      key,
      SIGNAL,
      JSON.serialize(new Map<String, Object>{ 'approver' => SECRET })
    );
  }

  private static void assertResolvedOutput(WorkflowTestHarness.Result r) {
    System.assertEquals('Completed', r.status, 'Workflow must complete');
    Map<String, Object> out = (Map<String, Object>) JSON.deserializeUntyped(
      r.output
    );
    System.assert(
      String.valueOf(out.get('input')).contains(SECRET),
      'Step sees decoded workflow input'
    );
    System.assert(
      String.valueOf(out.get('signal')).contains(SECRET),
      'Step sees decoded signal payload'
    );
    System.assertEquals(
      'captured:' + SECRET,
      out.get('captured'),
      'Step sees decoded capture'
    );
    System.assertEquals(true, out.get('bigHasSecret'), 'Offload round-trips');
    System.assert(
      String.valueOf(out.get('child')).contains(SECRET),
      'Parent sees decoded child output'
    );
  }

  // Returns every stored payload value on the four persistence surfaces.
  private static List<String> storedPayloads() {
    List<String> values = new List<String>();
    for (Workflow_Instance__c inst : [
      SELECT Input__c, Output__c, Progress__c
      FROM Workflow_Instance__c
    ]) {
      values.add(inst.Input__c);
      values.add(inst.Output__c);
      values.add(inst.Progress__c);
    }
    for (Workflow_Step_Execution__c se : [
      SELECT Input__c, Output__c, Captured_Values__c
      FROM Workflow_Step_Execution__c
    ]) {
      values.add(se.Input__c);
      values.add(se.Output__c);
      values.add(se.Captured_Values__c);
    }
    for (Workflow_Signal__c sig : [SELECT Payload__c FROM Workflow_Signal__c]) {
      values.add(sig.Payload__c);
    }
    for (ContentVersion cv : [SELECT VersionData FROM ContentVersion]) {
      values.add(cv.VersionData.toString());
    }
    return values;
  }

  private static Integer countContaining(List<String> values, String needle) {
    Integer hits = 0;
    for (String v : values) {
      if (v != null && v.contains(needle)) {
        hits++;
      }
    }
    return hits;
  }

  // ─── AC: no plaintext at rest ───────────────────────────────────────────

  @IsTest
  static void aesCodecLeavesNoPlaintextAtRest() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowPayloadCodecs.setCodec(new AesCodec());

      WorkflowTestHarness.Result r = runSecretWorkflow('codec-scan');

      assertResolvedOutput(r);
      List<String> values = storedPayloads();
      System.assertEquals(
        0,
        countContaining(values, SECRET),
        'No plaintext secret on any persistence surface'
      );
      System.assert(
        countContaining(values, ENVELOPE_PREFIX) > 0,
        'Payloads are encoded'
      );
      System.assert(
        [SELECT COUNT() FROM ContentVersion] > 0,
        'The large output must use the offload path'
      );
      for (Workflow_Signal__c sig : [
        SELECT Signal_Name__c, Payload__c
        FROM Workflow_Signal__c
      ]) {
        System.assert(
          sig.Payload__c.startsWith(ENVELOPE_PREFIX),
          'Signal payload is encoded: ' + sig.Signal_Name__c
        );
      }
      Workflow_Instance__c root = [
        SELECT Input__c, Progress__c, Status__c
        FROM Workflow_Instance__c
        WHERE Id = :r.instanceId
      ];
      System.assert(root.Input__c.startsWith(ENVELOPE_PREFIX));
      System.assert(root.Progress__c.startsWith(ENVELOPE_PREFIX));
      System.assertEquals('Completed', root.Status__c, 'Status stays plain');
    }
  }

  // ─── AC: identity default keeps bytes ───────────────────────────────────

  @IsTest
  static void identityCodecKeepsLegacyBytes() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowTestHarness.Result r = runSecretWorkflow('codec-identity');

      assertResolvedOutput(r);
      List<String> values = storedPayloads();
      System.assertEquals(
        0,
        countContaining(values, ENVELOPE_PREFIX),
        'Identity adds no envelope'
      );
      Workflow_Instance__c root = [
        SELECT Input__c
        FROM Workflow_Instance__c
        WHERE Id = :r.instanceId
      ];
      System.assertEquals(
        JSON.serialize(new Map<String, Object>{ 'ssn' => SECRET }),
        root.Input__c,
        'Identity stores the input byte for byte'
      );
    }
  }

  // ─── AC: round-trip equivalence ─────────────────────────────────────────

  @IsTest
  static void aesResultMatchesIdentityResult() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowTestHarness.Result plain = runSecretWorkflow('codec-rt-plain');
      WorkflowPayloadCodecs.setCodec(new AesCodec());
      WorkflowTestHarness.Result aes = runSecretWorkflow('codec-rt-aes');

      System.assertEquals(plain.status, aes.status);
      System.assertEquals(plain.completedSteps, aes.completedSteps);
      System.assertEquals(plain.compensatedSteps, aes.compensatedSteps);
      System.assertEquals(plain.output, aes.output, 'Same resolved output');
    }
  }

  // ─── AC: append-only; decode is read-only ───────────────────────────────

  @IsTest
  static void readsDoNotRewriteStoredPayloads() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowPayloadCodecs.setCodec(new AesCodec());
      WorkflowTestHarness.Result r = runSecretWorkflow('codec-append');
      Map<Id, Workflow_Step_Execution__c> before = new Map<Id, Workflow_Step_Execution__c>(
        [
          SELECT Input__c, Output__c, Captured_Values__c
          FROM Workflow_Step_Execution__c
        ]
      );

      Integer dmlBefore = Limits.getDmlStatements();
      WorkflowStatusRead.getStatus(new List<Id>{ r.instanceId });
      new WorkflowTestHarness(r.instanceId).inspect();
      for (Workflow_Step_Execution__c se : before.values()) {
        WorkflowPayloadOffload.resolvePayloads(
          new List<String>{ se.Input__c, se.Output__c, se.Captured_Values__c }
        );
      }
      System.assertEquals(
        dmlBefore,
        Limits.getDmlStatements(),
        'Reads do no DML'
      );

      // AES uses a random IV. A second encode gives new ciphertext, so equal
      // values prove that no read wrote a step row again.
      for (Workflow_Step_Execution__c se : [
        SELECT Input__c, Output__c, Captured_Values__c
        FROM Workflow_Step_Execution__c
      ]) {
        Workflow_Step_Execution__c old = before.get(se.Id);
        System.assertEquals(old.Input__c, se.Input__c);
        System.assertEquals(old.Output__c, se.Output__c);
        System.assertEquals(old.Captured_Values__c, se.Captured_Values__c);
      }
    }
  }

  // ─── read APIs decode ───────────────────────────────────────────────────

  @IsTest
  static void statusApiReturnsDecodedOutput() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowPayloadCodecs.setCodec(new AesCodec());
      WorkflowTestHarness.Result r = runSecretWorkflow('codec-status');

      WorkflowEngine.WorkflowStatus status = WorkflowStatusRead.getStatus(
        new List<Id>{ r.instanceId }
      )[0];
      System.assertEquals(r.output, status.output, 'getStatus decodes');
    }
  }

  // ─── dashboard shows a redacted placeholder ─────────────────────────────

  @IsTest
  static void dashboardRedactsEncodedPayloads() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowPayloadCodecs.setCodec(new AesCodec());
      WorkflowTestHarness.Result r = runSecretWorkflow('codec-dashboard');
      Workflow_Instance__c inst = [
        SELECT Id, Input__c, Output__c, Progress__c
        FROM Workflow_Instance__c
        WHERE Id = :r.instanceId
      ];
      List<Workflow_Step_Execution__c> steps = [
        SELECT Id, Input__c, Output__c
        FROM Workflow_Step_Execution__c
        WHERE Workflow_Instance__c = :r.instanceId
      ];

      Map<String, Object> files = WorkflowPayloadService.resolvePayloadsInBulk(
        inst,
        steps
      );

      System.assertEquals(
        WorkflowPayloadService.REDACTED_PAYLOAD,
        inst.Input__c,
        'Dashboard does not decode'
      );
      System.assertEquals(
        WorkflowPayloadService.REDACTED_PAYLOAD,
        inst.Output__c
      );
      for (Workflow_Step_Execution__c se : steps) {
        System.assert(
          se.Output__c == null || !se.Output__c.contains(SECRET),
          'No step payload is decoded on the dashboard'
        );
      }
      System.assert(files.isEmpty(), 'No download link for ciphertext');
      JSON.deserializeUntyped(WorkflowPayloadService.REDACTED_PAYLOAD);
    }
  }

  // ─── AC: control values stay plaintext ──────────────────────────────────

  @IsTest
  static void signalDedupUsesPlaintextKey() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowPayloadCodecs.setCodec(new AesCodec());
      Id instanceId = WorkflowEngine.start(
        'WorkflowPayloadCodecE2ETest.SecretWorkflow',
        'codec-dedup',
        new Map<String, Object>{ 'ssn' => SECRET }
      );
      new WorkflowTestHarness(instanceId).drive();

      for (Integer i = 0; i < 2; i++) {
        WorkflowEngine.SignalRequest req = new WorkflowEngine.SignalRequest(
          'codec-dedup',
          'Other',
          '{"n":' + i + '}'
        );
        req.idempotencyKey = 'same-key';
        WorkflowEngine.signal(req);
      }

      List<Workflow_Signal__c> rows = [
        SELECT Signal_Key__c, Payload__c
        FROM Workflow_Signal__c
        WHERE Workflow_Instance__c = :instanceId AND Signal_Name__c = 'Other'
      ];
      System.assertEquals(1, rows.size(), 'Dedup works under the codec');
      System.assertEquals(
        WorkflowSignalDedup.deriveSignalDedupKey(instanceId, 'same-key'),
        rows[0].Signal_Key__c,
        'Dedup key comes from plaintext'
      );
      System.assert(rows[0].Payload__c.startsWith(ENVELOPE_PREFIX));
    }
  }

  // ─── debounce input is workflow input at rest ───────────────────────────

  @IsTest
  static void debounceInputIsEncodedOnce() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowPayloadCodecs.setCodec(new AesCodec());
      WorkflowEngine.disableQueueableInTest = true;
      WorkflowEngine.mockNow = Datetime.now();
      String input = '{"ssn":"' + SECRET + '"}';

      Test.startTest();
      WorkflowStartService.startDebounced(
        new WorkflowDebouncer.DebounceRequest(
            'WorkflowPayloadCodecE2ETest.SecretWorkflow',
            'codec-debounce',
            input
          )
          .withDebounce(10)
      );
      Debounce_State__c state = [
        SELECT Input_Json__c
        FROM Debounce_State__c
        WHERE Correlation_Key__c = 'codec-debounce'
      ];
      System.assert(state.Input_Json__c.startsWith(ENVELOPE_PREFIX));
      System.assert(!state.Input_Json__c.contains(SECRET));

      WorkflowEngine.mockNow = WorkflowEngine.mockNow.addSeconds(11);
      WorkflowEngine.processWatchdogHeartbeat();
      Test.stopTest();

      Workflow_Instance__c inst = [
        SELECT Input__c
        FROM Workflow_Instance__c
        WHERE Correlation_Key__c = 'codec-debounce'
      ];
      System.assertEquals(
        input,
        WorkflowPayloadOffload.resolvePayload(inst.Input__c),
        'One decode gives the input: no double encode'
      );
    }
  }

  // ─── AC: codec selected by the config pointer ───────────────────────────

  @IsTest
  static void configPointerSelectsCodec() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.payloadCodecClass = 'WorkflowPayloadCodecE2ETest.AesCodec';

      String stored = WorkflowPayloadCodecs.encode(
        SECRET,
        CodecContext.PayloadKind.WORKFLOW_INPUT
      );

      System.assert(!WorkflowPayloadCodecs.isIdentity());
      System.assert(stored.startsWith(ENVELOPE_PREFIX));
      System.assertEquals(SECRET, WorkflowPayloadCodecs.decode(stored));
    }
  }

  @IsTest
  static void blankConfigPointerIsIdentity() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.payloadCodecClass = null;
      System.assert(WorkflowPayloadCodecs.isIdentity());
      System.assertEquals(
        SECRET,
        WorkflowPayloadCodecs.encode(
          SECRET,
          CodecContext.PayloadKind.WORKFLOW_INPUT
        )
      );
    }
  }
}
