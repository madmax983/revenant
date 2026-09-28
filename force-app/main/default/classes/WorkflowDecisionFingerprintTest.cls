/**
 * @description Unit tests for WorkflowDecisionFingerprint (issue #102). All
 * tests run in memory: no SOQL, no DML.
 */
@IsTest
private class WorkflowDecisionFingerprintTest {
  @IsTest
  static void completeTextHasNextStepAndCompensationFlag() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      String plain = WorkflowDecisionFingerprint.describe(
        StepResult.complete('Ship', null),
        false
      );
      String comp = WorkflowDecisionFingerprint.describe(
        StepResult.complete('Ship', null),
        true
      );
      Assert.areEqual('COMPLETE next=Ship compensate=false', plain);
      Assert.areEqual('COMPLETE next=Ship compensate=true', comp);
      Assert.areEqual(
        'COMPLETE next=- compensate=false',
        WorkflowDecisionFingerprint.describe(
          StepResult.complete(null, null),
          false
        ),
        'A null next step shows as a dash'
      );
    }
  }

  @IsTest
  static void differentNextStepGivesDifferentText() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Assert.areNotEqual(
        WorkflowDecisionFingerprint.describe(
          StepResult.complete('A', null),
          false
        ),
        WorkflowDecisionFingerprint.describe(
          StepResult.complete('B', null),
          false
        )
      );
    }
  }

  @IsTest
  static void payloadsAndDurationsAreNotPartOfTheDecision() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Assert.areEqual(
        WorkflowDecisionFingerprint.describe(
          StepResult.complete('A', 1),
          false
        ),
        WorkflowDecisionFingerprint.describe(
          StepResult.complete('A', 2),
          false
        ),
        'Output is not routing'
      );
      Assert.areEqual(
        WorkflowDecisionFingerprint.describe(StepResult.sleep(10), false),
        WorkflowDecisionFingerprint.describe(StepResult.sleep(20), false),
        'Sleep time is not routing'
      );
      Assert.areEqual(
        WorkflowDecisionFingerprint.describe(
          StepResult.suspend(60, 'Late'),
          false
        ),
        WorkflowDecisionFingerprint.describe(
          StepResult.suspend(120, 'Late'),
          false
        ),
        'Timeout time is not routing'
      );
      Assert.areEqual(
        WorkflowDecisionFingerprint.describe(
          StepResult.suspend().withStepState('{"a":1}'),
          false
        ),
        WorkflowDecisionFingerprint.describe(StepResult.suspend(), false),
        'Step state is not routing'
      );
    }
  }

  @IsTest
  static void timeoutRouteIsPartOfTheDecision() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Assert.areEqual(
        'SUSPEND timeout=Late',
        WorkflowDecisionFingerprint.describe(
          StepResult.suspend(60, 'Late'),
          false
        )
      );
      Assert.areEqual(
        'SUSPEND timeout=-',
        WorkflowDecisionFingerprint.describe(StepResult.suspend(), false)
      );
      Assert.areEqual(
        'WAIT_FOR_APPROVAL key=K role=Manager timeout=Esc',
        WorkflowDecisionFingerprint.describe(
          StepResult.waitForApproval('K', 'Manager')
            .withApprovalTimeout(60, 'Esc'),
          false
        )
      );
    }
  }

  @IsTest
  static void splitTargetsAreSorted() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      String ab = WorkflowDecisionFingerprint.describe(
        StepResult.split(new List<String>{ 'A', 'B' }),
        false
      );
      String ba = WorkflowDecisionFingerprint.describe(
        StepResult.split(new List<String>{ 'B', 'A' }),
        false
      );
      Assert.areEqual('SPLIT targets=[A, B]', ab);
      Assert.areEqual(ab, ba, 'Order of split targets is not routing');
    }
  }

  @IsTest
  static void childTargetsAreSortedAndPayloadFree() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Assert.areEqual(
        'START_CHILD child=Wf:k1',
        WorkflowDecisionFingerprint.describe(
          StepResult.startChild(
            'Wf',
            'k1',
            new Map<String, Object>{ 'x' => 1 }
          ),
          false
        )
      );
      String one = WorkflowDecisionFingerprint.describe(
        StepResult.startChildren(
          new List<StepResult.ChildRequest>{
            new StepResult.ChildRequest('Wf', 'k2', 1),
            new StepResult.ChildRequest('Wf', 'k1', 2)
          }
        ),
        false
      );
      String two = WorkflowDecisionFingerprint.describe(
        StepResult.startChildren(
          new List<StepResult.ChildRequest>{
            new StepResult.ChildRequest('Wf', 'k1', 3),
            new StepResult.ChildRequest('Wf', 'k2', 4)
          }
        ),
        false
      );
      Assert.areEqual('START_CHILDREN children=[Wf:k1, Wf:k2]', one);
      Assert.areEqual(one, two, 'Child order and input are not routing');
    }
  }

  @IsTest
  static void otherActionsUseTheActionName() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Assert.areEqual(
        'YIELD',
        WorkflowDecisionFingerprint.describe(StepResult.yield('{}'), false)
      );
      Assert.areEqual(
        'RETRY',
        WorkflowDecisionFingerprint.describe(
          StepResult.retry(new RetryPolicy()),
          false
        )
      );
      Assert.areEqual(
        'FAIL',
        WorkflowDecisionFingerprint.describe(StepResult.fail('no'), true)
      );
      Assert.areEqual(
        'CONTINUE_AS_NEW',
        WorkflowDecisionFingerprint.describe(
          StepResult.continueAsNew(null),
          false
        )
      );
      Assert.areEqual(
        'NULL',
        WorkflowDecisionFingerprint.describe(null, false),
        'A null result has a fixed text'
      );
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
      Assert.isFalse(WorkflowDecisionFingerprint.isWait(null));
    }
  }

  @IsTest
  static void digestIsStableHex() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      String a = WorkflowDecisionFingerprint.digest('abc');
      Assert.areEqual(64, a.length());
      Assert.isTrue(a.isAlphanumeric(), 'Hex digest');
      Assert.areEqual(a, WorkflowDecisionFingerprint.digest('abc'));
      Assert.areNotEqual(a, WorkflowDecisionFingerprint.digest('abd'));
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
      String raw = WorkflowDecisionFingerprint.toRecordJson(
        'in1',
        'SUSPEND timeout=-'
      );
      WorkflowDecisionFingerprint.Record rec = WorkflowDecisionFingerprint.parseRecord(
        raw
      );
      Assert.isNotNull(rec);
      Assert.areEqual('in1', rec.inputs);
      Assert.areEqual('SUSPEND timeout=-', rec.decision);
      Assert.areEqual(
        WorkflowDecisionFingerprint.digest('SUSPEND timeout=-'),
        rec.decisionHash
      );
    }
  }

  @IsTest
  static void recordKeepsFullHashButShortSummary() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      String longText = 'START_CHILDREN children=[' + 'x'.repeat(2000) + ']';
      String raw = WorkflowDecisionFingerprint.toRecordJson('in', longText);
      Assert.isTrue(raw.length() <= 1000, 'Record fits Decision_Record__c');
      WorkflowDecisionFingerprint.Record rec = WorkflowDecisionFingerprint.parseRecord(
        raw
      );
      Assert.areEqual(
        WorkflowDecisionFingerprint.MAX_SUMMARY_LENGTH,
        rec.decision.length()
      );
      Assert.areEqual(
        WorkflowDecisionFingerprint.digest(longText),
        rec.decisionHash,
        'The hash covers the full text'
      );
    }
  }

  @IsTest
  static void parseRejectsBlankInvalidAndForeignVersion() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Assert.isNull(WorkflowDecisionFingerprint.parseRecord(null));
      Assert.isNull(WorkflowDecisionFingerprint.parseRecord('  '));
      Assert.isNull(WorkflowDecisionFingerprint.parseRecord('not json'));
      Assert.isNull(WorkflowDecisionFingerprint.parseRecord('[1,2]'));
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
