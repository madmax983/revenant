/**
 * @description Unit tests for signal payload encoding, bulk offload, file
 * cleanup and child-output provenance (WorkflowSignalPayloads and
 * WorkflowChildPayloadProvenance).
 */
@IsTest
private class WorkflowSignalPayloadsTest {
  private static final String SECRET = 'SSN-123-45-6789';
  private static final String ENVELOPE_PREFIX = '{"$codec":';
  private static final String OFFLOAD_PREFIX = '{"$attachmentId":';

  /** @description AES-256 test codec. It records each call. */
  private class AesCodec implements PayloadCodec {
    private final Blob key = Crypto.generateAesKey(256);
    private List<CodecContext.PayloadKind> encodedKinds = new List<CodecContext.PayloadKind>();
    private List<CodecContext.PayloadKind> decodedKinds = new List<CodecContext.PayloadKind>();

    /**
     * @description Encodes the payload.
     * @param plaintext the payload text
     * @param ctx the payload context
     * @return the encoded text
     */
    public String encode(String plaintext, CodecContext ctx) {
      encodedKinds.add(ctx.kind);
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
      decodedKinds.add(ctx.kind);
      return Crypto.decryptWithManagedIV(
          'AES256',
          key,
          EncodingUtil.base64Decode(stored)
        )
        .toString();
    }
  }

