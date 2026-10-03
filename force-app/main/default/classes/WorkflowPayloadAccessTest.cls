/**
 * @description Tests for record-access checks in the decoding read APIs
 * (issue #243). A user without read access gets a placeholder, not plaintext.
 */
@IsTest
public class WorkflowPayloadAccessTest {
  private static final String SECRET = WorkflowPayloadCodecE2ETest.SECRET;

  private static User makeUser(String permSet) {
    User u;
    System.runAs(new User(Id = UserInfo.getUserId())) {
      u = insertUser(permSet);
    }
    return u;
  }

  private static User insertUser(String permSet) {
    Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
    String uniq = String.valueOf(Crypto.getRandomLong());
    User u = new User(
      Alias = 'rvn243',
      Email = 'rvn243' + uniq + '@example.com',
      EmailEncodingKey = 'UTF-8',
      LastName = 'Reader',
      LanguageLocaleKey = 'en_US',
      LocaleSidKey = 'en_US',
      ProfileId = p.Id,
      TimeZoneSidKey = 'America/Los_Angeles',
      Username = 'rvn243' + uniq + '@example.com'
    );
    insert u;
    if (permSet != null) {
      insert new PermissionSetAssignment(
        AssigneeId = u.Id,
        PermissionSetId = [SELECT Id FROM PermissionSet WHERE Name = :permSet]
        .Id
      );
    }
    return u;
  }

