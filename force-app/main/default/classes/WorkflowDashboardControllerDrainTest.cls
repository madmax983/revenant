@IsTest
public class WorkflowDashboardControllerDrainTest {
  // ── Version Drain Tests ────────────────────────────────────────────────────

  @IsTest
  static void testGetVersionDrainPerVersionClassification() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      String wfName = 'TestVersionDrainWorkflow.Main';

      // v1: 1 non-terminal (Running) + 1 terminal (Completed)
      insert new Workflow_Instance__c(
        Workflow_Name__c = wfName,
        Status__c = 'Running',
        Correlation_Key__c = 'drain-v1-running',
        Definition_Version__c = 1
      );
      insert new Workflow_Instance__c(
        Workflow_Name__c = wfName,
        Status__c = 'Completed',
        Correlation_Key__c = 'drain-v1-done',
        Definition_Version__c = 1
      );

      // v2: all terminal (Completed)
      insert new Workflow_Instance__c(
        Workflow_Name__c = wfName,
        Status__c = 'Completed',
        Correlation_Key__c = 'drain-v2-done',
        Definition_Version__c = 2
      );

      Test.startTest();
      List<Map<String, Object>> rows = WorkflowDashboardController.getVersionDrain(
        wfName
      );
      Test.stopTest();

      System.assertEquals(2, rows.size(), 'Expected exactly 2 version rows');

      Map<String, Object> v1Row = null;
      Map<String, Object> v2Row = null;
      for (Map<String, Object> row : rows) {
        if ((Integer) row.get('version') == 1) {
          v1Row = row;
        } else if ((Integer) row.get('version') == 2) {
          v2Row = row;
        }
      }

      System.assertNotEquals(null, v1Row, 'Expected a row for version 1');
      System.assertEquals(
        1,
        (Integer) v1Row.get('nonTerminalCount'),
        'v1 nonTerminal should be 1'
      );
      System.assertEquals(
        0,
        (Integer) v1Row.get('failedCount'),
        'v1 failed should be 0'
      );
      System.assertEquals(
        1,
        (Integer) v1Row.get('terminalCount'),
        'v1 terminal should be 1'
      );
      System.assertEquals(
        false,
        (Boolean) v1Row.get('safeToRetire'),
        'v1 should NOT be safe'
      );