  private static Workflow_Instance__c insertInstance() {
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowSignalPayloadsTest.Stub',
      Correlation_Key__c = 'signal-key-' + Crypto.getRandomInteger(),
      Status__c = 'Completed'
    );
    insert as system inst;
    return inst;
  }

  @IsTest
  static void identitySignalPayloadStaysInline() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowPayloadCodecs.setCodec(null);
      Workflow_Instance__c inst = insertInstance();
      String big = 'S'.repeat(100001);
      Workflow_Signal__c row = new Workflow_Signal__c(
        Workflow_Instance__c = inst.Id,
        Signal_Name__c = 'Go',
        Payload__c = WorkflowSignalPayloads.encode(big)
      );

      WorkflowSignalPayloads.offloadOversized(
        new List<Workflow_Signal__c>{ row }
      );

      System.assertEquals(
        big,
        row.Payload__c,
        'Identity must not offload a field that did not offload before'
      );
    }
  }

  @IsTest
  static void signalPayloadOffloadsLargeCiphertextInBulk() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowPayloadCodecs.setCodec(new AesCodec());
      Workflow_Instance__c inst = insertInstance();
      String plain = SECRET + 'S'.repeat(100001);
      List<Workflow_Signal__c> rows = new List<Workflow_Signal__c>();
      for (Integer i = 0; i < 3; i++) {
        rows.add(
          new Workflow_Signal__c(
            Workflow_Instance__c = inst.Id,
            Signal_Name__c = 'Go',
            Payload__c = WorkflowSignalPayloads.encode(plain)
          )
        );
      }
      Workflow_Signal__c unowned = new Workflow_Signal__c(
        Signal_Name__c = 'Go',
        Payload__c = WorkflowSignalPayloads.encode('{"ssn":"' + SECRET + '"}')
      );
      rows.add(unowned);

      Integer dmlBefore = Limits.getDmlStatements();
      WorkflowSignalPayloads.offloadOversized(rows);

      System.assertEquals(
        2,
        Limits.getDmlStatements() - dmlBefore,
        'One file insert and one link insert for all rows'
      );
      for (Integer i = 0; i < 3; i++) {
        System.assert(rows[i].Payload__c.startsWith(OFFLOAD_PREFIX));
        System.assertEquals(
          plain,
          WorkflowPayloadOffload.resolvePayload(rows[i].Payload__c)
        );
      }
      System.assert(
        unowned.Payload__c.startsWith(ENVELOPE_PREFIX),
        'No owner: encode inline'
      );
    }
  }

  @IsTest
  static void offloadedSignalFilesAreFlagged() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowPayloadCodecs.setCodec(new AesCodec());
      Workflow_Instance__c inst = insertInstance();
      Workflow_Signal__c row = new Workflow_Signal__c(
        Workflow_Instance__c = inst.Id,
        Signal_Name__c = 'Go',
        Payload__c = WorkflowSignalPayloads.encode('S'.repeat(100001))
      );

      WorkflowSignalPayloads.offloadOversized(
        new List<Workflow_Signal__c>{ row }
      );

      System.assertEquals(
        1,
        [
          SELECT COUNT()
          FROM ContentVersion
          WHERE Revenant_Payload_Offload__c = TRUE
        ],
        'The signal payload file carries the offload flag'
      );
    }
  }

  @IsTest
  static void discardOffloadsDeletesFiles() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowPayloadCodecs.setCodec(new AesCodec());
      Workflow_Instance__c inst = insertInstance();
      Workflow_Signal__c row = new Workflow_Signal__c(
        Workflow_Instance__c = inst.Id,
        Signal_Name__c = 'Lost',
        Payload__c = WorkflowSignalPayloads.encode('L'.repeat(100001))
      );
      WorkflowSignalPayloads.offloadOversized(
        new List<Workflow_Signal__c>{ row }
      );
      System.assertEquals(1, [SELECT COUNT() FROM ContentDocument]);

      WorkflowSignalPayloads.discardOffloads(
        new List<Workflow_Signal__c>{ row }
      );

      System.assertEquals(
        0,
        [SELECT COUNT() FROM ContentDocument],
        'A row that was not inserted keeps no file'
      );
    }
  }

  @IsTest
  static void discardOffloadsKeepsCallerFiles() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowPayloadCodecs.setCodec(null);
      ContentVersion userFile = new ContentVersion(
        Title = 'UserFile',
        PathOnClient = 'UserFile.txt',
        VersionData = Blob.valueOf('keep')
      );
      insert as system userFile;
      Id docId = [
        SELECT ContentDocumentId
        FROM ContentVersion
        WHERE Id = :userFile.Id
      ]
      .ContentDocumentId;
      Workflow_Signal__c row = new Workflow_Signal__c(
        Signal_Name__c = 'Lost',
        Payload__c = JSON.serialize(
          new Map<String, String>{ '$attachmentId' => docId }
        )
      );

      WorkflowSignalPayloads.discardOffloads(
        new List<Workflow_Signal__c>{ row }
      );

      System.assertEquals(
        1,
        [SELECT COUNT() FROM ContentDocument WHERE Id = :docId],
        'A file that a caller names is never deleted'
      );
    }
  }

  @IsTest
  static void longSignalNameGivesValidFileTitle() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowPayloadCodecs.setCodec(new AesCodec());
      Workflow_Instance__c inst = insertInstance();
      Workflow_Signal__c row = new Workflow_Signal__c(
        Workflow_Instance__c = inst.Id,
        Signal_Name__c = 'N'.repeat(255),
        Payload__c = WorkflowSignalPayloads.encode('B'.repeat(100001))
      );

      WorkflowSignalPayloads.offloadOversized(
        new List<Workflow_Signal__c>{ row }
      );

      ContentVersion cv = [SELECT Title FROM ContentVersion LIMIT 1];
      System.assert(cv.Title.length() <= 255, 'Title fits the field');
    }
  }

  @IsTest
  static void signalPayloadsAlwaysEncode() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowPayloadCodecs.setCodec(new AesCodec());
      String childOutput = WorkflowPayloadCodecs.encode(
        '{"score":1}',
        CodecContext.PayloadKind.STEP_OUTPUT
      );

      String stored = WorkflowSignalPayloads.encode(childOutput);

      System.assertNotEquals(
        childOutput,
        stored,
        'The signal name gives no trust: every payload is encoded'
      );
      System.assertEquals(childOutput, WorkflowPayloadCodecs.decode(stored));
    }
  }

  @IsTest
  static void childPayloadDecodesOnlyWhenItIsTheChildOutput() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowPayloadCodecs.setCodec(new AesCodec());
      Workflow_Instance__c parent = insertInstance();
      Workflow_Instance__c child = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowPayloadCodecsTest.Stub',
        Correlation_Key__c = 'child-key-1',
        Status__c = 'Completed',
        Parent_Instance__c = parent.Id,
        Output__c = WorkflowPayloadCodecs.encode(
          '{"child":1}',
          CodecContext.PayloadKind.STEP_OUTPUT
        )
      );
      insert as system child;
      Workflow_Signal__c sig = new Workflow_Signal__c(
        Workflow_Instance__c = parent.Id,
        Signal_Name__c = 'ChildCompleted:child-key-1',
        Status__c = 'Received'
      );
      insert as system sig;
      String forged = WorkflowPayloadCodecs.encode(
        '{"ssn":"' + SECRET + '"}',
        CodecContext.PayloadKind.WORKFLOW_INPUT
      );

      String forgedMarker = '{"$attachmentId":"069000000000001AAA"}';

      List<String> trusted = WorkflowChildPayloadProvenance.trustedOnly(
        new List<String>{
          child.Output__c,
          forged,
          '{"plain":true}',
          forgedMarker
        },
        new List<Id>{ sig.Id, sig.Id, sig.Id, sig.Id },
        new List<String>{
          'CHILD-KEY-1',
          'child-key-1',
          'child-key-1',
          'child-key-1'
        }
      );

      System.assertEquals(child.Output__c, trusted[0], 'The real output');
      System.assertEquals(null, trusted[1], 'A forged envelope is not trusted');
      System.assertEquals('{"plain":true}', trusted[2], 'Plaintext passes');
      System.assertEquals(
        null,
        trusted[3],
        'A forged file marker is not trusted'
      );
    }
  }

  @IsTest
  static void childPayloadCheckDoesNoQueryForPlaintext() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowPayloadCodecs.setCodec(null);
      Integer queriesBefore = Limits.getQueries();
      List<String> trusted = WorkflowChildPayloadProvenance.trustedOnly(
        new List<String>{ '{"a":1}' },
        new List<Id>{ null },
        new List<String>{ 'k' }
      );
      System.assertEquals('{"a":1}', trusted[0]);
      System.assertEquals(queriesBefore, Limits.getQueries(), 'No query');
    }
  }
}
