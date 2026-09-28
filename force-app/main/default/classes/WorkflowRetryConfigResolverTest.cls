/**
 * @description Unit tests for WorkflowRetryConfigResolver (issue #103). Each
 * test checks one row of the resolution truth table in
 * docs/retry-config.md. Tests set mockRecords, so org records have no effect.
 * A policy shows as "interval/backoff/attempts".
 */
@IsTest
private class WorkflowRetryConfigResolverTest {
  private static final String WF = 'OrderSaga';
  private static final String STEP = 'ChargeStep';

  // Record for WF. policy is [interval, backoff, attempts]; null keeps a field blank.
  private static Workflow_Retry_Config__mdt rec(
    String devName,
    String stepName,
    List<Decimal> policy
  ) {
    return new Workflow_Retry_Config__mdt(
      DeveloperName = devName,
      Workflow_Definition__c = WF,
      Step_Name__c = stepName,
      Initial_Interval_Seconds__c = policy[0],
      Backoff_Coefficient__c = policy[1],
      Maximum_Attempts__c = policy[2],
      Override_Author_Policy__c = false
    );
  }

  private static Workflow_Retry_Config__mdt overriding(
    Workflow_Retry_Config__mdt record
  ) {
    record.Override_Author_Policy__c = true;
    return record;
  }

  private static void useRecords(List<Workflow_Retry_Config__mdt> records) {
    WorkflowRetryConfigResolver.mockRecords = records;
  }

  private static String show(RetryPolicy policy) {
    return policy.initialIntervalSeconds +
      '/' +
      policy.backoffCoefficient +
      '/' +
      policy.maximumAttempts;
  }

  private static RetryPolicy author() {
    return new RetryPolicy(10, (Double) 3.0, 7);
  }

  private static User runner() {
    return new User(Id = UserInfo.getUserId());
  }

  @IsTest
  static void noRecordAndNoAuthorPolicyGivesEngineDefault() {
    System.runAs(runner()) {
      useRecords(new List<Workflow_Retry_Config__mdt>());
      Assert.areEqual(
        '5/2.0/5',
        show(WorkflowRetryConfigResolver.resolve(WF, STEP, null)),
        'No record: engine default'
      );
    }
  }

  @IsTest
  static void noRecordKeepsAuthorPolicy() {
    System.runAs(runner()) {
      useRecords(new List<Workflow_Retry_Config__mdt>());
      Assert.areEqual(
        '10/3.0/7',
        show(WorkflowRetryConfigResolver.resolve(WF, STEP, author())),
        'No record: author policy'
      );
    }
  }

  @IsTest
  static void badAuthorPolicyIsSanitized() {
    System.runAs(runner()) {
      useRecords(new List<Workflow_Retry_Config__mdt>());
      Assert.areEqual(
        '5/2.0/5',
        show(
          WorkflowRetryConfigResolver.resolve(
            WF,
            STEP,
            new RetryPolicy(0, (Double) 0.5, -1)
          )
        ),
        'Bad author values: engine default'
      );
    }
  }

  @IsTest
  static void definitionRecordAppliesWithoutAuthorPolicy() {
    System.runAs(runner()) {
      useRecords(
        new List<Workflow_Retry_Config__mdt>{
          rec('Def', null, new List<Decimal>{ 30, 1.5, 3 })
        }
      );
      Assert.areEqual(
        '30/1.5/3',
        show(WorkflowRetryConfigResolver.resolve(WF, STEP, null)),
        'Definition record applies to retry()'
      );
    }
  }

  @IsTest
  static void blankRecordFieldKeepsEngineDefault() {
    System.runAs(runner()) {
      useRecords(
        new List<Workflow_Retry_Config__mdt>{
          rec('Def', null, new List<Decimal>{ null, null, 2 })
        }
      );
      Assert.areEqual(
        '5/2.0/2',
        show(WorkflowRetryConfigResolver.resolve(WF, STEP, null)),
        'Only the attempts field changes'
      );
    }
  }

