/**
 * @description End-to-end tests for the payload codec (issue #99). A workflow moves a
 * sensitive value through workflow input, step output (inline and offloaded),
 * step state, captures, progress, inbound signals and child-completion
 * signals. The tests scan the payload fields of the three engine objects,
 * the error fields and the offload files for plaintext.
 */
@IsTest
public class WorkflowPayloadCodecE2ETest {
  public static final String SECRET = 'SSN-987-65-4321';
  public static final String SIGNAL = 'Approve';
  private static final String ENVELOPE_PREFIX = '{"$codec":';
  private static Blob aesKey;

  /** @description AES-256 codec. Tests load it by name, so it is public. */
  public class AesCodec implements PayloadCodec {
    private Blob key() {
      if (aesKey == null) {
        aesKey = Crypto.generateAesKey(256);
      }
      return aesKey;
    }

    /**
     * @description Encodes the payload.
     * @param plaintext the payload text
     * @param ctx the payload context
     * @return the encoded text
     */
    public String encode(String plaintext, CodecContext ctx) {
      return EncodingUtil.base64Encode(
        Crypto.encryptWithManagedIV('AES256', key(), Blob.valueOf(plaintext))
      );
    }

    /**
     * @description Decodes the payload.
     * @param stored the encoded text
     * @param ctx the payload context
     * @return the payload text
     */
    public String decode(String stored, CodecContext ctx) {
      return Crypto.decryptWithManagedIV(
          'AES256',
          key(),
          EncodingUtil.base64Decode(stored)
        )
        .toString();
    }
  }

  /** @description Parent workflow: receive, then start a child, then finish. */
  public class SecretWorkflow implements WorkflowDefinition {
    /**
     * @description Returns the step names.
     * @return the step names
     */
    public List<String> getSteps() {
      return new List<String>{
        'WorkflowPayloadCodecE2ETest.ReceiveStep',
        'WorkflowPayloadCodecE2ETest.ChildWaitStep',
        'WorkflowPayloadCodecE2ETest.FinishStep'
      };
    }

    /**
     * @description Returns the first step.
     * @return the first step name
     */
    public String getInitialStep() {
      return 'WorkflowPayloadCodecE2ETest.ReceiveStep';
    }

    /**
     * @description Returns the next step.
     * @param currentStepName the step that ran
     * @param result the step result
     * @return the next step name, or null at the end
     */
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

  /** @description Produces a capture value that holds the secret. */
  public class SecretProducer implements CaptureProducer {
    /**
     * @description Produces the capture value.
     * @return the capture value
     */
    public Object produce() {
      return 'captured:' + SECRET;
    }
  }

  /**
   * @description Writes the secret to captures, progress and step state. Waits for the
   * signal. Then completes with a large output, so the engine offloads it.
   */
  public class ReceiveStep implements WorkflowStep {
    /**
     * @description Runs the step.
     * @param ctx the step context
     * @return the step result
     */
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

  /** @description Starts the child. Then reads the child outcome. */
  public class ChildWaitStep implements WorkflowStep {
    /**
     * @description Runs the step.
     * @param ctx the step context
     * @return the step result
     */
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

  /** @description Completes with the previous output, so the workflow output holds it. */
  public class FinishStep implements WorkflowStep {
    /**
     * @description Runs the step.
     * @param ctx the step context
     * @return the step result
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(
        null,
        JSON.deserializeUntyped(ctx.previousStepOutput)
      );
    }
  }

  /** @description One-step child workflow. It returns the secret. */
  public class ChildWorkflow implements WorkflowDefinition {
    /**
     * @description Returns the step names.
     * @return the step names
     */
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowPayloadCodecE2ETest.ChildStep' };
    }

    /**
     * @description Returns the first step.
     * @return the first step name
     */
    public String getInitialStep() {
      return 'WorkflowPayloadCodecE2ETest.ChildStep';
    }

    /**
     * @description Returns the next step.
     * @param currentStepName the step that ran
     * @param result the step result
     * @return the next step name, or null at the end
     */
    public String getNextStep(String currentStepName, StepResult result) {
      return null;
    }
  }