  private static Id completedInstance(String output) {
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = 'Test.Workflow',
      Status__c = 'Completed',
      Correlation_Key__c = 'acc-' + String.valueOf(Crypto.getRandomLong()),
      Output__c = output,
      Progress__c = output
    );
    insert inst;
    return inst.Id;
  }

  private static String encoded(String plain) {
    return WorkflowPayloadCodecs.encode(
      plain,
      CodecContext.PayloadKind.STEP_OUTPUT
    );
  }

  private static void useCodec() {
    WorkflowPayloadCodecs.setCodec(new WorkflowPayloadCodecE2ETest.AesCodec());
  }

  // ─── getStatus ──────────────────────────────────────────────────────────

  @IsTest
  static void getStatusRedactsWithoutAccess() {
    useCodec();
    Id id1 = completedInstance(encoded(SECRET));
    String key = [
      SELECT Correlation_Key__c
      FROM Workflow_Instance__c
      WHERE Id = :id1
    ]
    .Correlation_Key__c;
    User u = makeUser(null);
    System.runAs(u) {
      WorkflowEngine.WorkflowStatus byId = WorkflowStatusRead.getStatus(id1);
      WorkflowEngine.WorkflowStatus byKey = WorkflowStatusRead.getStatus(key);
      System.assertEquals(WorkflowPayloadAccess.DENIED_PAYLOAD, byId.output);
      System.assertEquals(WorkflowPayloadAccess.DENIED_PAYLOAD, byKey.output);
      System.assertEquals('Completed', byId.status, 'Status stays visible');
      System.assert(!byId.output.contains(SECRET), 'No plaintext');
    }
  }

  @IsTest
  static void getStatusDecodesWithAccess() {
    useCodec();
    Id id1 = completedInstance(encoded(SECRET));
    User u = makeUser('Revenant_Operator');
    System.runAs(u) {
      System.assertEquals(SECRET, WorkflowStatusRead.getStatus(id1).output);
    }
    System.assertEquals(
      SECRET,
      WorkflowStatusRead.getStatus(id1).output,
      'Admin reads plaintext'
    );
  }

  @IsTest
  static void bulkGetStatusUsesOneAccessQuery() {
    useCodec();
    List<Id> ids = new List<Id>{
      completedInstance(encoded(SECRET)),
      completedInstance(encoded(SECRET))
    };
    Test.startTest();
    Integer before = Limits.getQueries();
    WorkflowStatusRead.getStatus(ids);
    System.assertEquals(
      2,
      Limits.getQueries() - before,
      'Instance query and one access query'
    );
    Test.stopTest();
  }

  @IsTest
  static void offloadedEncodedOutputIsRedactedWithoutAccess() {
    useCodec();
    ContentVersion cv = new ContentVersion(
      Title = 'offload',
      PathOnClient = 'offload.json',
      VersionData = Blob.valueOf(encoded(SECRET))
    );
    insert cv;
    Id docId = [
      SELECT ContentDocumentId
      FROM ContentVersion
      WHERE Id = :cv.Id
    ]
    .ContentDocumentId;
    Id id1 = completedInstance('{"$attachmentId":"' + docId + '"}');
    // A marker resolves only when the file links to the instance.
    WorkflowPayloadOffload.linkToOwner(docId, id1);
    User u = makeUser(null);
    String userBefore;
    System.runAs(u) {
      userBefore = WorkflowStatusRead.getStatus(id1).output;
    }
    System.assertEquals(
      SECRET,
      WorkflowStatusRead.getStatus(id1).output,
      'Admin reads the file'
    );
    System.runAs(u) {
      Boolean hasRead = [
        SELECT HasReadAccess
        FROM UserRecordAccess
        WHERE UserId = :u.Id AND RecordId = :id1
      ]
      .HasReadAccess;
      String stored = [
        SELECT Output__c
        FROM Workflow_Instance__c
        WHERE Id = :id1
      ]
      .Output__c;
      System.assertEquals(
        WorkflowPayloadAccess.DENIED_PAYLOAD,
        WorkflowStatusRead.getStatus(id1).output,
        'DIAG userBefore=' +
          userBefore +
          ' hasRead=' +
          hasRead +
          ' stored=' +
          stored
      );
    }
  }

  // ─── identity codec ─────────────────────────────────────────────────────

  @IsTest
  static void identityCodecAddsNoAccessQuery() {
    WorkflowPayloadCodecs.setCodec(null);
    Id id1 = completedInstance('"plain"');
    Integer before = Limits.getQueries();
    WorkflowEngine.WorkflowStatus s = WorkflowStatusRead.getStatus(id1);
    System.assertEquals('"plain"', s.output);
    System.assertEquals(1, Limits.getQueries() - before, 'Instance query only');
  }

  // ─── Flow action ────────────────────────────────────────────────────────

  @IsTest
  static void flowActionRedactsOutputAndProgressWithoutAccess() {
    useCodec();
    Id id1 = completedInstance(encoded(SECRET));
    User u = makeUser(null);
    System.runAs(u) {
      WorkflowStatusInvocableAction.StatusRequest r = new WorkflowStatusInvocableAction.StatusRequest();
      r.workflowKeyOrId = id1;
      WorkflowStatusInvocableAction.StatusResult res = WorkflowStatusInvocableAction.getStatus(
        new List<WorkflowStatusInvocableAction.StatusRequest>{ r }
      )[0];
      System.assertEquals(WorkflowPayloadAccess.DENIED_PAYLOAD, res.outputJson);
      System.assertEquals(
        WorkflowPayloadAccess.DENIED_PAYLOAD,
        res.progressJson
      );
      System.assertEquals('Completed', res.status);
    }
  }

  @IsTest
  static void flowActionDecodesWithAccess() {
    useCodec();
    Id id1 = completedInstance(encoded(SECRET));
    User u = makeUser('Revenant_Operator');
    System.runAs(u) {
      WorkflowStatusInvocableAction.StatusRequest r = new WorkflowStatusInvocableAction.StatusRequest();
      r.workflowKeyOrId = id1;
      WorkflowStatusInvocableAction.StatusResult res = WorkflowStatusInvocableAction.getStatus(
        new List<WorkflowStatusInvocableAction.StatusRequest>{ r }
      )[0];
      System.assertEquals(SECRET, res.outputJson);
      System.assertEquals(SECRET, res.progressJson);
    }
  }

  // ─── lineage ────────────────────────────────────────────────────────────

  @IsTest
  static void lineageRedactsEveryAncestorWithoutAccess() {
    useCodec();
    Id parent = completedInstance(encoded(SECRET));
    Workflow_Instance__c child = new Workflow_Instance__c(
      Workflow_Name__c = 'Test.Workflow',
      Status__c = 'Completed',
      Correlation_Key__c = 'acc-child',
      Output__c = encoded(SECRET),
      Parent_Instance__c = parent
    );
    insert child;
    User u = makeUser(null);
    System.runAs(u) {
      List<WorkflowEngine.WorkflowStatus> lineage = WorkflowCausationLineage.getCausationLineage(
        child.Id
      );
      System.assertEquals(2, lineage.size());
      for (WorkflowEngine.WorkflowStatus s : lineage) {
        System.assertEquals(WorkflowPayloadAccess.DENIED_PAYLOAD, s.output);
      }
    }
  }

  // ─── gate unit tests ────────────────────────────────────────────────────

  @IsTest
  static void gateLeavesPlaintextAndBlankAlone() {
    useCodec();
    WorkflowPayloadAccess.Gate gate = new WorkflowPayloadAccess.Gate(
      new Set<Id>()
    );
    System.assertEquals('"x"', gate.decode('"x"', null));
    System.assertEquals(null, gate.decode(null, null));
  }

  @IsTest
  static void gateRedactsUnknownInstance() {
    useCodec();
    WorkflowPayloadAccess.Gate gate = new WorkflowPayloadAccess.Gate(
      new Set<Id>()
    );
    System.assertEquals(
      WorkflowPayloadAccess.DENIED_PAYLOAD,
      gate.decode(encoded(SECRET), completedInstance('"a"'))
    );
  }

  @IsTest
  static void deniedPayloadIsValidJson() {
    System.assert(
      JSON.deserializeUntyped(WorkflowPayloadAccess.DENIED_PAYLOAD) != null
    );
  }

  // ─── step error ─────────────────────────────────────────────────────────

  @IsTest
  static void stepErrorRedactsFailureDataWithoutAccess() {
    useCodec();
    Id instId = completedInstance('"x"');
    Workflow_Step_Execution__c exec = new Workflow_Step_Execution__c(
      Workflow_Instance__c = instId,
      Step_Name__c = 'S',
      Status__c = 'Failed',
      Retry_Count__c = 0,
      Error_Details__c = 'boom\nfailureData: ' + encoded(SECRET)
    );
    insert exec;
    System.assertEquals(
      'boom\nfailureData: ' + SECRET,
      WorkflowHistoryRead.getStepError(exec.Id),
      'Admin reads plaintext'
    );
    User u = makeUser(null);
    System.runAs(u) {
      String text = WorkflowHistoryRead.getStepError(exec.Id);
      System.assertEquals(
        'boom\nfailureData: ' + WorkflowPayloadAccess.DENIED_PAYLOAD,
        text
      );
    }
  }
}