  @IsTest
  static void recordWithoutOverrideKeepsAuthorPolicy() {
    System.runAs(runner()) {
      useRecords(
        new List<Workflow_Retry_Config__mdt>{
          rec('Def', null, new List<Decimal>{ 30, 1.5, 2 }),
          rec('Step', STEP, new List<Decimal>{ 40, 1.5, 2 })
        }
      );
      Assert.areEqual(
        '10/3.0/7',
        show(WorkflowRetryConfigResolver.resolve(WF, STEP, author())),
        'No override: author policy wins'
      );
    }
  }

  @IsTest
  static void overrideRecordReplacesAuthorPolicy() {
    System.runAs(runner()) {
      useRecords(
        new List<Workflow_Retry_Config__mdt>{
          overriding(rec('Def', null, new List<Decimal>{ 60, 4.0, 2 }))
        }
      );
      Assert.areEqual(
        '60/4.0/2',
        show(WorkflowRetryConfigResolver.resolve(WF, STEP, author())),
        'Override: record wins'
      );
    }
  }

  @IsTest
  static void overrideBlankFieldKeepsAuthorValue() {
    System.runAs(runner()) {
      useRecords(
        new List<Workflow_Retry_Config__mdt>{
          overriding(rec('Def', null, new List<Decimal>{ null, null, 2 }))
        }
      );
      Assert.areEqual(
        '10/3.0/2',
        show(WorkflowRetryConfigResolver.resolve(WF, STEP, author())),
        'Override caps attempts only. Author pacing stays.'
      );
    }
  }

  @IsTest
  static void stepRecordWinsOverDefinitionRecord() {
    System.runAs(runner()) {
      useRecords(
        new List<Workflow_Retry_Config__mdt>{
          rec('Def', null, new List<Decimal>{ 30, 1.5, 4 }),
          rec('Step', STEP, new List<Decimal>{ 45, 2.5, 2 })
        }
      );
      Assert.areEqual(
        '45/2.5/2',
        show(WorkflowRetryConfigResolver.resolve(WF, STEP, null)),
        'Step record wins'
      );
    }
  }

  @IsTest
  static void stepRecordReplacesDefinitionRecordFully() {
    System.runAs(runner()) {
      useRecords(
        new List<Workflow_Retry_Config__mdt>{
          rec('Def', null, new List<Decimal>{ 30, 1.5, 4 }),
          rec('Step', STEP, new List<Decimal>{ null, null, 2 })
        }
      );
      Assert.areEqual(
        '5/2.0/2',
        show(WorkflowRetryConfigResolver.resolve(WF, STEP, null)),
        'Blank step record field uses the engine default, not the definition record'
      );
    }
  }

  @IsTest
  static void overrideFlagComesFromWinningRecordOnly() {
    System.runAs(runner()) {
      useRecords(
        new List<Workflow_Retry_Config__mdt>{
          overriding(rec('Def', null, new List<Decimal>{ 30, 1.5, 2 })),
          rec('Step', STEP, new List<Decimal>{ 45, 2.5, 3 })
        }
      );
      Assert.areEqual(
        '10/3.0/7',
        show(WorkflowRetryConfigResolver.resolve(WF, STEP, author())),
        'Step record has no override, so author policy wins'
      );
    }
  }

  @IsTest
  static void recordForOtherStepIsIgnored() {
    System.runAs(runner()) {
      useRecords(
        new List<Workflow_Retry_Config__mdt>{
          rec('Def', null, new List<Decimal>{ 30, 1.5, 4 }),
          rec('Other', 'OtherStep', new List<Decimal>{ 45, 2.5, 2 })
        }
      );
      Assert.areEqual(
        '30/1.5/4',
        show(WorkflowRetryConfigResolver.resolve(WF, STEP, null)),
        'Other step record does not match'
      );
    }
  }