  /** @description Returns the child input. */
  public class ChildStep implements WorkflowStep {
    /**
     * @description Runs the step.
     * @param ctx the step context
     * @return the step result
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(
        null,
        new Map<String, Object>{ 'childInput' => ctx.workflowInputJson }
      );
    }
  }

  /** @description Saga: a compensatable step, then a step that fails with data. */
  public class SagaWorkflow implements WorkflowDefinition {
    /**
     * @description Returns the step names.
     * @return the step names
     */
    public List<String> getSteps() {
      return new List<String>{
        'WorkflowPayloadCodecE2ETest.ReserveStep',
        'WorkflowPayloadCodecE2ETest.FailWithDataStep'
      };
    }

    /**
     * @description Returns the first step.
     * @return the first step name
     */
    public String getInitialStep() {
      return 'WorkflowPayloadCodecE2ETest.ReserveStep';
    }

    /**
     * @description Returns the next step.
     * @param currentStepName the step that ran
     * @param result the step result
     * @return the next step name, or null at the end
     */
    public String getNextStep(String currentStepName, StepResult result) {
      return currentStepName == 'WorkflowPayloadCodecE2ETest.ReserveStep'
        ? 'WorkflowPayloadCodecE2ETest.FailWithDataStep'
        : null;
    }
  }

  /** @description Completes with the secret. Compensates with the secret. */
  public class ReserveStep implements CompensatableStep {
    /**
     * @description Runs the step.
     * @param ctx the step context
     * @return the step result
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(
        null,
        new Map<String, Object>{ 'reserved' => SECRET }
      );
    }

    /**
     * @description Undoes the step.
     * @param ctx the step context
     * @return the step result
     */
    public StepResult compensate(StepContext ctx) {
      return StepResult.complete(
        null,
        new Map<String, Object>{ 'released' => SECRET }
      );
    }
  }

