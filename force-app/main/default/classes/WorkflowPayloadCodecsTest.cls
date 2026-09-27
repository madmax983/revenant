/**
 * @description Unit tests for the payload codec seam: WorkflowPayloadCodecs, PayloadCodec,
 * CodecContext, IdentityPayloadCodec and the codec hooks in
 * WorkflowPayloadOffload.
 */
@IsTest
private class WorkflowPayloadCodecsTest {
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

  /** @description Test codec whose output needs JSON escapes. */
  private class QuotingCodec implements PayloadCodec {
    /**
     * @description Encodes the payload.
     * @param plaintext the payload text
     * @param ctx the payload context
     * @return the encoded text
     */
    public String encode(String plaintext, CodecContext ctx) {
      return '"' + plaintext.reverse() + '"\n';
    }

    /**
     * @description Decodes the payload.
     * @param stored the encoded text
     * @param ctx the payload context
     * @return the payload text
     */
    public String decode(String stored, CodecContext ctx) {
      return stored.substring(1, stored.length() - 2).reverse();
    }
  }

  private static Workflow_Instance__c insertInstance() {
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowPayloadCodecsTest.Stub',
      Correlation_Key__c = 'codec-key-' + Crypto.getRandomInteger(),
      Status__c = 'Completed'
    );
    insert as system inst;
    return inst;
  }

  // ─── identity (default) ─────────────────────────────────────────────────

  @IsTest
  static void defaultCodecIsIdentityAndKeepsBytes() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowPayloadCodecs.setCodec(null);
      String plain = '{"ssn":"' + SECRET + '"}';

      System.assert(
        WorkflowPayloadCodecs.isIdentity(),
        'No config must mean identity'
      );
      System.assertEquals(
        plain,
        WorkflowPayloadCodecs.encode(
          plain,
          CodecContext.PayloadKind.WORKFLOW_INPUT
        ),
        'Identity encode must keep the bytes'
      );
      System.assertEquals(
        plain,
        WorkflowPayloadCodecs.decode(plain),
        'Identity decode must keep the bytes'
      );
    }
  }

  @IsTest
  static void identityCodecClassReturnsInput() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      PayloadCodec codec = new IdentityPayloadCodec();
      CodecContext ctx = new CodecContext(CodecContext.PayloadKind.STEP_OUTPUT);
      System.assertEquals('abc', codec.encode('abc', ctx));
      System.assertEquals('abc', codec.decode('abc', ctx));
      System.assertEquals(
        CodecContext.PayloadKind.STEP_OUTPUT,
        ctx.kind,
        'Context must keep its kind'
      );
    }
  }

  @IsTest
  static void identityOffloadKeepsLegacyBehavior() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowPayloadCodecs.setCodec(null);
      Workflow_Instance__c inst = insertInstance();
      String small = '{"a":1}';
      String big = 'P'.repeat(100001);

      String storedSmall = WorkflowPayloadOffload.savePayloadIfNeeded(
        inst.Id,
        small,
        'Small'
      );
      String storedBig = WorkflowPayloadOffload.savePayloadIfNeeded(
        inst.Id,
        big,
        'Big'
      );

      System.assertEquals(small, storedSmall, 'Small stays inline as-is');
      System.assert(storedBig.startsWith(OFFLOAD_PREFIX), 'Big offloads');
      ContentVersion cv = [
        SELECT VersionData
        FROM ContentVersion
        WHERE Title = 'Big'
        LIMIT 1
      ];
      System.assertEquals(
        big,
        cv.VersionData.toString(),
        'Identity blob stays plaintext'
      );
    }
  }

  // ─── encrypting codec ───────────────────────────────────────────────────

  @IsTest
  static void encodeWrapsCiphertextInEnvelope() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      AesCodec codec = new AesCodec();
      WorkflowPayloadCodecs.setCodec(codec);
      String plain = '{"ssn":"' + SECRET + '"}';

      String stored = WorkflowPayloadCodecs.encode(
        plain,
        CodecContext.PayloadKind.SIGNAL_PAYLOAD
      );

      System.assert(stored.startsWith(ENVELOPE_PREFIX), 'Envelope expected');
      System.assert(!stored.contains(SECRET), 'No plaintext at rest');
      System.assert(WorkflowPayloadCodecs.isEncoded(stored));
      System.assertEquals(plain, WorkflowPayloadCodecs.decode(stored));
      System.assertEquals(
        new List<CodecContext.PayloadKind>{
          CodecContext.PayloadKind.SIGNAL_PAYLOAD
        },
        codec.encodedKinds,
        'Encode gets the payload kind'
      );
      System.assertEquals(
        codec.encodedKinds,
        codec.decodedKinds,
        'Decode gets the same kind as encode'
      );
    }
  }

  @IsTest
  static void encodeAlwaysEncodesExternalInput() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      AesCodec codec = new AesCodec();
      WorkflowPayloadCodecs.setCodec(codec);
      String once = WorkflowPayloadCodecs.encode(
        'x',
        CodecContext.PayloadKind.STEP_OUTPUT
      );
      String marker = '{"$attachmentId":"069000000000001AAA"}';

      String twice = WorkflowPayloadCodecs.encode(
        once,
        CodecContext.PayloadKind.SIGNAL_PAYLOAD
      );
      System.assertNotEquals(once, twice, 'A copied envelope is input too');
      System.assertEquals(
        once,
        WorkflowPayloadCodecs.decode(twice),
        'A replayed envelope decodes to its own text, not to plaintext'
      );
      System.assertEquals(
        once,
        WorkflowPayloadCodecs.encodeStored(
          once,
          CodecContext.PayloadKind.STEP_OUTPUT
        ),
        'Engine copies keep the stored form'
      );
      System.assertEquals(
        marker,
        WorkflowPayloadCodecs.encode(
          marker,
          CodecContext.PayloadKind.STEP_OUTPUT
        ),
        'Offload marker stays plaintext'
      );
    }
  }

  @IsTest
  static void escapedCodecOutputRoundTrips() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowPayloadCodecs.setCodec(new QuotingCodec());
      String plain = 'a"b\\c\nd é';

      String stored = WorkflowPayloadCodecs.encode(
        plain,
        CodecContext.PayloadKind.STEP_STATE
      );

      JSON.deserializeUntyped(stored);
      System.assert(WorkflowPayloadCodecs.isEncoded(stored));
      System.assertEquals(plain, WorkflowPayloadCodecs.decode(stored));
    }
  }

  @IsTest
  static void blankAndLegacyValuesPassThrough() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      AesCodec codec = new AesCodec();
      WorkflowPayloadCodecs.setCodec(codec);

      System.assertEquals(
        null,
        WorkflowPayloadCodecs.encode(null, CodecContext.PayloadKind.STEP_STATE)
      );
      System.assertEquals(
        '',
        WorkflowPayloadCodecs.encode('', CodecContext.PayloadKind.STEP_STATE)
      );
      System.assertEquals(null, WorkflowPayloadCodecs.decode(null));
      System.assertEquals(
        '{"legacy":true}',
        WorkflowPayloadCodecs.decode('{"legacy":true}'),
        'Plaintext rows from before the codec stay readable'
      );
      System.assertEquals(0, codec.decodedKinds.size(), 'No codec call');
    }
  }

  @IsTest
  static void decodeEnvelopeWithoutCodecThrows() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowPayloadCodecs.setCodec(new AesCodec());
      String stored = WorkflowPayloadCodecs.encode(
        'x',
        CodecContext.PayloadKind.STEP_OUTPUT
      );
      WorkflowPayloadCodecs.setCodec(null);

      Boolean thrown = false;
      try {
        WorkflowPayloadCodecs.decode(stored);
      } catch (WorkflowPayloadCodecs.PayloadCodecException e) {
        thrown = true;
      }
      System.assert(thrown, 'Ciphertext must never reach a step as plaintext');
    }
  }

  @IsTest
  static void unknownKindIsPlaintext() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowPayloadCodecs.setCodec(null);
      String odd = '{"$codec":"NOT_A_KIND","data":"x"}';
      System.assert(!WorkflowPayloadCodecs.isEncoded(odd));
      System.assertEquals(
        odd,
        WorkflowPayloadCodecs.decode(odd),
        'Only a valid engine envelope is decoded'
      );
    }
  }

  @IsTest
  static void codecFailureIsWrappedWithoutPayload() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowPayloadCodecs.setCodec(new AesCodec());
      String bad = '{"$codec":"STEP_OUTPUT","data":"' + SECRET + '"}';
      String message;
      try {
        WorkflowPayloadCodecs.decode(bad);
      } catch (WorkflowPayloadCodecs.PayloadCodecException e) {
        message = e.getMessage();
      }
      System.assertNotEquals(null, message, 'Bad ciphertext must fail closed');
      System.assert(!message.contains(SECRET), 'No payload in the message');
    }
  }

  @IsTest
  static void configReadFailureFailsClosed() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.payloadCodecConfigFailed = true;
      Boolean thrown = false;
      try {
        WorkflowPayloadCodecs.isIdentity();
      } catch (WorkflowPayloadCodecs.PayloadCodecException e) {
        thrown = true;
      }
      System.assert(thrown, 'No silent fallback to plaintext');
    }
  }

  @IsTest
  static void decodeDoesNoDml() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowPayloadCodecs.setCodec(new AesCodec());
      Workflow_Instance__c inst = insertInstance();
      String stored = WorkflowPayloadOffload.savePayloadIfNeeded(
        inst.Id,
        WorkflowPayloadCodecs.encode(
          'Q'.repeat(100001),
          CodecContext.PayloadKind.STEP_OUTPUT
        ),
        'ReadOnly'
      );

      Integer dmlBefore = Limits.getDmlStatements();
      WorkflowPayloadCodecs.decode(
        WorkflowPayloadCodecs.encode('r', CodecContext.PayloadKind.STEP_OUTPUT)
      );
      WorkflowPayloadOffload.resolvePayload(stored);
      WorkflowPayloadOffload.resolvePayloads(new List<String>{ stored });
      System.assertEquals(
        dmlBefore,
        Limits.getDmlStatements(),
        'Decode is read-only'
      );
    }
  }

  // ─── offload seam ───────────────────────────────────────────────────────

  @IsTest
  static void savePayloadEncodesInlineValue() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowPayloadCodecs.setCodec(new AesCodec());
      Workflow_Instance__c inst = insertInstance();
      String plain = '{"ssn":"' + SECRET + '"}';

      String stored = WorkflowPayloadOffload.savePayloadIfNeeded(
        inst.Id,
        WorkflowPayloadCodecs.encode(
          plain,
          CodecContext.PayloadKind.STEP_OUTPUT
        ),
        'Inline'
      );

      System.assert(stored.startsWith(ENVELOPE_PREFIX), 'Envelope expected');
      System.assert(!stored.contains(SECRET), 'No plaintext inline');
      System.assertEquals(plain, WorkflowPayloadOffload.resolvePayload(stored));
      System.assertEquals(
        plain,
        WorkflowPayloadOffload.resolvePayloads(new List<String>{ stored })[0]
      );
    }
  }

  @IsTest
  static void savePayloadEncodesOffloadBlob() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowPayloadCodecs.setCodec(new AesCodec());
      Workflow_Instance__c inst = insertInstance();
      String plain = SECRET + 'Z'.repeat(100001);

      String stored = WorkflowPayloadOffload.savePayloadIfNeeded(
        inst.Id,
        WorkflowPayloadCodecs.encode(
          plain,
          CodecContext.PayloadKind.STEP_OUTPUT
        ),
        'Offloaded'
      );

      System.assert(stored.startsWith(OFFLOAD_PREFIX), 'Marker stays plain');
      ContentVersion cv = [
        SELECT VersionData
        FROM ContentVersion
        WHERE Title = 'Offloaded'
        LIMIT 1
      ];
      String fileText = cv.VersionData.toString();
      System.assert(fileText.startsWith(ENVELOPE_PREFIX), 'Blob is enveloped');
      System.assert(!fileText.contains(SECRET), 'No plaintext in the blob');
      System.assertEquals(plain, WorkflowPayloadOffload.resolvePayload(stored));
      System.assertEquals(
        plain,
        WorkflowPayloadOffload.resolvePayloads(new List<String>{ stored })[0]
      );
    }
  }

  @IsTest
  static void savePayloadOffloadsWhenCiphertextOutgrowsField() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowPayloadCodecs.setCodec(new AesCodec());
      Workflow_Instance__c inst = insertInstance();
      // 90 000 plaintext chars grow past 100 000 after AES + base64.
      String plain = 'W'.repeat(90000);

      String stored = WorkflowPayloadOffload.savePayloadIfNeeded(
        inst.Id,
        WorkflowPayloadCodecs.encode(
          plain,
          CodecContext.PayloadKind.STEP_OUTPUT
        ),
        'Grown'
      );

      System.assert(
        stored.startsWith(OFFLOAD_PREFIX),
        'The offload test must use the encoded length'
      );
      System.assertEquals(plain, WorkflowPayloadOffload.resolvePayload(stored));
    }
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
        Payload__c = WorkflowSignalPayloads.encode('Go', big)
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
            Payload__c = WorkflowSignalPayloads.encode('Go', plain)
          )
        );
      }
      Workflow_Signal__c unowned = new Workflow_Signal__c(
        Signal_Name__c = 'Go',
        Payload__c = WorkflowSignalPayloads.encode(
          'Go',
          '{"ssn":"' + SECRET + '"}'
        )
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
  static void childSignalsKeepStoredForm() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowPayloadCodecs.setCodec(new AesCodec());
      String childOutput = WorkflowPayloadCodecs.encode(
        '{"score":1}',
        CodecContext.PayloadKind.STEP_OUTPUT
      );

      System.assertEquals(
        childOutput,
        WorkflowSignalPayloads.encode('ChildCompleted:k1', childOutput),
        'Child output is already stored'
      );
      System.assertNotEquals(
        childOutput,
        WorkflowSignalPayloads.encode('Approve', childOutput),
        'Other signals always encode'
      );
    }
  }

  @IsTest
  static void findReservedMarkerFindsStoredFormKeys() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      System.assertEquals(
        '$attachmentId',
        WorkflowPayloadCodecs.findReservedMarker('{"$attachmentId":"x"}')
      );
      System.assertEquals(
        '$codec',
        WorkflowPayloadCodecs.findReservedMarker('{"a":{"$codec":"x"}}')
      );
      System.assertEquals(
        null,
        WorkflowPayloadCodecs.findReservedMarker('{"note":"see $codec docs"}'),
        'Only a quoted reserved token matches'
      );
      System.assertEquals(null, WorkflowPayloadCodecs.findReservedMarker(null));
    }
  }

  @IsTest
  static void redactForLogHidesPayloadOnlyWithCodec() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      String plain = '{"ssn":"' + SECRET + '"}';
      System.assertEquals(plain, WorkflowPayloadCodecs.redactForLog(plain));

      WorkflowPayloadCodecs.setCodec(new AesCodec());
      System.assertEquals(
        WorkflowPayloadCodecs.REDACTED_PAYLOAD,
        WorkflowPayloadCodecs.redactForLog(plain)
      );
      System.assertEquals(null, WorkflowPayloadCodecs.redactForLog(null));
    }
  }

  @IsTest
  static void resolveControlPayloadSkipsAuthorCiphertext() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      String marker = '{"waitingForApproval":true,"approvalKey":"K"}';
      WorkflowPayloadCodecs.setCodec(new AesCodec());
      String encoded = WorkflowPayloadCodecs.encode(
        '{"state":"' + SECRET + '"}',
        CodecContext.PayloadKind.STEP_STATE
      );

      System.assertEquals(
        marker,
        WorkflowPayloadOffload.resolveControlPayload(marker),
        'Control markers stay readable'
      );
      System.assertEquals(
        null,
        WorkflowPayloadOffload.resolveControlPayload(encoded),
        'Operator views do not decode author state'
      );
    }
  }

  // ─── configuration ──────────────────────────────────────────────────────

  @IsTest
  static void resolveControlPayloadSkipsOffloadedCiphertext() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowPayloadCodecs.setCodec(new AesCodec());
      Workflow_Instance__c inst = insertInstance();
      String bigState = WorkflowPayloadOffload.savePayloadIfNeeded(
        inst.Id,
        WorkflowPayloadCodecs.encode(
          'T'.repeat(100001),
          CodecContext.PayloadKind.STEP_STATE
        ),
        'State_Big'
      );
      String bigMarker = WorkflowPayloadOffload.savePayloadIfNeeded(
        inst.Id,
        '{"childCorrelationKeys":["' + 'k'.repeat(100001) + '"]}',
        'State_Keys'
      );
      WorkflowPayloadCodecs.setCodec(null);

      List<String> resolved = WorkflowPayloadOffload.resolveControlPayloads(
        new List<String>{ bigState, bigMarker }
      );

      System.assertEquals(
        null,
        resolved[0],
        'Offloaded author state is not decoded, even without a codec'
      );
      System.assert(
        resolved[1].startsWith('{"childCorrelationKeys"'),
        'Offloaded control markers resolve'
      );
    }
  }

  @IsTest
  static void resolveBlankNameIsIdentity() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      System.assertEquals(null, WorkflowPayloadCodecs.resolve(null));
      System.assertEquals(null, WorkflowPayloadCodecs.resolve('  '));
    }
  }

  @IsTest
  static void resolveNamedIdentityCodec() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      PayloadCodec codec = WorkflowPayloadCodecs.resolve(
        'IdentityPayloadCodec'
      );
      System.assert(codec instanceof IdentityPayloadCodec);
      WorkflowPayloadCodecs.setCodec(codec);
      System.assert(
        WorkflowPayloadCodecs.isIdentity(),
        'Named identity keeps legacy bytes'
      );
    }
  }

  @IsTest
  static void resolveUnknownClassThrows() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Boolean thrown = false;
      try {
        WorkflowPayloadCodecs.resolve('No_Such_Codec_Class_X');
      } catch (WorkflowPayloadCodecs.PayloadCodecException e) {
        thrown = true;
      }
      System.assert(thrown, 'A bad codec name must fail closed');
    }
  }

  @IsTest
  static void resolveNonCodecClassThrows() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Boolean thrown = false;
      try {
        WorkflowPayloadCodecs.resolve('WorkflowPayloadOffload');
      } catch (WorkflowPayloadCodecs.PayloadCodecException e) {
        thrown = true;
      }
      System.assert(thrown, 'A class that is not a codec must fail closed');
    }
  }
}
