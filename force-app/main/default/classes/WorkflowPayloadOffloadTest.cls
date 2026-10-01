/**
 * @description Tests that `savePayloadIfNeeded` flags the file it writes. A small
 * payload writes no file.
 */
@IsTest
private class WorkflowPayloadOffloadTest {
  private static Workflow_Instance__c newInstance() {
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
      Status__c = 'Running',
      Correlation_Key__c = 'OffloadFlagKey'
    );
    insert inst;
    return inst;
  }

  @IsTest
  static void testLargePayloadFileIsFlagged() {
    Workflow_Instance__c inst = newInstance();

    String marker = WorkflowPayloadOffload.savePayloadIfNeeded(
      inst.Id,
      'x'.repeat(100001),
      'Output_FlagCheck'
    );

    Id docId = (Id) ((Map<String, Object>) JSON.deserializeUntyped(marker))
      .get('$attachmentId');
    ContentVersion cv = [
      SELECT Revenant_Payload_Offload__c
      FROM ContentVersion
      WHERE ContentDocumentId = :docId AND IsLatest = TRUE
    ];
    System.assertEquals(
      true,
      cv.Revenant_Payload_Offload__c,
      'The offloaded file carries the engine flag'
    );
  }

  @IsTest
  static void testSmallPayloadWritesNoFile() {
    Workflow_Instance__c inst = newInstance();

    String stored = WorkflowPayloadOffload.savePayloadIfNeeded(
      inst.Id,
      '{"a":1}',
      'Output_Small'
    );

    System.assertEquals('{"a":1}', stored, 'A small payload stays inline');
    System.assertEquals(
      0,
      [
        SELECT COUNT()
        FROM ContentVersion
        WHERE Revenant_Payload_Offload__c = TRUE
      ],
      'No flagged file exists'
    );
  }

  private static Workflow_Instance__c childOf(Workflow_Instance__c parent) {
    Workflow_Instance__c child = new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
      Status__c = 'Completed',
      Correlation_Key__c = 'OffloadChildKey',
      Parent_Instance__c = parent.Id
    );
    insert child;
    return child;
  }

  private static String offload(Id ownerId, String text) {
    return WorkflowPayloadOffload.savePayloadIfNeeded(
      ownerId,
      text.rightPad(100001, ' '),
      'Output_Own'
    );
  }

  @IsTest
  static void testOwnMarkerResolves() {
    Workflow_Instance__c inst = newInstance();
    String marker = offload(inst.Id, '{"own":1}');

    String text = WorkflowPayloadOffload.resolvePayload(marker, inst.Id);

    System.assert(text.startsWith('{"own":1}'), 'The owner reads its file');
  }

  @IsTest
  static void testForgedMarkerDoesNotReturnOtherInstanceFile() {
    Workflow_Instance__c victim = newInstance();
    Workflow_Instance__c attacker = new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
      Status__c = 'Running',
      Correlation_Key__c = 'AttackerKey'
    );
    insert attacker;
    String forged = offload(victim.Id, '{"secret":1}');

    String text = WorkflowPayloadOffload.resolvePayload(forged, attacker.Id);

    System.assertEquals(forged, text, 'A foreign marker stays unresolved');
    System.assert(!text.contains('secret'), 'The file text does not leak');
  }

  @IsTest
  static void testUnlinkedFileDoesNotResolve() {
    Workflow_Instance__c inst = newInstance();
    ContentVersion cv = new ContentVersion(
      Title = 'Unrelated',
      PathOnClient = 'Unrelated.json',
      VersionData = Blob.valueOf('{"org":"file"}')
    );
    insert cv;
    Id docId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id]
    .ContentDocumentId;
    String forged = JSON.serialize(
      new Map<String, String>{ '$attachmentId' => docId }
    );

    System.assertEquals(
      forged,
      WorkflowPayloadOffload.resolvePayload(forged, inst.Id),
      'An unlinked org file stays unresolved'
    );
  }

  @IsTest
  static void testBulkResolveChecksEachOwnerWithOneQueryPerObject() {
    Workflow_Instance__c a = newInstance();
    Workflow_Instance__c b = childOf(a);
    String markerA = offload(a.Id, '{"a":1}');
    String markerB = offload(b.Id, '{"b":1}');

    Test.startTest();
    Integer before = Limits.getQueries();
    List<String> out = WorkflowPayloadOffload.resolvePayloads(
      new List<String>{ markerA, markerB, '{"inline":1}' },
      new List<Id>{ a.Id, a.Id, a.Id }
    );
    Integer used = Limits.getQueries() - before;
    Test.stopTest();

    System.assert(out[0].startsWith('{"a":1}'), 'Own file resolves');
    System.assertEquals(markerB, out[1], 'A sibling-owned file stays marker');
    System.assertEquals('{"inline":1}', out[2], 'Inline value is unchanged');
    System.assert(used <= 2, 'Bulk read stays constant: ' + used);
  }

  @IsTest
  static void testChildPayloadsResolveChildFilesOnly() {
    Workflow_Instance__c parent = newInstance();
    Workflow_Instance__c child = childOf(parent);
    Workflow_Instance__c stranger = new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
      Status__c = 'Running',
      Correlation_Key__c = 'StrangerKey'
    );
    insert stranger;
    String childMarker = offload(child.Id, '{"child":1}');
    String strangerMarker = offload(stranger.Id, '{"stranger":1}');

    List<String> out = WorkflowPayloadOffload.resolveChildPayloads(
      new List<String>{ childMarker, strangerMarker },
      parent.Id
    );

    System.assert(out[0].startsWith('{"child":1}'), 'Child file resolves');
    System.assertEquals(strangerMarker, out[1], 'Foreign file stays marker');
  }

  @IsTest
  static void testControlPayloadChecksOwner() {
    Workflow_Instance__c inst = newInstance();
    Workflow_Instance__c other = childOf(inst);
    String marker = offload(inst.Id, '{"waitingForApproval":true}');

    System.assert(
      WorkflowPayloadOffload.resolveControlPayload(marker, inst.Id)
        .startsWith('{"waitingForApproval"'),
      'The owner reads its control file'
    );
    System.assertEquals(
      marker,
      WorkflowPayloadOffload.resolveControlPayload(marker, other.Id),
      'A foreign instance does not read it'
    );
  }

  @IsTest
  static void testRejectOffloadMarker() {
    WorkflowPayloadOffload.rejectOffloadMarker('{"a":1}', 'Input');
    WorkflowPayloadOffload.rejectOffloadMarker(null, 'Input');
    try {
      WorkflowPayloadOffload.rejectOffloadMarker(
        '{"$attachmentId":"069000000000001AAA"}',
        'Input'
      );
      System.assert(false, 'A marker must be rejected');
    } catch (WorkflowEngine.WorkflowException e) {
      System.assert(e.getMessage().contains('Input'), e.getMessage());
    }
  }

  @IsTest
  static void testNullOwnerAndMalformedMarkerPassThrough() {
    Workflow_Instance__c inst = newInstance();
    String marker = offload(inst.Id, '{"own":1}');
    String malformed = '{"$attachmentId":"not-an-id"}';
    String wrongType = JSON.serialize(
      new Map<String, String>{ '$attachmentId' => String.valueOf(inst.Id) }
    );

    List<String> out = WorkflowPayloadOffload.resolvePayloads(
      new List<String>{ marker, malformed, null },
      new List<Id>{ null, inst.Id, inst.Id }
    );

    System.assertEquals(marker, out[0], 'A null owner resolves nothing');
    System.assertEquals(malformed, out[1], 'A malformed marker passes through');
    System.assertEquals(null, out[2], 'A null value stays null');
    System.assertEquals(
      null,
      WorkflowPayloadOffload.markerDocId(wrongType),
      'An Id of another type is not a file marker'
    );
    System.assertEquals(
      0,
      WorkflowPayloadOffload.loadOwned(new List<Id>(), new List<Id>(), true)
        .size(),
      'No pairs load nothing'
    );
  }

  @IsTest
  static void testChildFileResolvesOnlyOnChildPath() {
    Workflow_Instance__c parent = newInstance();
    Workflow_Instance__c child = childOf(parent);
    String childMarker = offload(child.Id, '{"child":1}');

    System.assertEquals(
      childMarker,
      WorkflowPayloadOffload.resolvePayload(childMarker, parent.Id),
      'The plain path does not read a child file'
    );
    List<String> viaChild = WorkflowPayloadOffload.resolveChildPayloads(
      new List<String>{ childMarker },
      child.Id
    );
    System.assert(viaChild[0].startsWith('{"child":1}'), 'Own file resolves');
  }

  @IsTest
  static void testChildOfOtherParentDoesNotResolve() {
    Workflow_Instance__c parent = newInstance();
    Workflow_Instance__c otherParent = new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
      Status__c = 'Running',
      Correlation_Key__c = 'OtherParentKey'
    );
    insert otherParent;
    Workflow_Instance__c foreignChild = childOf(otherParent);
    String marker = offload(foreignChild.Id, '{"foreign":1}');

    List<String> out = WorkflowPayloadOffload.resolveChildPayloads(
      new List<String>{ marker },
      parent.Id
    );

    System.assertEquals(marker, out[0], 'A child of another parent stays text');
  }

  @IsTest
  static void testPrefetchedLinksNeedNoLinkQuery() {
    Workflow_Instance__c a = newInstance();
    Workflow_Instance__c b = childOf(a);
    String markerA = offload(a.Id, '{"a":1}');
    String markerB = offload(b.Id, '{"b":1}');
    List<String> raw = new List<String>{ markerA, markerB };
    List<Id> owners = new List<Id>{ a.Id, a.Id };
    Map<Id, Set<Id>> links = WorkflowPayloadOffload.linksFor(raw);

    Integer before = Limits.getQueries();
    List<String> out = WorkflowPayloadOffload.resolvePayloads(
      raw,
      owners,
      links
    );
    Integer used = Limits.getQueries() - before;

    System.assert(out[0].startsWith('{"a":1}'), 'Own file resolves');
    System.assertEquals(markerB, out[1], 'A foreign file stays marker');
    System.assertEquals(1, used, 'Only the file query runs: ' + used);
  }
}
