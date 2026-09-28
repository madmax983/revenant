/**
 * @description Unit tests for WorkflowNotification and
 * StepResult.withNotification (issue #123). No DML and no SOQL.
 */
@IsTest
private class WorkflowNotificationTest {
  private static final Id USER_ID = UserInfo.getUserId();

  private static Id fakeId(String prefix, Integer n) {
    return Id.valueOf(prefix + String.valueOf(n).leftPad(12, '0'));
  }

  private static void assertThrows(Callable action, String expectedText) {
    try {
      action.call(null, null);
      Assert.fail('Expected IllegalArgumentException: ' + expectedText);
    } catch (IllegalArgumentException e) {
      Assert.isTrue(
        e.getMessage().contains(expectedText),
        'Message must contain "' + expectedText + '", got: ' + e.getMessage()
      );
    }
  }

  // Runs one builder call that must throw.
  private class BuilderCall implements Callable {
    private final String kind;
    private final Object arg;
    public BuilderCall(String kind, Object arg) {
      this.kind = kind;
      this.arg = arg;
    }
    public Object call(String action, Map<String, Object> args) {
      WorkflowNotification n = WorkflowNotification.create('T', 'B');
      switch on kind {
        when 'titleBody' {
          List<String> pair = (List<String>) arg;
          return WorkflowNotification.create(pair[0], pair[1]);
        }
        when 'recipient' {
          return n.toRecipient((Id) arg);
        }
        when 'recipients' {
          return n.toRecipients((Set<Id>) arg);
        }
        when 'inputKey' {
          return n.toInputKey((String) arg);
        }
        when 'owner' {
          return n.toRecordOwner((Id) arg);
        }
        when 'target' {
          return n.withTarget((Id) arg);
        }
        when 'type' {
          return n.withNotificationType((String) arg);
        }
        when 'result' {
          return ((StepResult) arg)
            .withNotification(
              WorkflowNotification.create('T', 'B').toRecipient(USER_ID)
            );
        }
        when 'nullNotification' {
          return ((StepResult) arg).withNotification(null);
        }
        when 'noSource' {
          return ((StepResult) arg)
            .withNotification(WorkflowNotification.create('T', 'B'));
        }
      }
      return null;
    }
  }

  @IsTest
  static void createStoresTitleBodyAndDefaults() {
    WorkflowNotification n = WorkflowNotification.create('Approve', 'Body');
    Assert.areEqual('Approve', n.title);
    Assert.areEqual('Body', n.body);
    Assert.areEqual(WorkflowNotification.DEFAULT_TYPE, n.notificationType);
    Assert.isNull(n.targetId, 'Default target is the instance (null)');
    Assert.isTrue(n.recipientIds.isEmpty());
    Assert.isTrue(n.inputKeys.isEmpty());
    Assert.isTrue(n.ownerRecordIds.isEmpty());
    Assert.isFalse(n.hasRecipientSource());
  }

  @IsTest
  static void createRejectsBadTitleAndBody() {
    assertThrows(
      new BuilderCall('titleBody', new List<String>{ ' ', 'B' }),
      'title'
    );
    assertThrows(
      new BuilderCall('titleBody', new List<String>{ 'T', null }),
      'body'
    );
    assertThrows(
      new BuilderCall(
        'titleBody',
        new List<String>{
          'x'.repeat(WorkflowNotification.MAX_TITLE_LENGTH + 1),
          'B'
        }
      ),
      'title'
    );
    assertThrows(
      new BuilderCall(
        'titleBody',
        new List<String>{
          'T',
          'x'.repeat(WorkflowNotification.MAX_BODY_LENGTH + 1)
        }
      ),
      'body'
    );
  }

  @IsTest
  static void createAcceptsMaxLengths() {
    WorkflowNotification n = WorkflowNotification.create(
      'x'.repeat(WorkflowNotification.MAX_TITLE_LENGTH),
      'y'.repeat(WorkflowNotification.MAX_BODY_LENGTH)
    );
    Assert.areEqual(WorkflowNotification.MAX_TITLE_LENGTH, n.title.length());
    Assert.areEqual(WorkflowNotification.MAX_BODY_LENGTH, n.body.length());
  }

  @IsTest
  static void recipientSourcesAreStored() {
    Id groupId = fakeId('00G', 1);
    Id accountId = fakeId('001', 1);
    WorkflowNotification n = WorkflowNotification.create('T', 'B')
      .toRecipient(USER_ID)
      .toRecipients(new Set<Id>{ groupId })
      .toInputKey('approverId')
      .toRecordOwner(accountId)
      .withTarget(accountId)
      .withNotificationType('My_Type');
    Assert.areEqual(new Set<Id>{ USER_ID, groupId }, n.recipientIds);
    Assert.areEqual(new Set<String>{ 'approverId' }, n.inputKeys);
    Assert.areEqual(new Set<Id>{ accountId }, n.ownerRecordIds);
    Assert.areEqual(accountId, n.targetId);
    Assert.areEqual('My_Type', n.notificationType);
    Assert.isTrue(n.hasRecipientSource());
  }

  @IsTest
  static void eachSourceAloneIsARecipientSource() {
    Assert.isTrue(
      WorkflowNotification.create('T', 'B')
        .toRecipient(USER_ID)
        .hasRecipientSource()
    );
    Assert.isTrue(
      WorkflowNotification.create('T', 'B').toInputKey('a').hasRecipientSource()
    );
    Assert.isTrue(
      WorkflowNotification.create('T', 'B')
        .toRecordOwner(fakeId('001', 2))
        .hasRecipientSource()
    );
  }