  /** @description Fails with failure data that holds the secret. */
  public class FailWithDataStep implements WorkflowStep {
    /**
     * @description Runs the step.
     * @param ctx the step context
     * @return the step result
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.fail(
        'Declined',
        new Map<String, Object>{ 'ssn' => SECRET }
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
      SELECT Input__c, Output__c, Progress__c, Error_Message__c
      FROM Workflow_Instance__c
    ]) {
      values.add(inst.Input__c);
      values.add(inst.Output__c);
      values.add(inst.Progress__c);
      values.add(inst.Error_Message__c);
    }
    for (Workflow_Step_Execution__c se : [
      SELECT Input__c, Output__c, Captured_Values__c, Error_Details__c
      FROM Workflow_Step_Execution__c
    ]) {
      values.add(se.Input__c);
      values.add(se.Output__c);
      values.add(se.Captured_Values__c);
      values.add(se.Error_Details__c);
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
      WorkflowPayloadCodecs.setCodec(null);
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
      WorkflowPayloadCodecs.setCodec(null);
      WorkflowTestHarness.Result plain = runSecretWorkflow('codec-rt-plain');
      // A second governor context for the AES run.
      Test.startTest();
      WorkflowPayloadCodecs.setCodec(new AesCodec());
      WorkflowTestHarness.Result aes = runSecretWorkflow('codec-rt-aes');
      Test.stopTest();

      System.assertEquals(plain.status, aes.status);
      System.assertEquals(plain.completedSteps, aes.completedSteps);
      System.assertEquals(plain.compensatedSteps, aes.compensatedSteps);
      System.assertEquals(plain.output, aes.output, 'Same resolved output');
    }
  }

  // ─── AC: append-only; decode is read-only ───────────────────────────────

  @IsTest
  static void checkpointPayloadsAreWrittenOnce() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowPayloadCodecs.setCodec(new AesCodec());
      Id instanceId = WorkflowEngine.start(
        'WorkflowPayloadCodecE2ETest.SecretWorkflow',
        'codec-append',
        new Map<String, Object>{ 'ssn' => SECRET }
      );
      WorkflowTestHarness harness = new WorkflowTestHarness(instanceId);
      harness.drive();
      WorkflowEngine.signal('codec-append', SIGNAL, '{"a":1}');
      harness.driveUntilStep('WorkflowPayloadCodecE2ETest.ChildWaitStep');
      Workflow_Step_Execution__c checkpoint = [
        SELECT Id, Output__c, Captured_Values__c
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Step_Name__c = 'WorkflowPayloadCodecE2ETest.ReceiveStep'
          AND Status__c = 'Completed'
      ];

      WorkflowTestHarness.Result r = harness.drive();
      Integer dmlBefore = Limits.getDmlStatements();
      WorkflowStatusRead.getStatus(new List<Id>{ instanceId });
      harness.inspect();
      WorkflowPayloadOffload.resolvePayloads(
        new List<String>{ checkpoint.Output__c, checkpoint.Captured_Values__c }
      );

      System.assertEquals('Completed', r.status);
      System.assertEquals(
        dmlBefore,
        Limits.getDmlStatements(),
        'Reads do no DML'
      );
      // AES uses a random IV. A second encode gives new ciphertext, so equal
      // values prove that the engine wrote the checkpoint once.
      Workflow_Step_Execution__c after = [
        SELECT Output__c, Captured_Values__c
        FROM Workflow_Step_Execution__c
        WHERE Id = :checkpoint.Id
      ];
      System.assertEquals(checkpoint.Output__c, after.Output__c);
      System.assertEquals(
        checkpoint.Captured_Values__c,
        after.Captured_Values__c
      );
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
        SELECT Id, Step_Name__c, Status__c, Input__c, Output__c
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
      System.assertEquals(
        WorkflowPayloadService.REDACTED_PAYLOAD,
        inst.Progress__c
      );
      for (Workflow_Step_Execution__c se : steps) {
        if (
          se.Step_Name__c == 'WorkflowPayloadCodecE2ETest.ReceiveStep' &&
          se.Status__c == 'Completed'
        ) {
          System.assertEquals(
            WorkflowPayloadService.REDACTED_PAYLOAD,
            se.Output__c,
            'The offloaded output is redacted, not shown as a marker'
          );
        }
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

  // ─── review fixes ───────────────────────────────────────────────────────

  @IsTest
  static void replayedEnvelopeIsNotDecodedForAnotherInstance() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowPayloadCodecs.setCodec(new AesCodec());
      Id victimId = WorkflowEngine.start(
        'WorkflowPayloadCodecE2ETest.SecretWorkflow',
        'codec-victim',
        new Map<String, Object>{ 'ssn' => SECRET }
      );
      String stolen = [
        SELECT Input__c
        FROM Workflow_Instance__c
        WHERE Id = :victimId
      ]
      .Input__c;

      Id attackerId = WorkflowEngine.start(
        'WorkflowPayloadCodecE2ETest.SecretWorkflow',
        'codec-attacker',
        new Map<String, Object>{ 'ssn' => 'none' }
      );
      WorkflowTestHarness harness = new WorkflowTestHarness(attackerId);
      harness.drive();
      Test.startTest();
      WorkflowTestHarness.Result r = harness.injectSignal(
        'codec-attacker',
        SIGNAL,
        stolen
      );
      Test.stopTest();

      Map<String, Object> out = (Map<String, Object>) JSON.deserializeUntyped(
        r.output
      );
      System.assertEquals(
        stolen,
        out.get('signal'),
        'The step gets the envelope text it was sent'
      );
      System.assert(
        !String.valueOf(out.get('signal')).contains(SECRET),
        'No decrypt by replay'
      );
    }
  }

  @IsTest
  static void sagaControlValuesStayPlaintext() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowPayloadCodecs.setCodec(new AesCodec());
      Id instanceId = WorkflowEngine.start(
        'WorkflowPayloadCodecE2ETest.SagaWorkflow',
        'codec-saga',
        new Map<String, Object>{ 'ssn' => SECRET }
      );

      WorkflowTestHarness.Result r = new WorkflowTestHarness(instanceId)
        .drive();

      System.assertEquals('Compensated', r.status);
      System.assertEquals(
        new List<String>{ 'WorkflowPayloadCodecE2ETest.ReserveStep' },
        r.compensatedSteps
      );
      Workflow_Instance__c inst = [
        SELECT Terminal_At__c, Compensation_Stack__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      System.assertNotEquals(null, inst.Terminal_At__c);
      System.assert(
        !WorkflowPayloadCodecs.isEncoded(inst.Compensation_Stack__c),
        'The compensation stack is control data'
      );
      Workflow_Step_Execution__c failed = [
        SELECT Error_Details__c
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Step_Name__c = 'WorkflowPayloadCodecE2ETest.FailWithDataStep'
        LIMIT 1
      ];
      System.assert(
        failed.Error_Details__c.startsWith('Declined\nfailureData: {"$codec":'),
        'failureData is encoded: ' + failed.Error_Details__c
      );
      System.assertEquals(
        0,
        countContaining(storedPayloads(), SECRET),
        'No plaintext secret after a saga rollback'
      );
    }
  }

  @IsTest
  static void undecodableDebounceRowDoesNotBlockOthers() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowPayloadCodecs.setCodec(new AesCodec());
      WorkflowEngine.disableQueueableInTest = true;
      WorkflowEngine.mockNow = Datetime.now();
      Test.startTest();
      WorkflowStartService.startDebounced(
        new WorkflowDebouncer.DebounceRequest(
            'WorkflowPayloadCodecE2ETest.SecretWorkflow',
            'codec-debounce-good',
            '{"ssn":"' + SECRET + '"}'
          )
          .withDebounce(10)
      );
      Debounce_State__c bad = new Debounce_State__c(
        Workflow_Name__c = 'WorkflowPayloadCodecE2ETest.SecretWorkflow',
        Correlation_Key__c = 'codec-debounce-bad',
        Debounce_Key__c = 'codec-debounce-bad',
        Input_Json__c = '{"$codec":"WORKFLOW_INPUT","data":"not-cipher"}',
        First_Triggered_At__c = WorkflowEngine.mockNow,
        Fire_At__c = WorkflowEngine.mockNow.addSeconds(-60)
      );
      insert as system bad;

      WorkflowEngine.mockNow = WorkflowEngine.mockNow.addSeconds(11);
      WorkflowEngine.processWatchdogHeartbeat();
      Test.stopTest();

      System.assertEquals(
        1,
        [
          SELECT COUNT()
          FROM Workflow_Instance__c
          WHERE Correlation_Key__c = 'codec-debounce-good'
        ],
        'The good row starts'
      );
      Debounce_State__c after = [
        SELECT Retry_Count__c
        FROM Debounce_State__c
        WHERE Id = :bad.Id
      ];
      System.assertEquals(1, after.Retry_Count__c, 'The bad row is retried');
    }
  }

  @IsTest
  static void duplicateKeyedSignalLeavesNoOffloadFile() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowPayloadCodecs.setCodec(new AesCodec());
      Id instanceId = WorkflowEngine.start(
        'WorkflowPayloadCodecE2ETest.SecretWorkflow',
        'codec-dup-offload',
        new Map<String, Object>{ 'ssn' => SECRET }
      );
      new WorkflowTestHarness(instanceId).drive();
      String big = '{"blob":"' + 'z'.repeat(100001) + '"}';

      // Two separate bulk calls: the second one loses the unique-key race.
      for (Integer i = 0; i < 2; i++) {
        WorkflowEngine.SignalRequest req = new WorkflowEngine.SignalRequest(
          'codec-dup-offload',
          'Other',
          big
        );
        req.idempotencyKey = 'same-big-key';
        WorkflowEngine.signal(new List<WorkflowEngine.SignalRequest>{ req });
      }

      System.assertEquals(
        1,
        [
          SELECT COUNT()
          FROM Workflow_Signal__c
          WHERE Workflow_Instance__c = :instanceId AND Signal_Name__c = 'Other'
        ]
      );
      System.assertEquals(
        1,
        [
          SELECT COUNT()
          FROM ContentDocument
          WHERE Title LIKE 'Output_Signal_Other%'
        ],
        'The duplicate delivery leaves no offload file'
      );
    }
  }

  /** @description Test codec that keeps the length: it reverses the text. */
  public class ReverseCodec implements PayloadCodec {
    /**
     * @description Encodes the payload.
     * @param plaintext the payload text
     * @param ctx the payload context
     * @return the reversed text
     */
    public String encode(String plaintext, CodecContext ctx) {
      return plaintext.reverse();
    }

