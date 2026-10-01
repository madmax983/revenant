/**
 * @description Tests for bulk payload offload (issue #244): the helper, and the
 * bulk start, bulk child start and bulk resume paths. DML cost must not grow
 * with the row count.
 */
@IsTest
private class WorkflowBulkOffloadTest {
  private static final String WF = 'WorkflowEngineTest.HappyWorkflow';
  private static final String OFFLOAD_PREFIX = '{"$attachmentId":';
  private static final Integer BIG = 100001;

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

  private static Workflow_Instance__c newInstance(
    String key,
    String status,
    String step
  ) {
    return new Workflow_Instance__c(
      Workflow_Name__c = WF,
      Correlation_Key__c = key,
      Status__c = status,
      Current_Step__c = step
    );
  }

  private static List<Workflow_Instance__c> insertInstances(
    String prefix,
    Integer count,
    String status,
    String step
  ) {
    List<Workflow_Instance__c> rows = new List<Workflow_Instance__c>();
    for (Integer i = 0; i < count; i++) {
      rows.add(newInstance(prefix + i, status, step));
    }
    insert as system rows;
    return rows;
  }

  private static Integer flaggedFileCount() {
    return [
      SELECT COUNT()
      FROM ContentVersion
      WHERE Revenant_Payload_Offload__c = TRUE
    ];
  }

  private static Id docIdOf(String marker) {
    return (Id) ((Map<String, Object>) JSON.deserializeUntyped(marker))
      .get('$attachmentId');
  }

  // ---- helper ----

  @IsTest
  static void helperUsesFixedDmlForManyLargeItems() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      List<Workflow_Instance__c> insts = insertInstances(
        'h',
        5,
        'Running',
        null
      );
      List<WorkflowBulkOffload.Item> items = new List<WorkflowBulkOffload.Item>();
      for (Integer i = 0; i < insts.size(); i++) {
        items.add(
          new WorkflowBulkOffload.Item(
            insts[i].Id,
            String.valueOf(i).repeat(BIG),
            'Input_' + insts[i].Id
          )
        );
      }
      Integer dml = Limits.getDmlStatements();
      Integer soql = Limits.getQueries();

      List<String> stored = WorkflowBulkOffload.save(items);