      System.assertNotEquals(null, v2Row, 'Expected a row for version 2');
      System.assertEquals(
        0,
        (Integer) v2Row.get('nonTerminalCount'),
        'v2 nonTerminal should be 0'
      );
      System.assertEquals(
        0,
        (Integer) v2Row.get('failedCount'),
        'v2 failed should be 0'
      );
      System.assertEquals(
        1,
        (Integer) v2Row.get('terminalCount'),
        'v2 terminal should be 1'
      );
      System.assertEquals(
        true,
        (Boolean) v2Row.get('safeToRetire'),
        'v2 SHOULD be safe'
      );
    }
  }

  @IsTest
  static void testGetVersionDrainFailedCountedSeparatelyAndBlocksRetire() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      String wfName = 'TestVersionDrainWorkflow.Failed';

      // v1: only Failed instances — terminal in lifecycle, but re-drivable on this
      // version, so it must be surfaced as failedCount and block safeToRetire.
      insert new Workflow_Instance__c(
        Workflow_Name__c = wfName,
        Status__c = 'Failed',
        Correlation_Key__c = 'drain-failed-v1-a',
        Definition_Version__c = 1
      );
      insert new Workflow_Instance__c(
        Workflow_Name__c = wfName,
        Status__c = 'Failed',
        Correlation_Key__c = 'drain-failed-v1-b',
        Definition_Version__c = 1
      );

      // v2: Failed + Completed — failed and clean-terminal must be in distinct buckets.
      insert new Workflow_Instance__c(
        Workflow_Name__c = wfName,
        Status__c = 'Failed',
        Correlation_Key__c = 'drain-failed-v2',
        Definition_Version__c = 2
      );
      insert new Workflow_Instance__c(
        Workflow_Name__c = wfName,
        Status__c = 'Completed',
        Correlation_Key__c = 'drain-done-v2',
        Definition_Version__c = 2
      );

      Test.startTest();
      List<Map<String, Object>> rows = WorkflowDashboardController.getVersionDrain(
        wfName
      );
      Test.stopTest();

      Map<String, Object> v1Row = null;
      Map<String, Object> v2Row = null;
      for (Map<String, Object> row : rows) {
        if ((Integer) row.get('version') == 1) {
          v1Row = row;
        } else if ((Integer) row.get('version') == 2) {
          v2Row = row;
        }
      }

      System.assertNotEquals(null, v1Row, 'Expected a row for version 1');
      System.assertEquals(
        0,
        (Integer) v1Row.get('nonTerminalCount'),
        'v1 nonTerminal should be 0'
      );
      System.assertEquals(
        2,
        (Integer) v1Row.get('failedCount'),
        'v1 failed should be 2'
      );
      System.assertEquals(
        0,
        (Integer) v1Row.get('terminalCount'),
        'Failed must NOT be counted as clean terminal'
      );
      System.assertEquals(
        2,
        (Integer) v1Row.get('totalCount'),
        'v1 total should be 2'
      );
      System.assertEquals(
        false,
        (Boolean) v1Row.get('safeToRetire'),
        're-drivable failures must block retire'
      );

      System.assertNotEquals(null, v2Row, 'Expected a row for version 2');
      System.assertEquals(
        1,
        (Integer) v2Row.get('failedCount'),
        'v2 failed should be 1'
      );
      System.assertEquals(
        1,
        (Integer) v2Row.get('terminalCount'),
        'v2 clean terminal should be 1'
      );
      System.assertEquals(
        false,
        (Boolean) v2Row.get('safeToRetire'),
        'v2 still has a re-drivable failure'
      );
    }
  }

  @IsTest
  static void testGetVersionDrainSafeOnlyWhenZeroNonTerminal() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      String wfName = 'TestVersionDrainWorkflow.NonTerminal';
      List<String> nonTerminalStatuses = new List<String>{
        'Pending',
        'Running',
        'Suspended',
        'Compensating',
        'Cancelling',
        'CompensationFailed'
      };

      Integer ver = 10;
      List<Workflow_Instance__c> drainInstances = new List<Workflow_Instance__c>();
      for (String s : nonTerminalStatuses) {
        drainInstances.add(
          new Workflow_Instance__c(
            Workflow_Name__c = wfName,
            Status__c = s,
            Correlation_Key__c = 'drain-nonterminal-' + s,
            Definition_Version__c = ver
          )
        );
        ver++;
      }
      insert drainInstances;

      Test.startTest();
      List<Map<String, Object>> rows = WorkflowDashboardController.getVersionDrain(
        wfName
      );
      Test.stopTest();

      System.assertEquals(
        nonTerminalStatuses.size(),
        rows.size(),
        'Expected one row per non-terminal status version'
      );
      for (Map<String, Object> row : rows) {
        System.assertEquals(
          false,
          (Boolean) row.get('safeToRetire'),
          'Version with a non-terminal instance must NOT be safe to retire: ' +
          row.get('version')
        );
        System.assertEquals(
          1,
          (Integer) row.get('nonTerminalCount'),
          'nonTerminalCount should be 1 for version: ' + row.get('version')
        );
      }
    }
  }

  @IsTest
  static void testGetVersionDrainScopedByWorkflowNameAbsenceNotSafe() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      String wfX = 'TestVersionDrainWorkflow.X';
      String wfY = 'TestVersionDrainWorkflow.Y';

      // wfX v1 is fully drained
      insert new Workflow_Instance__c(
        Workflow_Name__c = wfX,
        Status__c = 'Completed',
        Correlation_Key__c = 'drain-x-v1',
        Definition_Version__c = 1
      );

      // wfY v1 has a non-terminal — must NOT bleed into wfX results
      insert new Workflow_Instance__c(
        Workflow_Name__c = wfY,
        Status__c = 'Running',
        Correlation_Key__c = 'drain-y-v1',
        Definition_Version__c = 1
      );

      Test.startTest();
      List<Map<String, Object>> rows = WorkflowDashboardController.getVersionDrain(
        wfX
      );
      Test.stopTest();

      // Only wfX instances reported; wfY instances absent from results
      System.assertEquals(
        1,
        rows.size(),
        'Only versions observed under wfX should appear'
      );
      Map<String, Object> row = rows[0];
      System.assertEquals(1, (Integer) row.get('version'));
      System.assertEquals(
        0,
        (Integer) row.get('nonTerminalCount'),
        'wfY running instance must not contaminate wfX count'
      );
      System.assertEquals(
        true,
        (Boolean) row.get('safeToRetire'),
        'wfX v1 should be safe'
      );
    }
  }

  @IsTest
  static void testGetVersionDrainBlankWorkflowNameReturnsEmpty() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      List<Map<String, Object>> rows = WorkflowDashboardController.getVersionDrain(
        ''
      );
      Test.stopTest();
      System.assertEquals(
        0,
        rows.size(),
        'Blank workflow name should return empty list'
      );
    }
  }

  @IsTest
  static void testGetVersionDrainAuthorizationEnforced() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
      User stdUser = new User(
        Alias = 'drainusr',
        Email = 'drain.user@testorg.com',
        EmailEncodingKey = 'UTF-8',
        LastName = 'DrainTest',
        LanguageLocaleKey = 'en_US',
        LocaleSidKey = 'en_US',
        ProfileId = p.Id,
        TimeZoneSidKey = 'America/Los_Angeles',
        UserName = 'drain_user_' + DateTime.now().getTime() + '@testorg.com'
      );
      insert stdUser;

      System.runAs(stdUser) {
        try {
          WorkflowDashboardController.getVersionDrain('SomeWorkflow.Def');
          System.assert(
            false,
            'Expected AuraHandledException for unauthorized user'
          );
        } catch (AuraHandledException e) {
          System.assert(
            e.getMessage().contains('Unauthorized') ||
            e.getMessage().contains('Script-thrown exception'),
            'Exception message should indicate unauthorized access'
          );
        }
      }

    }
  }

  // ── Unrouted-signal dashboard tests ───────────────────────────────────────

  @IsTest
  static void testGetUnroutedSignalsReturnsUnroutedRows() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Signal__c sig1 = new Workflow_Signal__c(
        Correlation_Key__c = 'Unrouted-Key-1',
        Signal_Name__c = 'PingA',
        Status__c = 'Unrouted'
      );
      Workflow_Signal__c sig2 = new Workflow_Signal__c(
        Correlation_Key__c = 'Unrouted-Key-2',
        Signal_Name__c = 'PingB',
        Status__c = 'Unrouted'
      );
      insert new List<Workflow_Signal__c>{ sig1, sig2 };

      // A Received signal must NOT appear in the unrouted list.
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
        Status__c = 'Running',
        Correlation_Key__c = 'Matched-Running-Key'
      );
      insert inst;
      insert new Workflow_Signal__c(
        Correlation_Key__c = 'Matched-Running-Key',
        Workflow_Instance__c = inst.Id,
        Signal_Name__c = 'MatchedSignal',
        Status__c = 'Received'
      );

      Test.startTest();
      List<Map<String, Object>> results = WorkflowDashboardController.getUnroutedSignals(
        null,
        10,
        0,
        ''
      );
      Test.stopTest();

      System.assertEquals(
        2,
        results.size(),
        'Only Unrouted signals must be returned'
      );
      Set<String> returnedKeys = new Set<String>();
      for (Map<String, Object> row : results) {
        returnedKeys.add((String) row.get('correlationKey'));
        System.assertNotEquals(
          null,
          row.get('ageMinutes'),
          'ageMinutes must be populated'
        );
        System.assertNotEquals(null, row.get('signalName'));
      }
      System.assert(returnedKeys.contains('Unrouted-Key-1'));
      System.assert(returnedKeys.contains('Unrouted-Key-2'));
    }
  }

  @IsTest
  static void testGetUnroutedSignalCountReturnsCount() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      insert new List<Workflow_Signal__c>{
        new Workflow_Signal__c(
          Correlation_Key__c = 'Count-Key-1',
          Signal_Name__c = 'S1',
          Status__c = 'Unrouted'
        ),
        new Workflow_Signal__c(
          Correlation_Key__c = 'Count-Key-2',
          Signal_Name__c = 'S2',
          Status__c = 'Unrouted'
        )
      };

      Test.startTest();
      Map<String, Object> result = WorkflowDashboardController.getUnroutedSignalCount(
        null
      );
      Test.stopTest();

      System.assertEquals(2, (Integer) result.get('count'));
      System.assertEquals(false, (Boolean) result.get('capped'));
    }
  }

  @IsTest
  static void testRedeliverSignalMatchedReturnsTrue() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Signal__c sig = new Workflow_Signal__c(
        Correlation_Key__c = 'Dashboard-Redeliver-Key',
        Signal_Name__c = 'Wake',
        Status__c = 'Unrouted'
      );
      insert sig;

      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
        Status__c = 'Suspended',
        Correlation_Key__c = 'Dashboard-Redeliver-Key'
      );
      insert inst;

      WorkflowEngine.disableQueueableInTest = true;

      Test.startTest();
      Map<String, Object> result = WorkflowDashboardController.redeliverSignal(
        sig.Id
      );
      Test.stopTest();

      System.assertEquals(
        true,
        (Boolean) result.get('matched'),
        'Re-deliver must return matched=true when instance found'
      );

      Workflow_Signal__c reloaded = [
        SELECT Status__c
        FROM Workflow_Signal__c
        WHERE Id = :sig.Id
      ];
      System.assertEquals(
        'Received',
        reloaded.Status__c,
        'Re-delivered signal must transition to Received'
      );
    }
  }

  @IsTest
  static void testRedeliverSignalNoMatchReturnsFalse() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Signal__c sig = new Workflow_Signal__c(
        Correlation_Key__c = 'Dashboard-NoMatch-Key',
        Signal_Name__c = 'Orphan',
        Status__c = 'Unrouted'
      );
      insert sig;

      Test.startTest();
      Map<String, Object> result = WorkflowDashboardController.redeliverSignal(
        sig.Id
      );
      Test.stopTest();

      System.assertEquals(
        false,
        (Boolean) result.get('matched'),
        'Re-deliver must return matched=false when no active instance'
      );
    }
  }

  @IsTest
  static void testUnroutedSignalMethodsAuthorizationEnforced() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
      User stdUser = new User(
        Alias = 'unrtusr',
        Email = 'unrouted.user@testorg.com',
        EmailEncodingKey = 'UTF-8',
        LastName = 'UnroutedTest',
        LanguageLocaleKey = 'en_US',
        LocaleSidKey = 'en_US',
        ProfileId = p.Id,
        TimeZoneSidKey = 'America/Los_Angeles',
        UserName = 'unrouted_user_' + DateTime.now().getTime() + '@testorg.com'
      );
      insert stdUser;

      System.runAs(stdUser) {
        try {
          WorkflowDashboardController.getUnroutedSignals(null, 10, 0, '');
          System.assert(false, 'Expected AuraHandledException');
        } catch (AuraHandledException e) {
          System.assert(
            e.getMessage().contains('Unauthorized') ||
            e.getMessage().contains('Script-thrown exception')
          );
        }
        try {
          WorkflowDashboardController.getUnroutedSignalCount(null);
          System.assert(false, 'Expected AuraHandledException');
        } catch (AuraHandledException e) {
          System.assert(
            e.getMessage().contains('Unauthorized') ||
            e.getMessage().contains('Script-thrown exception')
          );
        }
        try {
          WorkflowDashboardController.redeliverSignal(null);
          System.assert(false, 'Expected AuraHandledException');
        } catch (AuraHandledException e) {
          System.assert(
            e.getMessage().contains('Unauthorized') ||
            e.getMessage().contains('Script-thrown exception')
          );
        }
      }

    }
  }

  @IsTest
  static void testGetWorkflowFailureBreakdownEmptyState() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      Map<String, Object> result = WorkflowDashboardController.getWorkflowFailureBreakdown(
        'CleanupWorkflow',
        '24h'
      );
      Test.stopTest();

      System.assertEquals('CleanupWorkflow', result.get('workflowName'));
      System.assertEquals('24h', result.get('timeWindow'));
      System.assertEquals(false, result.get('isCapped'));
      System.assertEquals(0, result.get('totalFailures'));
      List<Object> steps = (List<Object>) result.get('steps');
      System.assertEquals(0, steps.size());
    }
  }

  @IsTest
  static void testGetWorkflowFailureBreakdownFiltersAndGroups() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst1 = new Workflow_Instance__c(
        Workflow_Name__c = 'CleanupWorkflow',
        Status__c = 'Failed'
      );
      insert inst1;

      List<Workflow_Step_Execution__c> stepsToInsert = new List<Workflow_Step_Execution__c>{
        new Workflow_Step_Execution__c(
          Workflow_Instance__c = inst1.Id,
          Step_Name__c = 'StepOne',
          Status__c = 'Failed',
          Error_Details__c = 'System.NullPointerException: Attempt to de-reference a null object\nClass.MyClass.method: line 10'
        ),
        new Workflow_Step_Execution__c(
          Workflow_Instance__c = inst1.Id,
          Step_Name__c = 'StepOne',
          Status__c = 'Failed',
          Error_Details__c = 'System.NullPointerException: Attempt to de-reference a null object\nClass.MyClass.method: line 15'
        ),
        new Workflow_Step_Execution__c(
          Workflow_Instance__c = inst1.Id,
          Step_Name__c = 'StepTwo',
          Status__c = 'Failed',
          Error_Details__c = 'System.DmlException: Insert failed. First exception on row 0; first error: REQUIRED_FIELD_MISSING, Required fields are missing: [Name]: [Name]'
        )
      };
      insert stepsToInsert;

      Test.startTest();
      Map<String, Object> result = WorkflowDashboardController.getWorkflowFailureBreakdown(
        'CleanupWorkflow',
        '24h'
      );
      Test.stopTest();

      System.assertEquals('CleanupWorkflow', result.get('workflowName'));
      System.assertEquals('24h', result.get('timeWindow'));
      System.assertEquals(3, result.get('totalFailures'));

      List<Object> steps = (List<Object>) result.get('steps');
      System.assertEquals(
        2,
        steps.size(),
        'Should have 2 failing steps grouped'
      );

      Map<String, Object> step1 = (Map<String, Object>) steps[0];
      System.assertEquals('StepOne', step1.get('stepName'));
      System.assertEquals(2, step1.get('failureCount'));

      List<Object> signatures1 = (List<Object>) step1.get('errorSignatures');
      System.assertEquals(
        1,
        signatures1.size(),
        'Should group both NPEs together'
      );
      Map<String, Object> sig1 = (Map<String, Object>) signatures1[0];
      System.assertEquals(
        'System.NullPointerException: Attempt to de-reference a null object',
        sig1.get('signature')
      );
      System.assertEquals(2, sig1.get('count'));

      List<Object> examples1 = (List<Object>) sig1.get('examples');
      System.assertEquals(
        1,
        examples1.size(),
        'Should unique examples by instance'
      );

      Map<String, Object> step2 = (Map<String, Object>) steps[1];
      System.assertEquals('StepTwo', step2.get('stepName'));
      System.assertEquals(1, step2.get('failureCount'));
    }
  }

  @IsTest
  static void testGetWorkflowFailureBreakdownNormalization() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst1 = new Workflow_Instance__c(
        Workflow_Name__c = 'CleanupWorkflow',
        Status__c = 'Failed'
      );
      insert inst1;

      List<Workflow_Step_Execution__c> stepsToInsert = new List<Workflow_Step_Execution__c>{
        new Workflow_Step_Execution__c(
          Workflow_Instance__c = inst1.Id,
          Step_Name__c = 'NormalizeStep',
          Status__c = 'Failed',
          Error_Details__c = 'Failed to update Account 001DSv00000CFwWKMA at 2026-06-22T20:16:30Z with transaction 3d3b7e41-0f46-4c4f-9e7b-c9e504c5fb43. Retries: 3'
        )
      };
      insert stepsToInsert;

      Test.startTest();
      Map<String, Object> result = WorkflowDashboardController.getWorkflowFailureBreakdown(
        'CleanupWorkflow',
        'all'
      );
      Test.stopTest();

      List<Object> steps = (List<Object>) result.get('steps');
      Map<String, Object> step = (Map<String, Object>) steps[0];
      List<Object> signatures = (List<Object>) step.get('errorSignatures');
      Map<String, Object> sig = (Map<String, Object>) signatures[0];

      String signature = (String) sig.get('signature');
      System.assert(
        signature.contains('[ID]'),
        'Should contain [ID]: ' + signature
      );
      System.assert(
        signature.contains('[DATETIME]'),
        'Should contain [DATETIME]: ' + signature
      );
      System.assert(
        signature.contains('[UUID]'),
        'Should contain [UUID]: ' + signature
      );
      System.assert(
        signature.contains('[NUM]'),
        'Should contain [NUM]: ' + signature
      );
    }
  }
}