    /**
     * @description Decodes the payload.
     * @param stored the reversed text
     * @param ctx the payload context
     * @return the payload text
     */
    public String decode(String stored, CodecContext ctx) {
      return stored.reverse();
    }
  }

  @IsTest
  static void largeFailedChildWrapperResolvesInOnePass() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowPayloadCodecs.setCodec(new ReverseCodec());
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c parent = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowPayloadCodecE2ETest.SecretWorkflow',
        Correlation_Key__c = 'codec-parent-failed',
        Active_Correlation_Key__c = 'codec-parent-failed',
        Status__c = 'Suspended'
      );
      insert as system parent;
      // The child output stays inline, but the wrapper around it is longer
      // than the offload limit.
      Workflow_Instance__c child = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowPayloadCodecE2ETest.ChildWorkflow',
        Correlation_Key__c = 'codec-child-failed',
        Status__c = 'Failed',
        Error_Message__c = 'Child failed',
        Parent_Instance__c = parent.Id,
        Output__c = WorkflowPayloadCodecs.encode(
          'a'.repeat(99950),
          CodecContext.PayloadKind.STEP_OUTPUT
        )
      );
      insert as system child;

      Test.startTest();
      WorkflowParentNotifier.notifyParentCompletion(child);
      Test.stopTest();