  @IsTest
  static void recordForOtherWorkflowIsIgnored() {
    System.runAs(runner()) {
      useRecords(
        new List<Workflow_Retry_Config__mdt>{
          overriding(rec('Def', null, new List<Decimal>{ 30, 1.5, 2 }))
        }
      );
      Assert.areEqual(
        '5/2.0/5',
        show(WorkflowRetryConfigResolver.resolve('OtherSaga', STEP, null)),
        'Other workflow record does not match'
      );
    }
  }

  @IsTest
  static void matchIgnoresCaseAndSpaces() {
    System.runAs(runner()) {
      useRecords(
        new List<Workflow_Retry_Config__mdt>{
          rec('Step', ' CHARGESTEP ', new List<Decimal>{ 45, 2.5, 2 })
        }
      );
      Assert.areEqual(
        '45/2.5/2',
        show(WorkflowRetryConfigResolver.resolve(' ordersaga ', STEP, null)),
        'Match ignores case and outer spaces'
      );
    }
  }

  @IsTest
  static void blankStepNameMatchesDefinitionRecord() {
    System.runAs(runner()) {
      useRecords(
        new List<Workflow_Retry_Config__mdt>{
          rec('Def', '   ', new List<Decimal>{ 30, 1.5, 4 })
        }
      );
      Assert.areEqual(
        '30/1.5/4',
        show(WorkflowRetryConfigResolver.resolve(WF, null, null)),
        'Blank step name is a definition record'
      );
    }
  }

  @IsTest
  static void duplicateKeyLowestDeveloperNameWins() {
    System.runAs(runner()) {
      useRecords(
        new List<Workflow_Retry_Config__mdt>{
          rec('Zeta', STEP, new List<Decimal>{ 90, 2.0, 9 }),
          rec('Alpha', STEP, new List<Decimal>{ 20, 2.0, 2 })
        }
      );
      Assert.areEqual(
        '20/2.0/2',
        show(WorkflowRetryConfigResolver.resolve(WF, STEP, null)),
        'Lowest DeveloperName wins'
      );
    }
  }

  @IsTest
  static void badRecordValuesKeepLowerLayer() {
    System.runAs(runner()) {
      useRecords(
        new List<Workflow_Retry_Config__mdt>{
          overriding(rec('Def', null, new List<Decimal>{ 0, 0.5, -3 }))
        }
      );
      Assert.areEqual(
        '10/3.0/7',
        show(WorkflowRetryConfigResolver.resolve(WF, STEP, author())),
        'Bad record values do not replace author values'
      );
    }
  }

  @IsTest
  static void fractionalCountsRoundDown() {
    System.runAs(runner()) {
      useRecords(
        new List<Workflow_Retry_Config__mdt>{
          rec('Def', null, new List<Decimal>{ 1.9, 1.25, 2.7 })
        }
      );
      Assert.areEqual(
        '1/1.25/2',
        show(WorkflowRetryConfigResolver.resolve(WF, STEP, null)),
        'Whole-number fields round down'
      );
    }
  }

  @IsTest
  static void attemptsBelowOneAfterRoundingAreIgnored() {
    System.runAs(runner()) {
      useRecords(
        new List<Workflow_Retry_Config__mdt>{
          rec('Def', null, new List<Decimal>{ 0.9, null, 0.5 })
        }
      );
      Assert.areEqual(
        '5/2.0/5',
        show(WorkflowRetryConfigResolver.resolve(WF, STEP, null)),
        'A count below 1 is bad'
      );
    }
  }

  @IsTest
  static void blankWorkflowNameGivesEngineDefault() {
    System.runAs(runner()) {
      useRecords(
        new List<Workflow_Retry_Config__mdt>{
          overriding(rec('Def', null, new List<Decimal>{ 30, 1.5, 2 }))
        }
      );
      Assert.areEqual(
        '5/2.0/5',
        show(WorkflowRetryConfigResolver.resolve(null, STEP, null)),
        'Blank workflow: engine default'
      );
    }
  }