      Integer dmlUsed = Limits.getDmlStatements() - dml;
      System.assert(
        dmlUsed == 2 || dmlUsed == 3,
        'File insert, link insert, and at most one AllUsers retry: ' + dmlUsed
      );
      System.assertEquals(1, Limits.getQueries() - soql, 'One query');
      System.assertEquals(5, stored.size());
      for (Integer i = 0; i < 5; i++) {
        System.assert(stored[i].startsWith(OFFLOAD_PREFIX), 'Row ' + i);
        System.assertEquals(
          String.valueOf(i).repeat(BIG),
          WorkflowPayloadOffload.resolvePayload(stored[i], insts[i].Id),
          'Marker ' + i + ' points to its own file'
        );
        System.assertEquals(
          insts[i].Id,
          [
            SELECT LinkedEntityId
            FROM ContentDocumentLink
            WHERE
              ContentDocumentId = :docIdOf(stored[i])
              AND LinkedEntityId = :insts[i].Id
          ]
          .LinkedEntityId,
          'Link ' + i
        );
      }
      System.assertEquals(5, flaggedFileCount(), 'Every file is flagged');
    }
  }

  @IsTest
  static void helperKeepsSmallBlankAndNullInlineInOrder() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = insertInstances('m', 1, 'Running', null)[0];
      String exact = 'x'.repeat(100000);
      List<String> stored = WorkflowBulkOffload.save(
        new List<WorkflowBulkOffload.Item>{
          new WorkflowBulkOffload.Item(inst.Id, '{"a":1}', 'T1'),
          new WorkflowBulkOffload.Item(inst.Id, 'y'.repeat(BIG), 'T2'),
          new WorkflowBulkOffload.Item(inst.Id, null, 'T3'),
          new WorkflowBulkOffload.Item(inst.Id, '', 'T4'),
          new WorkflowBulkOffload.Item(inst.Id, exact, 'T5')
        }
      );

      System.assertEquals('{"a":1}', stored[0]);
      System.assert(stored[1].startsWith(OFFLOAD_PREFIX));
      System.assertEquals(null, stored[2]);
      System.assertEquals('', stored[3]);
      System.assertEquals(exact, stored[4], 'The limit itself stays inline');
      System.assertEquals(1, flaggedFileCount(), 'Only one file');
    }
  }

  @IsTest
  static void helperWithNoLargeItemsRunsNoDml() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = insertInstances('n', 1, 'Running', null)[0];
      Integer dml = Limits.getDmlStatements();
      Integer soql = Limits.getQueries();

      List<String> stored = WorkflowBulkOffload.save(
        new List<WorkflowBulkOffload.Item>{
          new WorkflowBulkOffload.Item(inst.Id, 'small', 'T')
        }
      );
      List<String> none = WorkflowBulkOffload.save(
        new List<WorkflowBulkOffload.Item>()
      );

      System.assertEquals('small', stored[0]);
      System.assert(none.isEmpty());
      System.assertEquals(0, Limits.getDmlStatements() - dml);
      System.assertEquals(0, Limits.getQueries() - soql);
    }
  }

  @IsTest
  static void helperSetsTitleAndFileName() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = insertInstances('t', 1, 'Running', null)[0];

      List<String> stored = WorkflowBulkOffload.save(
        new List<WorkflowBulkOffload.Item>{
          new WorkflowBulkOffload.Item(inst.Id, 'z'.repeat(BIG), 'Input_Title')
        }
      );

      ContentVersion cv = [
        SELECT Title, PathOnClient
        FROM ContentVersion
        WHERE ContentDocumentId = :docIdOf(stored[0]) AND IsLatest = TRUE
      ];
      System.assertEquals('Input_Title', cv.Title);
      System.assertEquals('Input_Title.json', cv.PathOnClient);
    }
  }

  @IsTest
  static void identityCodecStillOffloadsPlaintextOverLimit() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowPayloadCodecs.setCodec(null);
      Workflow_Instance__c inst = insertInstances('i', 1, 'Running', null)[0];

      String single = WorkflowPayloadOffload.savePayloadIfNeeded(
        inst.Id,
        'q'.repeat(BIG),
        'Output_Single'
      );

      System.assert(single.startsWith(OFFLOAD_PREFIX), 'Legacy behavior');
      System.assertEquals(
        'q'.repeat(BIG),
        WorkflowPayloadOffload.resolvePayload(single, inst.Id)
      );
    }
  }

  @IsTest
  static void linkInsertRetriesWithAllUsersThenThrows() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = insertInstances('l', 1, 'Running', null)[0];
      Integer dml = Limits.getDmlStatements();
      DmlException caught;

      try {
        // No document id: both attempts fail.
        WorkflowBulkOffload.insertLinks(
          new List<ContentDocumentLink>{
            new ContentDocumentLink(
              LinkedEntityId = inst.Id,
              ShareType = 'V',
              Visibility = 'InternalUsers'
            )
          }
        );
      } catch (DmlException ex) {
        caught = ex;
      }

      System.assertNotEquals(null, caught, 'The second failure is thrown');
      System.assertEquals(2, Limits.getDmlStatements() - dml, 'One retry');
    }
  }

  // ---- bulk start ----

  private static List<WorkflowEngine.StartRequest> startRequests(
    String prefix,
    Integer count
  ) {
    List<WorkflowEngine.StartRequest> reqs = new List<WorkflowEngine.StartRequest>();
    for (Integer i = 0; i < count; i++) {
      reqs.add(
        new WorkflowEngine.StartRequest(
          WF,
          prefix + i,
          new Map<String, Object>{ 'blob' => 'b'.repeat(BIG) }
        )
      );
    }
    return reqs;
  }

  private static Integer dmlFor(List<WorkflowEngine.StartRequest> reqs) {
    Integer before = Limits.getDmlStatements();
    WorkflowEngine.startOrGet(reqs);
    return Limits.getDmlStatements() - before;
  }

  @IsTest
  static void bulkStartDmlDoesNotGrowWithRows() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowPayloadCodecs.setCodec(new AesCodec());

      Integer two = dmlFor(startRequests('s2-', 2));
      Integer three = dmlFor(startRequests('s3-', 3));

      System.assertEquals(two, three, 'DML is the same for 2 and 3 rows');
      System.assertEquals(5, flaggedFileCount(), 'One file per row');
      for (Workflow_Instance__c inst : [
        SELECT Id, Input__c
        FROM Workflow_Instance__c
        WHERE Correlation_Key__c LIKE 's%'
      ]) {
        System.assert(inst.Input__c.startsWith(OFFLOAD_PREFIX));
        System.assert(
          WorkflowPayloadOffload.resolvePayload(inst.Input__c, inst.Id)
            .contains('bbbb'),
          'Input decodes to the original'
        );
      }
    }
  }

  // ---- bulk child start ----

  private static Integer childDmlFor(
    Id parentId,
    String prefix,
    Integer count
  ) {
    List<StepResult.ChildRequest> reqs = new List<StepResult.ChildRequest>();
    for (Integer i = 0; i < count; i++) {
      reqs.add(
        new StepResult.ChildRequest(
          WF,
          prefix + i,
          new Map<String, Object>{ 'blob' => 'c'.repeat(BIG) }
        )
      );
    }
    Integer before = Limits.getDmlStatements();
    WorkflowChildBulkService.startChildWorkflows(parentId, reqs);
    return Limits.getDmlStatements() - before;
  }

  @IsTest
  static void bulkChildStartDmlDoesNotGrowWithRows() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowPayloadCodecs.setCodec(new AesCodec());
      Id parentId = insertInstances('p', 1, 'Running', null)[0].Id;

      Integer two = childDmlFor(parentId, 'c2-', 2);
      Integer three = childDmlFor(parentId, 'c3-', 3);

      System.assertEquals(two, three, 'DML is the same for 2 and 3 rows');
      System.assertEquals(5, flaggedFileCount(), 'One file per row');
      for (Workflow_Instance__c child : [
        SELECT Input__c
        FROM Workflow_Instance__c
        WHERE Correlation_Key__c LIKE 'c%'
      ]) {
        System.assert(child.Input__c.startsWith(OFFLOAD_PREFIX));
      }
    }
  }

  // ---- bulk resume ----

  private static List<WorkflowEngine.ResumeRequest> suspendedResumes(
    String prefix,
    Integer count
  ) {
    List<Workflow_Instance__c> insts = insertInstances(
      prefix,
      count,
      'Suspended',
      'S1'
    );
    List<Workflow_Step_Execution__c> steps = new List<Workflow_Step_Execution__c>();
    List<WorkflowEngine.ResumeRequest> reqs = new List<WorkflowEngine.ResumeRequest>();
    for (Workflow_Instance__c inst : insts) {
      steps.add(
        new Workflow_Step_Execution__c(
          Workflow_Instance__c = inst.Id,
          Step_Name__c = 'S1',
          Status__c = 'Suspended'
        )
      );
      reqs.add(new WorkflowEngine.ResumeRequest(inst.Id, 'r'.repeat(BIG)));
    }
    insert as system steps;
    return reqs;
  }

  @IsTest
  static void bulkResumeDmlDoesNotGrowWithRows() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowPayloadCodecs.setCodec(new AesCodec());
      List<WorkflowEngine.ResumeRequest> two = suspendedResumes('r2-', 2);
      List<WorkflowEngine.ResumeRequest> three = suspendedResumes('r3-', 3);

      Integer before = Limits.getDmlStatements();
      WorkflowBulkResumeService.resume(two);
      Integer dmlTwo = Limits.getDmlStatements() - before;
      before = Limits.getDmlStatements();
      WorkflowBulkResumeService.resume(three);
      Integer dmlThree = Limits.getDmlStatements() - before;

      System.assertEquals(dmlTwo, dmlThree, 'DML is the same for 2 and 6 rows');
      System.assertEquals(5, flaggedFileCount(), 'One file per row');
      for (Workflow_Step_Execution__c step : [
        SELECT Output__c, Workflow_Instance__c
        FROM Workflow_Step_Execution__c
        WHERE Workflow_Instance__r.Correlation_Key__c LIKE 'r%'
      ]) {
        System.assert(step.Output__c.startsWith(OFFLOAD_PREFIX));
        System.assertEquals(
          'r'.repeat(BIG),
          WorkflowPayloadOffload.resolvePayload(
            step.Output__c,
            step.Workflow_Instance__c
          ),
          'Output decodes to the resume payload'
        );
      }
    }
  }

  @IsTest
  static void bulkResumeKeepsSmallPayloadInline() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowPayloadCodecs.setCodec(null);
      List<WorkflowEngine.ResumeRequest> reqs = suspendedResumes('k', 2);
      reqs[0] = new WorkflowEngine.ResumeRequest(
        reqs[0].instanceId,
        '{"ok":true}'
      );

      WorkflowBulkResumeService.resume(reqs);

      System.assertEquals(1, flaggedFileCount(), 'Only the large row offloads');
      System.assertEquals(
        '{"ok":true}',
        [
          SELECT Output__c
          FROM Workflow_Step_Execution__c
          WHERE Workflow_Instance__c = :reqs[0].instanceId
        ]
        .Output__c
      );
    }
  }
}