  @IsTest
  static void toRecipientsCopiesTheSet() {
    Set<Id> ids = new Set<Id>{ USER_ID };
    WorkflowNotification n = WorkflowNotification.create('T', 'B')
      .toRecipients(ids);
    ids.add(fakeId('00G', 3));
    Assert.areEqual(
      1,
      n.recipientIds.size(),
      'Later caller edits must not leak in'
    );
  }

  @IsTest
  static void builderRejectsBadArguments() {
    assertThrows(new BuilderCall('recipient', null), 'recipientId');
    assertThrows(new BuilderCall('recipients', null), 'ids');
    assertThrows(new BuilderCall('recipients', new Set<Id>{ null }), 'ids');
    assertThrows(new BuilderCall('inputKey', ''), 'key');
    assertThrows(new BuilderCall('owner', null), 'recordId');
    assertThrows(new BuilderCall('target', null), 'recordId');
    assertThrows(new BuilderCall('type', ' '), 'developerName');
  }

  @IsTest
  static void staticRecipientsAreCapped() {
    Set<Id> ids = new Set<Id>();
    for (Integer i = 1; i <= WorkflowNotification.MAX_STATIC_RECIPIENTS; i++) {
      ids.add(fakeId('005', i));
    }
    WorkflowNotification n = WorkflowNotification.create('T', 'B')
      .toRecipients(ids);
    Assert.areEqual(
      WorkflowNotification.MAX_STATIC_RECIPIENTS,
      n.recipientIds.size()
    );
    Set<Id> tooMany = new Set<Id>(ids);
    tooMany.add(fakeId('005', WorkflowNotification.MAX_STATIC_RECIPIENTS + 1));
    assertThrows(
      new BuilderCall('recipients', tooMany),
      String.valueOf(WorkflowNotification.MAX_STATIC_RECIPIENTS)
    );
    try {
      n.toRecipient(
        fakeId('005', WorkflowNotification.MAX_STATIC_RECIPIENTS + 1)
      );
      Assert.fail('The 501st recipient must throw');
    } catch (IllegalArgumentException e) {
      Assert.areEqual(
        WorkflowNotification.MAX_STATIC_RECIPIENTS,
        n.recipientIds.size()
      );
    }
  }

  @IsTest
  static void withNotificationStoresOnSuspendAndApproval() {
    WorkflowNotification n = WorkflowNotification.create('T', 'B')
      .toRecipient(USER_ID);
    List<StepResult> results = new List<StepResult>{
      StepResult.suspend(),
      StepResult.suspend(60, 'TimeoutStep'),
      StepResult.waitForApproval('Gate', null),
      StepResult.waitForApproval('Gate', null)
        .withApprovalTimeout(60, 'TimeoutStep')
    };
    for (StepResult r : results) {
      StepResult chained = r.withNotification(n);
      Assert.areEqual(r, chained, 'Fluent: returns the same result');
      Assert.areEqual(n, r.directive().notification);
    }
  }

  @IsTest
  static void withNotificationRejectsOtherActions() {
    List<StepResult> results = new List<StepResult>{
      StepResult.complete(null, null),
      StepResult.yield('{}'),
      StepResult.sleep(10),
      StepResult.retry(new RetryPolicy(1, (Double) 1.0, 2)),
      StepResult.startChild('W', 'k', null),
      StepResult.startChildren(
        new List<StepResult.ChildRequest>{
          new StepResult.ChildRequest('W', 'k', null)
        }
      ),
      StepResult.split(new List<String>{ 'A' }),
      StepResult.continueAsNew(null),
      StepResult.fail('no')
    };
    for (StepResult r : results) {
      assertThrows(new BuilderCall('result', r), 'SUSPEND');
      Assert.isNull(r.directive().notification);
    }
  }

  @IsTest
  static void withNotificationRejectsNullAndNoSource() {
    assertThrows(
      new BuilderCall('nullNotification', StepResult.suspend()),
      'null'
    );
    assertThrows(
      new BuilderCall('noSource', StepResult.suspend()),
      'recipient'
    );
  }

  @IsTest
  static void readAccessorsReturnCopies() {
    WorkflowNotification n = WorkflowNotification.create('T', 'B')
      .toRecipient(USER_ID)
      .toInputKey('a')
      .toRecordOwner(fakeId('001', 4));
    n.recipientIds.add(fakeId('00G', 4));
    n.recipientIds.add(null);
    n.inputKeys.add('b');
    n.ownerRecordIds.clear();
    Assert.areEqual(new Set<Id>{ USER_ID }, n.recipientIds);
    Assert.areEqual(new Set<String>{ 'a' }, n.inputKeys);
    Assert.areEqual(1, n.ownerRecordIds.size());
  }

  @IsTest
  static void secondNotificationIsRejected() {
    StepResult r = StepResult.waitForApproval('Gate', null)
      .withNotification(
        WorkflowNotification.create('T', 'B').toRecipient(USER_ID)
      );
    WorkflowNotification first = r.directive().notification;
    assertThrows(new BuilderCall('result', r), 'already has a notification');
    Assert.areEqual(first, r.directive().notification, 'The first one stays');
  }

  @IsTest
  static void noNotificationByDefault() {
    Assert.isNull(StepResult.suspend().directive().notification);
    Assert.isNull(
      StepResult.waitForApproval('Gate', null).directive().notification
    );
  }
}