  @IsTest
  static void fromConfigPolicyIsNoAuthorPolicy() {
    System.runAs(runner()) {
      useRecords(
        new List<Workflow_Retry_Config__mdt>{
          rec('Def', null, new List<Decimal>{ 30, 1.5, 3 })
        }
      );
      Assert.areEqual(
        '30/1.5/3',
        show(
          WorkflowRetryConfigResolver.resolve(
            WF,
            STEP,
            RetryPolicy.fromConfig()
          )
        ),
        'fromConfig(): record applies with no override'
      );
    }
  }

  @IsTest
  static void fromConfigPolicyWithNoRecordGivesEngineDefault() {
    System.runAs(runner()) {
      useRecords(new List<Workflow_Retry_Config__mdt>());
      RetryPolicy resolved = WorkflowRetryConfigResolver.resolve(
        WF,
        STEP,
        RetryPolicy.fromConfig()
      );
      Assert.areEqual('5/2.0/5', show(resolved), 'Engine default');
      Assert.isFalse(resolved.isFromConfig(), 'Result is a plain policy');
    }
  }

  @IsTest
  static void recordWithBlankWorkflowIsSkipped() {
    System.runAs(runner()) {
      Workflow_Retry_Config__mdt blank = rec(
        'Blank',
        null,
        new List<Decimal>{ 30, 1.5, 2 }
      );
      blank.Workflow_Definition__c = '  ';
      useRecords(new List<Workflow_Retry_Config__mdt>{ blank });
      Assert.areEqual(
        '5/2.0/5',
        show(WorkflowRetryConfigResolver.resolve('  ', STEP, null)),
        'A record needs a workflow name'
      );
    }
  }

  @IsTest
  static void resolveUsesNoSoqlAndNoDml() {
    System.runAs(runner()) {
      // Real getAll() path: no mock records.
      useRecords(null);
      Integer queries = Limits.getQueries();
      Integer dml = Limits.getDmlStatements();
      for (Integer i = 0; i < 50; i++) {
        WorkflowRetryConfigResolver.resolve(WF, STEP + i, author());
        WorkflowRetryConfigResolver.resolve(WF, STEP + i, null);
        WorkflowRetryConfigResolver.overrideMaxAttempts(WF, STEP + i, 3);
      }
      Assert.areEqual(queries, Limits.getQueries(), 'Resolve uses no SOQL');
      Assert.areEqual(dml, Limits.getDmlStatements(), 'Resolve uses no DML');
    }
  }

  @IsTest
  static void overrideMaxAttemptsUsesOverrideRecordOnly() {
    System.runAs(runner()) {
      useRecords(
        new List<Workflow_Retry_Config__mdt>{
          overriding(rec('Def', null, new List<Decimal>{ null, null, 2 })),
          rec('Plain', 'PlainStep', new List<Decimal>{ null, null, 4 }),
          overriding(
            rec('Blank', 'BlankStep', new List<Decimal>{ 30, null, null })
          )
        }
      );
      Assert.areEqual(
        2,
        WorkflowRetryConfigResolver.overrideMaxAttempts(WF, STEP, 7),
        'Override record sets the cap'
      );
      Assert.areEqual(
        7,
        WorkflowRetryConfigResolver.overrideMaxAttempts(WF, 'PlainStep', 7),
        'No override: current value stays'
      );
      Assert.areEqual(
        7,
        WorkflowRetryConfigResolver.overrideMaxAttempts(WF, 'BlankStep', 7),
        'Blank attempts field: current value stays'
      );
      Assert.areEqual(
        7,
        WorkflowRetryConfigResolver.overrideMaxAttempts('OtherSaga', STEP, 7),
        'No record: current value stays'
      );
    }
  }
}
