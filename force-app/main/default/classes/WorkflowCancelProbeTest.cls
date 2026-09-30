/**
 * @description Tests for `WorkflowCancelProbe` (issue #143). The probe reads
 * the status of an instance and of its five nearest ancestors in one SOQL.
 */
@IsTest
private class WorkflowCancelProbeTest {
  private static Integer keySequence = 0;

  private static Id insertInstance(String status, Id parentId) {
    keySequence++;
    Workflow_Instance__c row = new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowCancelProbeTest.NoWorkflow',
      Status__c = status,
      Current_Step__c = 'StepA',
      Parent_Instance__c = parentId,
      Correlation_Key__c = 'Probe_' + keySequence
    );
    insert row;
    return row.Id;
  }

  // Inserts a chain: the first status is the root. Returns the Ids, root first.
  private static List<Id> insertChain(List<String> statuses) {
    List<Id> ids = new List<Id>();
    Id parentId = null;
    for (String status : statuses) {
      parentId = insertInstance(status, parentId);
      ids.add(parentId);
    }
    return ids;
  }

  private static Boolean probe(Id instanceId) {
    return new WorkflowCancelProbe(instanceId).isCancellationRequested();
  }

  @IsTest
  static void activeInstanceGivesFalse() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      List<Id> chain = insertChain(new List<String>{ 'Running', 'Running' });
      Assert.isFalse(probe(chain[1]));
      Assert.isNull(WorkflowCancelProbe.ancestorCancelStatus(chain[1]));
    }
  }

  @IsTest
  static void cancelledInstanceGivesTrue() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Assert.isTrue(probe(insertInstance('Cancelled', null)));
    }
  }

  @IsTest
  static void cancellingInstanceGivesTrue() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Assert.isTrue(probe(insertInstance('Cancelling', null)));
    }
  }

  @IsTest
  static void otherStatusesGiveFalse() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      for (
        String status : new List<String>{
          'Pending',
          'Suspended',
          'Held',
          'Compensating',
          'Failed',
          'Completed'
        }
      ) {
        Assert.isFalse(probe(insertInstance(status, null)), status);
      }
    }
  }

  @IsTest
  static void cancelledParentGivesTrue() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      List<Id> chain = insertChain(new List<String>{ 'Cancelled', 'Running' });
      Assert.isTrue(probe(chain[1]));
      Assert.areEqual(
        'Cancelled',
        WorkflowCancelProbe.ancestorCancelStatus(chain[1])
      );
    }
  }

  @IsTest
  static void nearestCancelledAncestorWins() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      List<Id> chain = insertChain(
        new List<String>{ 'Cancelled', 'Cancelling', 'Running' }
      );
      Assert.areEqual(
        'Cancelling',
        WorkflowCancelProbe.ancestorCancelStatus(chain[2])
      );
    }
  }

  @IsTest
  static void fifthAncestorIsRead() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Root is five levels above the leaf.
      List<Id> chain = insertChain(
        new List<String>{
          'Cancelled',
          'Running',
          'Running',
          'Running',
          'Running',
          'Running'
        }
      );
      Assert.isTrue(probe(chain[5]));
    }
  }

  @IsTest
  static void sixthAncestorIsNotRead() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Root is six levels above the leaf. The read stops at five.
      List<Id> chain = insertChain(
        new List<String>{
          'Cancelled',
          'Running',
          'Running',
          'Running',
          'Running',
          'Running',
          'Running'
        }
      );
      Assert.isFalse(probe(chain[6]));
    }
  }

  @IsTest
  static void ownStatusIsNotAnAncestor() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id rootId = insertInstance('Cancelled', null);
      Assert.isNull(WorkflowCancelProbe.ancestorCancelStatus(rootId));
    }
  }

  @IsTest
  static void missingInstanceGivesFalse() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id instanceId = insertInstance('Cancelled', null);
      delete new Workflow_Instance__c(Id = instanceId);
      Assert.isFalse(probe(instanceId));
      Assert.isNull(WorkflowCancelProbe.ancestorCancelStatus(instanceId));
    }
  }

  @IsTest
  static void nullIdGivesFalseWithNoQuery() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Integer queriesBefore = Limits.getQueries();
      Assert.isFalse(probe(null));
      Assert.isNull(WorkflowCancelProbe.ancestorCancelStatus(null));
      Assert.areEqual(queriesBefore, Limits.getQueries());
    }
  }

  @IsTest
  static void oneReadIsOneQueryAndNoDml() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      List<Id> chain = insertChain(
        new List<String>{ 'Running', 'Running', 'Running' }
      );
      WorkflowCancelProbe source = new WorkflowCancelProbe(chain[2]);
      Integer queriesBefore = Limits.getQueries();
      Integer dmlBefore = Limits.getDmlStatements();

      source.isCancellationRequested();

      Assert.areEqual(1, Limits.getQueries() - queriesBefore, 'One SOQL');
      Assert.areEqual(dmlBefore, Limits.getDmlStatements(), 'No DML');
    }
  }

  @IsTest
  static void cancelStatusSet() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Assert.isTrue(WorkflowCancelProbe.isCancelStatus('Cancelled'));
      Assert.isTrue(WorkflowCancelProbe.isCancelStatus('Cancelling'));
      Assert.isFalse(WorkflowCancelProbe.isCancelStatus('Running'));
      Assert.isFalse(WorkflowCancelProbe.isCancelStatus(null));
    }
  }
}
