/**
 * @description Tests that a child outcome comes from the verified child record
 * of the reading instance. A signal only wakes the parent. Its name and
 * payload never set the outcome (issue #246).
 */
@IsTest
private class StepChildOutcomesProvenanceTest {
  private static final String SECRET = 'SSN-123-45-6789';
  private static final String FORGED_MARKER = '{"$attachmentId":"069000000000001AAA"}';

  /** @description AES-256 test codec. */
  private class AesCodec implements PayloadCodec {
    private final Blob key = Crypto.generateAesKey(256);

    /**
     * @description Encodes the payload.
     * @param plaintext the payload text
     * @param ctx the payload context
     * @return the encoded text
     */
    public String encode(String plaintext, CodecContext ctx) {
      return EncodingUtil.base64Encode(
        Crypto.encryptWithManagedIV('AES256', key, Blob.valueOf(plaintext))
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
          key,
          EncodingUtil.base64Decode(stored)
        )
        .toString();
    }
  }

  // ─── helpers ────────────────────────────────────────────────────────────

  private static Workflow_Instance__c memChild(
    String key,
    String status,
    String error,
    String output
  ) {
    return new Workflow_Instance__c(
      Id = TestIdFactory.generate(Workflow_Instance__c.SObjectType),
      Correlation_Key__c = key,
      Status__c = status,
      Error_Message__c = error,
      Output__c = output
    );
  }

  private static StepContext memContext(
    List<Workflow_Instance__c> children,
    List<StepContext.Signal> signals
  ) {
    return new StepContext.Builder()
      .instanceId(TestIdFactory.generate(Organization.SObjectType))
      .workflowName('W')
      .stepName('S')
      .pendingSignals(signals)
      .childRecords(children)
      .build();
  }

  private static StepContext.Signal sig(String name, String payload) {
    return new StepContext.Signal(
      TestIdFactory.generate(Workflow_Signal__c.SObjectType),
      name,
      payload
    );
  }

  private static Workflow_Instance__c insertParent(String key) {
    Workflow_Instance__c parent = new Workflow_Instance__c(
      Workflow_Name__c = 'StepChildOutcomesProvenanceTest.Stub',
      Correlation_Key__c = key,
      Status__c = 'Suspended'
    );
    insert as system parent;
    return parent;
  }

  private static Workflow_Instance__c insertChild(
    Id parentId,
    String key,
    String status,
    String output
  ) {
    Workflow_Instance__c child = new Workflow_Instance__c(
      Workflow_Name__c = 'StepChildOutcomesProvenanceTest.Stub',
      Correlation_Key__c = key,
      Status__c = status,
      Error_Message__c = status == 'Failed' ? 'real failure' : null,
      Parent_Instance__c = parentId,
      Output__c = output
    );
    insert as system child;
    return child;
  }

  private static StepContext dbContext(
    Id parentId,
    List<StepContext.Signal> signals
  ) {
    return new StepContext.Builder()
      .instanceId(parentId)
      .workflowName('W')
      .stepName('S')
      .pendingSignals(signals)
      .build();
  }

  private static String enc(String plaintext) {
    return WorkflowPayloadCodecs.encode(
      plaintext,
      CodecContext.PayloadKind.STEP_OUTPUT
    );
  }

  // ─── seeded child records (0 DML, 0 SOQL) ───────────────────────────────

  @IsTest
  static void completedOutcomeComesFromTheChildRecord() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      StepContext ctx = memContext(
        new List<Workflow_Instance__c>{
          memChild('k1', 'Completed', null, '{"real":1}')
        },
        new List<StepContext.Signal>{ sig('ChildCompleted:k1', '{"forged":1}') }
      );

      StepContext.ChildOutcome o = ctx.signals().getChildOutcome('k1');