      Workflow_Signal__c sig = [
        SELECT Payload__c
        FROM Workflow_Signal__c
        WHERE Signal_Name__c = 'ChildFailed:codec-child-failed'
      ];
      System.assert(
        sig.Payload__c.startsWith(WorkflowPayloadCodecs.OFFLOAD_PREFIX),
        'The engine offloads the encoded wrapper'
      );
      Map<String, Object> wrapper = (Map<String, Object>) JSON.deserializeUntyped(
        WorkflowPayloadOffload.resolvePayload(sig.Payload__c)
      );
      System.assertEquals('Failed', wrapper.get('status'));
      System.assertEquals(
        child.Output__c,
        wrapper.get('output'),
        'The wrapper carries the child stored output'
      );
    }
  }

  @IsTest
  static void failureDetailsFitTheField() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowPayloadCodecs.setCodec(new AesCodec());
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowPayloadCodecE2ETest.SagaWorkflow',
        Correlation_Key__c = 'codec-failure-data',
        Status__c = 'Running'
      );
      insert as system inst;
      Workflow_Step_Execution__c stepExec = new Workflow_Step_Execution__c(
        Workflow_Instance__c = inst.Id,
        Step_Name__c = 'WorkflowPayloadCodecE2ETest.FailWithDataStep'
      );
      // 99 000 plaintext characters grow past the offload limit after AES.
      String bigData = '{"ssn":"' + SECRET + 'x'.repeat(99000) + '"}';
      // 60 000 characters stay inline after AES, but not with a long reason.
      String midData = '{"ssn":"' + SECRET + 'y'.repeat(60000) + '"}';
      String longReason = 'r'.repeat(60000);

      String offloaded = WorkflowPayloadCodecs.failureDetails(
        stepExec,
        'Declined',
        bigData
      );
      String inline = WorkflowPayloadCodecs.failureDetails(
        stepExec,
        longReason,
        midData
      );

      String marker = offloaded.substringAfter('\nfailureData: ');
      System.assert(
        marker.startsWith(WorkflowPayloadCodecs.OFFLOAD_PREFIX),
        'Large encoded failure data goes to a file'
      );
      System.assertEquals(
        bigData,
        WorkflowPayloadOffload.resolvePayload(marker)
      );
      System.assert(inline.length() <= 131072, 'The value fits the field');
      System.assertEquals(
        midData,
        WorkflowPayloadCodecs.decode(inline.substringAfter('\nfailureData: ')),
        'The failure data does not change'
      );
      WorkflowPayloadCodecs.setCodec(null);
      System.assertEquals(
        'Declined\nfailureData: ' + bigData,
        WorkflowPayloadCodecs.failureDetails(stepExec, 'Declined', bigData),
        'Identity keeps the legacy value'
      );
      System.assertEquals(
        'Declined',
        WorkflowPayloadCodecs.failureDetails(stepExec, 'Declined', null)
      );
    }
  }
}
