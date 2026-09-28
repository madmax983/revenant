/**
 * @description Unit tests for WorkflowDecisionFingerprint (issue #102). All
 * tests run in memory: no SOQL, no DML.
 */
@IsTest
private class WorkflowDecisionFingerprintTest {
  private static String text(StepResult result) {
    return WorkflowDecisionFingerprint.describe(result, false);
  }

  @IsTest
  static void completeTextHasNextStepAndCompensationFlag() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Assert.areEqual(
        'COMPLETE next="Ship" compensate=false',
        text(StepResult.complete('Ship', null)),
        'Plain completion'
      );
      Assert.areEqual(
        'COMPLETE next="Ship" compensate=true',
        WorkflowDecisionFingerprint.describe(
          StepResult.complete('Ship', null),
          true
        ),
        'Compensatable completion'
      );
      Assert.areEqual(
        'COMPLETE next=null compensate=false',
        text(StepResult.complete(null, null)),
        'A null next step shows as null'
      );
    }
  }

  @IsTest
  static void differentNextStepGivesDifferentText() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Assert.areNotEqual(
        text(StepResult.complete('A', null)),
        text(StepResult.complete('B', null)),
        'The next step is routing'
      );
    }
  }

  @IsTest
  static void payloadsAndDurationsAreNotPartOfTheDecision() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Assert.areEqual(
        text(StepResult.complete('A', 1)),
        text(StepResult.complete('A', 2)),
        'Output is not routing'
      );
      Assert.areEqual(
        text(StepResult.sleep(10)),
        text(StepResult.sleep(20)),
        'Sleep time is not routing'
      );
      Assert.areEqual(
        text(StepResult.suspend(60, 'Late')),
        text(StepResult.suspend(120, 'Late')),
        'Timeout time is not routing'
      );
      Assert.areEqual(
        text(StepResult.suspend().withStepState('{"a":1}')),
        text(StepResult.suspend()),
        'Step state is not routing'
      );
    }
  }

  @IsTest
  static void timeoutRouteIsPartOfTheDecision() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Assert.areEqual(
        'SUSPEND timeout="Late"',
        text(StepResult.suspend(60, 'Late')),
        'Timed suspend'
      );
      Assert.areEqual(
        'SUSPEND timeout=null',
        text(StepResult.suspend()),
        'Plain suspend'
      );
      Assert.areEqual(
        'WAIT_FOR_APPROVAL key="K" role="Manager" timeout="Esc"',
        text(
          StepResult.waitForApproval('K', 'Manager')
            .withApprovalTimeout(60, 'Esc')
        ),
        'Timed approval'
      );
    }
  }

  @IsTest
  static void splitTargetsAreSorted() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      String ab = text(StepResult.split(new List<String>{ 'A', 'B' }));
      Assert.areEqual('SPLIT targets=["A","B"]', ab, 'Split targets');
      Assert.areEqual(
        ab,
        text(StepResult.split(new List<String>{ 'B', 'A' })),
        'Order of split targets is not routing'
      );
    }
  }

  @IsTest
  static void childTargetsAreSortedAndPayloadFree() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Assert.areEqual(
        'START_CHILD child=["Wf","k1"]',
        text(
          StepResult.startChild('Wf', 'k1', new Map<String, Object>{ 'x' => 1 })
        ),
        'One child'
      );
      String one = text(
        StepResult.startChildren(
          new List<StepResult.ChildRequest>{
            new StepResult.ChildRequest('Wf', 'k2', 1),
            new StepResult.ChildRequest('Wf', 'k1', 2)
          }
        )
      );
      String two = text(
        StepResult.startChildren(
          new List<StepResult.ChildRequest>{
            new StepResult.ChildRequest('Wf', 'k1', 3),
            new StepResult.ChildRequest('Wf', 'k2', 4)
          }
        )
      );
      Assert.areEqual(
        'START_CHILDREN children=[["Wf","k1"],["Wf","k2"]]',
        one,
        'Two children'
      );
      Assert.areEqual(one, two, 'Child order and input are not routing');
    }
  }

  @IsTest
  static void delimitersInValuesCannotMakeTwoDecisionsEqual() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      String oneChild = text(
        StepResult.startChildren(
          new List<StepResult.ChildRequest>{
            new StepResult.ChildRequest('Wf', 'a, Wf:b', null)
          }
        )
      );
      String twoChildren = text(
        StepResult.startChildren(
          new List<StepResult.ChildRequest>{
            new StepResult.ChildRequest('Wf', 'a', null),
            new StepResult.ChildRequest('Wf', 'b', null)
          }
        )
      );
      Assert.areNotEqual(oneChild, twoChildren, 'A comma in a key');
      Assert.areNotEqual(
        text(StepResult.waitForApproval('a" role="b', null)),
        text(StepResult.waitForApproval('a', 'b')),
        'A quote in a key'
      );
    }
  }

  @IsTest
  static void otherActionsUseTheActionName() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Assert.areEqual('YIELD', text(StepResult.yield('{}')), 'Yield');
      Assert.areEqual(
        'RETRY',
        text(StepResult.retry(new RetryPolicy())),
        'Retry'
      );
      Assert.areEqual(
        'FAIL',
        WorkflowDecisionFingerprint.describe(StepResult.fail('no'), true),
        'Fail'
      );
      Assert.areEqual(
        'CONTINUE_AS_NEW',
        text(StepResult.continueAsNew(null)),
        'Continue as new'
      );
      Assert.areEqual('NULL', text(null), 'A null result has a fixed text');
    }
  }

  @IsTest
  static void isWaitMatchesTheFourWaitActions() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Set<StepResult.ActionType> waits = new Set<StepResult.ActionType>{
        StepResult.ActionType.SUSPEND,
        StepResult.ActionType.WAIT_FOR_APPROVAL,
        StepResult.ActionType.START_CHILD,
        StepResult.ActionType.START_CHILDREN
      };
      for (StepResult.ActionType action : StepResult.ActionType.values()) {
        Assert.areEqual(
          waits.contains(action),
          WorkflowDecisionFingerprint.isWait(action),
          'isWait for ' + action
        );
      }
      Assert.isFalse(
        WorkflowDecisionFingerprint.isWait(null),
        'Null is not a wait'
      );
    }
  }

  @IsTest
  static void digestIsStableHex() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      String a = WorkflowDecisionFingerprint.digest('abc');
      Assert.areEqual(64, a.length(), 'SHA-256 hex length');
      Assert.isTrue(a.isAlphanumeric(), 'Hex digest');
      Assert.areEqual(
        a,
        WorkflowDecisionFingerprint.digest('abc'),
        'Equal text gives an equal digest'
      );
      Assert.areNotEqual(
        a,
        WorkflowDecisionFingerprint.digest('abd'),
        'Other text gives another digest'
      );
      Assert.areEqual(
        WorkflowDecisionFingerprint.digest(''),
        WorkflowDecisionFingerprint.digest(null),
        'Null is the same as empty'
      );
    }
  }

  @IsTest
  static void recordRoundTrips() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowDecisionFingerprint.Record rec = WorkflowDecisionFingerprint.parseRecord(
        WorkflowDecisionFingerprint.toRecordJson('in1', 'SUSPEND timeout=null')
      );
      Assert.isNotNull(rec, 'The record parses');
      Assert.areEqual('in1', rec.inputs, 'Inputs round-trip');
      Assert.areEqual(
        'SUSPEND timeout=null',
        rec.decision,
        'Decision round-trips'
      );
      Assert.areEqual(
        WorkflowDecisionFingerprint.digest('SUSPEND timeout=null'),
        rec.decisionHash,
        'The hash is the digest of the decision'
      );
    }
  }

  @IsTest
  static void recordKeepsFullHashButShortSummary() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      String longText = 'START_CHILDREN children=[' + 'x'.repeat(2000) + ']';
      WorkflowDecisionFingerprint.Record rec = WorkflowDecisionFingerprint.parseRecord(
        WorkflowDecisionFingerprint.toRecordJson('in', longText)
      );
      Assert.areEqual(
        WorkflowDecisionFingerprint.MAX_SUMMARY_LENGTH,
        rec.decision.length(),
        'The summary is short'
      );
      Assert.areEqual(
        WorkflowDecisionFingerprint.digest(longText),
        rec.decisionHash,
        'The hash covers the full text'
      );
    }
  }

  @IsTest
  static void recordFitsTheFieldInTheWorstCase() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Each control character escapes to six characters in JSON.
      String worst = String.fromCharArray(new List<Integer>{ 1 }).repeat(2000);
      String raw = WorkflowDecisionFingerprint.toRecordJson(
        WorkflowDecisionFingerprint.digest('in'),
        worst
      );
      Assert.isTrue(
        raw.length() <=
        Workflow_Step_Execution__c.Decision_Record__c.getDescribe().getLength(),
        'Record fits Decision_Record__c: ' + raw.length()
      );
    }
  }

  @IsTest
  static void parseRejectsBlankInvalidAndForeignVersion() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Assert.isNull(WorkflowDecisionFingerprint.parseRecord(null), 'Null');
      Assert.isNull(WorkflowDecisionFingerprint.parseRecord('  '), 'Blank');
      Assert.isNull(
        WorkflowDecisionFingerprint.parseRecord('not json'),
        'Not JSON'
      );
      Assert.isNull(
        WorkflowDecisionFingerprint.parseRecord('[1,2]'),
        'Not an object'
      );
      Assert.isNull(
        WorkflowDecisionFingerprint.parseRecord(
          '{"v":2,"inputs":"a","decisionHash":"b","decision":"c"}'
        ),
        'Another version is unknown'
      );
      Assert.isNull(
        WorkflowDecisionFingerprint.parseRecord('{"v":1,"decision":"c"}'),
        'A record without digests is unknown'
      );
    }
  }
}