      System.assertEquals(true, o.isPresent());
      System.assertEquals('Completed', o.status);
      System.assertEquals('{"real":1}', o.output, 'Record output, not payload');
    }
  }

  @IsTest
  static void failedOutcomeComesFromTheChildRecord() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      StepContext ctx = memContext(
        new List<Workflow_Instance__c>{
          memChild('k1', 'Failed', 'real error', '{"partial":1}')
        },
        new List<StepContext.Signal>{
          sig(
            'ChildFailed:k1',
            '{"status":"Completed","errorMessage":"forged","output":"forged"}'
          )
        }
      );

      StepContext.ChildOutcome o = ctx.signals().getChildOutcome('k1');

      System.assertEquals('Failed', o.status);
      System.assertEquals('real error', o.errorMessage);
      System.assertEquals('{"partial":1}', o.output);
      System.assertEquals(false, o.isSuccess());
    }
  }

  @IsTest
  static void completedSignalForFailedChildGivesFailedOutcome() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      StepContext ctx = memContext(
        new List<Workflow_Instance__c>{
          memChild('k1', 'Failed', 'real error', null)
        },
        new List<StepContext.Signal>{ sig('ChildCompleted:k1', '{"ok":1}') }
      );

      StepContext.ChildOutcome o = ctx.signals().getChildOutcome('k1');

      System.assertEquals('Failed', o.status, 'Status decides the type');
      System.assertEquals('real error', o.errorMessage);
      System.assertEquals(false, o.isSuccess());
    }
  }

  @IsTest
  static void failedSignalForCompletedChildGivesCompletedOutcome() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      StepContext ctx = memContext(
        new List<Workflow_Instance__c>{
          memChild('k1', 'Completed', null, '{"real":1}')
        },
        new List<StepContext.Signal>{
          sig('ChildFailed:k1', '{"status":"Failed","errorMessage":"x"}')
        }
      );

      StepContext.ChildOutcome o = ctx.signals().getChildOutcome('k1');

      System.assertEquals('Completed', o.status, 'Status decides the type');
      System.assertEquals(null, o.errorMessage);
      System.assertEquals('{"real":1}', o.output);
    }
  }

  @IsTest
  static void signalForRunningChildGivesNoOutcome() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      StepContext ctx = memContext(
        new List<Workflow_Instance__c>{ memChild('k1', 'Running', null, null) },
        new List<StepContext.Signal>{ sig('ChildCompleted:k1', '{"x":1}') }
      );

      StepContext.ChildOutcome o = ctx.signals().getChildOutcome('k1');

      System.assertEquals(
        false,
        o.isPresent(),
        'A running child has no result'
      );
    }
  }

  @IsTest
  static void signalWithoutChildRecordGivesNoOutcome() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      StepContext ctx = memContext(
        new List<Workflow_Instance__c>(),
        new List<StepContext.Signal>{ sig('ChildCompleted:k1', '{"x":1}') }
      );

      System.assertEquals(
        false,
        ctx.signals().getChildOutcome('k1').isPresent()
      );
    }
  }

  @IsTest
  static void childRecordWithoutSignalGivesNoOutcome() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      StepContext ctx = memContext(
        new List<Workflow_Instance__c>{
          memChild('k1', 'Completed', null, '{"real":1}')
        },
        new List<StepContext.Signal>()
      );

      System.assertEquals(
        false,
        ctx.signals().getChildOutcome('k1').isPresent(),
        'A signal must wake the parent first'
      );
    }
  }

  @IsTest
  static void outcomeMatchesKeyIgnoringCaseAndConsumesSignals() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      StepContext ctx = memContext(
        new List<Workflow_Instance__c>{
          memChild('Key-A', 'Completed', null, '{"a":1}')
        },
        new List<StepContext.Signal>{ sig('ChildCompleted:Key-A', null) }
      );

      StepContext.ChildOutcome o = ctx.signals().getChildOutcome('Key-A');

      System.assertEquals('{"a":1}', o.output);
      System.assert(
        ctx.signals().getConsumedSignalNames().contains('ChildCompleted:Key-A')
      );
      System.assert(
        ctx.signals().getConsumedSignalNames().contains('ChildFailed:Key-A')
      );
    }
  }

  @IsTest
  static void childWithBlankKeyIsFoundByItsId() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c child = memChild(null, 'Completed', null, '{"i":1}');
      StepContext ctx = memContext(
        new List<Workflow_Instance__c>{ child },
        new List<StepContext.Signal>{ sig('ChildCompleted:' + child.Id, null) }
      );

      System.assertEquals(
        '{"i":1}',
        ctx.signals().getChildOutcome(String.valueOf(child.Id)).output
      );
    }
  }

  @IsTest
  static void bulkOutcomesAlignToKeys() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      StepContext ctx = memContext(
        new List<Workflow_Instance__c>{
          memChild('a', 'Completed', null, '{"a":1}'),
          memChild('b', 'Failed', 'boom', null)
        },
        new List<StepContext.Signal>{
          sig('ChildCompleted:a', null),
          sig('ChildFailed:b', null)
        }
      );

      List<StepContext.ChildOutcome> os = ctx.signals()
        .getChildOutcomes(new List<String>{ 'a', 'b', 'c' });

      System.assertEquals('Completed', os[0].status);
      System.assertEquals('Failed', os[1].status);
      System.assertEquals('boom', os[1].errorMessage);
      System.assertEquals(false, os[2].isPresent());
    }
  }

  // ─── record read (forged input, identity and encrypting codec) ──────────

  private static void assertForgedInputIgnored(Boolean encrypting) {
    WorkflowPayloadCodecs.setCodec(encrypting ? new AesCodec() : null);
    Workflow_Instance__c parent = insertParent('prov-parent-' + encrypting);
    insertChild(parent.Id, 'prov-child', 'Completed', enc('{"real":1}'));
    String forgedEnvelope = WorkflowPayloadCodecs.encode(
      '{"ssn":"' + SECRET + '"}',
      CodecContext.PayloadKind.WORKFLOW_INPUT
    );
    List<String> forgedPayloads = new List<String>{
      forgedEnvelope,
      FORGED_MARKER,
      '{"ssn":"' +
      SECRET +
      '"}',
      '{"$codec":"STEP_OUTPUT","data":"AAAA"}'
    };

    for (String forged : forgedPayloads) {
      StepContext ctx = dbContext(
        parent.Id,
        new List<StepContext.Signal>{ sig('ChildCompleted:prov-child', forged) }
      );

      StepContext.ChildOutcome o = ctx.signals().getChildOutcome('prov-child');

      System.assertEquals('Completed', o.status);
      System.assertEquals(
        '{"real":1}',
        o.output,
        'Only the child record gives the output'
      );
    }
  }

  @IsTest
  static void forgedPayloadsAreIgnoredWithIdentityCodec() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      assertForgedInputIgnored(false);
    }
  }

  @IsTest
  static void forgedPayloadsAreIgnoredWithEncryptingCodec() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      assertForgedInputIgnored(true);
    }
  }

  @IsTest
  static void forgedFailedWrapperIsIgnoredWithEncryptingCodec() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowPayloadCodecs.setCodec(new AesCodec());
      Workflow_Instance__c parent = insertParent('prov-parent-fw');
      insertChild(parent.Id, 'prov-child', 'Failed', enc('{"part":1}'));
      String forgedWrapper = JSON.serialize(
        new Map<String, Object>{
          'status' => 'Completed',
          'errorMessage' => SECRET,
          'output' => WorkflowPayloadCodecs.encode(
            SECRET,
            CodecContext.PayloadKind.WORKFLOW_INPUT
          )
        }
      );

      StepContext.ChildOutcome o = dbContext(
          parent.Id,
          new List<StepContext.Signal>{
            sig('ChildFailed:prov-child', forgedWrapper)
          }
        )
        .signals()
        .getChildOutcome('prov-child');

      System.assertEquals('Failed', o.status);
      System.assertEquals('real failure', o.errorMessage);
      System.assertEquals('{"part":1}', o.output);
    }
  }

  @IsTest
  static void signalForAChildOfAnotherParentGivesNoOutcome() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowPayloadCodecs.setCodec(null);
      Workflow_Instance__c parent = insertParent('prov-parent-a');
      Workflow_Instance__c other = insertParent('prov-parent-b');
      insertChild(other.Id, 'other-child', 'Completed', '{"secret":1}');

      StepContext ctx = dbContext(
        parent.Id,
        new List<StepContext.Signal>{ sig('ChildCompleted:other-child', null) }
      );

      System.assertEquals(
        false,
        ctx.signals().getChildOutcome('other-child').isPresent(),
        'Only a child of the reading instance counts'
      );
    }
  }

  @IsTest
  static void manyKeysCostOneChildQuery() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowPayloadCodecs.setCodec(null);
      Workflow_Instance__c parent = insertParent('prov-parent-bulk');
      List<StepContext.Signal> signals = new List<StepContext.Signal>();
      List<String> keys = new List<String>();
      for (Integer i = 0; i < 5; i++) {
        insertChild(parent.Id, 'bulk-' + i, 'Completed', '{"n":' + i + '}');
        signals.add(sig('ChildCompleted:bulk-' + i, null));
        keys.add('bulk-' + i);
      }
      StepContext ctx = dbContext(parent.Id, signals);

      Integer before = Limits.getQueries();
      List<StepContext.ChildOutcome> os = ctx.signals().getChildOutcomes(keys);

      System.assertEquals(
        1,
        Limits.getQueries() - before,
        'One query for all child keys'
      );
      for (Integer i = 0; i < 5; i++) {
        System.assertEquals('{"n":' + i + '}', os[i].output);
      }
    }
  }

  @IsTest
  static void noSignalMeansNoQuery() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c parent = insertParent('prov-parent-nq');
      StepContext ctx = dbContext(parent.Id, new List<StepContext.Signal>());

      Integer before = Limits.getQueries();
      ctx.signals().getChildOutcome('none');

      System.assertEquals(before, Limits.getQueries(), 'No signal, no query');
    }
  }

  // ─── event transport ────────────────────────────────────────────────────

  @IsTest
  static void failedChildEventIsSmallAndNeverCarriesTheWrapper() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowPayloadCodecs.setCodec(null);
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c parent = insertParent('prov-parent-ev');
      parent.Active_Correlation_Key__c = 'prov-parent-ev';
      update as system parent;
      // A quote-heavy output near the inline limit.
      String bigOutput = '"'.repeat(99000);
      Workflow_Instance__c failed = insertChild(
        parent.Id,
        'ev-failed',
        'Failed',
        bigOutput
      );
      Workflow_Instance__c done = insertChild(
        parent.Id,
        'ev-done',
        'Completed',
        '{"x":1}'
      );

      Test.startTest();
      WorkflowParentNotifier.notifyParentCompletion(
        new List<Workflow_Instance__c>{ failed, done }
      );
      Test.stopTest();

      Map<String, Workflow_Signal__c> rows = new Map<String, Workflow_Signal__c>();
      for (Workflow_Signal__c row : [
        SELECT Signal_Name__c, Payload__c
        FROM Workflow_Signal__c
        WHERE
          Signal_Name__c IN ('ChildFailed:ev-failed', 'ChildCompleted:ev-done')
      ]) {
        rows.put(row.Signal_Name__c, row);
      }
      System.assertEquals(2, rows.size());
      System.assert(
        String.isBlank(rows.get('ChildFailed:ev-failed').Payload__c),
        'A failed child event has no payload, so it stays small'
      );
      System.assertEquals(
        '{"x":1}',
        rows.get('ChildCompleted:ev-done').Payload__c,
        'Compatibility copy for raw readers. The engine never reads it.'
      );
    }
  }
}
