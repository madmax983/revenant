/**
 * @description Tests for WorkflowMetricsPublisher (issue #127): toggle,
 * window, chunks, truncation log, failure isolation and the heartbeat hook.
 * Platform events cannot be queried, so the tests read publishedEvents.
 */
@IsTest
private class WorkflowMetricsPublisherTest {
  private static Integer keySeq = 0;

  private static void seed(String workflowName, String status) {
    insert new Workflow_Instance__c(
      Workflow_Name__c = workflowName,
      Correlation_Key__c = 'MetricsPubKey_' + (keySeq++),
      Status__c = status
    );
  }

  private static void stampLastSweep(Datetime at) {
    insert new Watchdog_Liveness__c(
      SetupOwnerId = UserInfo.getOrganizationId(),
      Last_Sweep_At__c = at,
      Cadence_Minutes__c = 10
    );
  }

  private static List<Workflow_Log__c> metricLogs(String level) {
    return [
      SELECT Id, Message__c
      FROM Workflow_Log__c
      WHERE
        Log_Type__c = :WorkflowMetricsPublisher.LOG_TYPE
        AND Level__c = :level
    ];
  }

  @IsTest
  static void defaultRecordIsOff() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Revenant_Config__mdt config = [
        SELECT Publish_Metrics_Events__c
        FROM Revenant_Config__mdt
        WHERE DeveloperName = 'Default'
      ];

      Assert.isFalse(config.Publish_Metrics_Events__c, 'Default is off');
      Assert.isFalse(WorkflowEngine.publishMetricsEvents);
    }
  }

  @IsTest
  static void toggleOffCostsNothing() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      seed('Acme.A', 'Running');
      WorkflowEngine.publishMetricsEvents = false;

      Integer q0 = Limits.getQueries();
      Integer d0 = Limits.getDmlStatements();
      WorkflowMetricsPublisher.publishSnapshot(System.now());

      Assert.areEqual(0, Limits.getQueries() - q0, 'Off: 0 SOQL');
      Assert.areEqual(0, Limits.getDmlStatements() - d0, 'Off: 0 DML');
      Assert.isTrue(WorkflowMetricsPublisher.publishedEvents.isEmpty());
    }
  }

  @IsTest
  static void publishesOneSnapshotEvent() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      seed('Acme.A', 'Running');
      seed('Acme.A', 'Suspended');
      Datetime snapshotAt = System.now().addSeconds(1);
      Datetime lastSweep = snapshotAt.addMinutes(-5);
      stampLastSweep(lastSweep);
      WorkflowEngine.publishMetricsEvents = true;

      Test.startTest();
      WorkflowMetricsPublisher.publishSnapshot(snapshotAt);
      Test.stopTest();

      Assert.areEqual(1, WorkflowMetricsPublisher.publishedEvents.size());
      Workflow_Metrics__e event = WorkflowMetricsPublisher.publishedEvents[0];
      Assert.areEqual(36, event.Snapshot_Id__c.length(), 'UUID snapshot id');
      Assert.areEqual(snapshotAt, event.Snapshot_At__c);
      Assert.areEqual(lastSweep, event.Window_Start__c, 'Previous sweep');
      Assert.areEqual(1, event.Chunk_Index__c.intValue());
      Assert.areEqual(1, event.Chunk_Count__c.intValue());
      Assert.areEqual(
        WorkflowMetricsSnapshot.SCHEMA_VERSION,
        event.Schema_Version__c.intValue()
      );
      Assert.isFalse(event.Is_Truncated__c);
      WorkflowMetricsSnapshot.DefinitionMetrics row = WorkflowMetricsSnapshot.parse(
        event
      )[0];
      Assert.areEqual('Acme.A', row.workflowName);
      Assert.areEqual(1, row.running);
      Assert.areEqual(1, row.suspended);
      Assert.isNotNull(row.oldestActiveAgeSeconds);
    }
  }

  @IsTest
  static void windowFallsBackToCadence() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Datetime snapshotAt = System.now();
      WorkflowEngine.publishMetricsEvents = true;
      WorkflowEngine.watchdogDelayMinutes = 7;

      WorkflowMetricsPublisher.publishSnapshot(snapshotAt);

      Assert.areEqual(
        snapshotAt.addMinutes(-7),
        WorkflowMetricsPublisher.publishedEvents[0].Window_Start__c,
        'No stamp: window is one cadence'
      );
    }
  }

  @IsTest
  static void windowFallsBackWhenStampIsNotEarlier() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Datetime snapshotAt = System.now();
      stampLastSweep(snapshotAt);
      WorkflowEngine.publishMetricsEvents = true;
      WorkflowEngine.watchdogDelayMinutes = 10;

      WorkflowMetricsPublisher.publishSnapshot(snapshotAt);

      Assert.areEqual(
        snapshotAt.addMinutes(-10),
        WorkflowMetricsPublisher.publishedEvents[0].Window_Start__c
      );
    }
  }

  @IsTest
  static void emptyFleetSendsOneSnapshot() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.publishMetricsEvents = true;

      WorkflowMetricsPublisher.publishSnapshot(System.now());

      Assert.areEqual(1, WorkflowMetricsPublisher.publishedEvents.size());
      Assert.areEqual(
        0,
        WorkflowMetricsSnapshot.parse(
            WorkflowMetricsPublisher.publishedEvents[0]
          )
          .size()
      );
    }
  }

  @IsTest
  static void chunksShareSnapshotId() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      for (Integer i = 0; i < 6; i++) {
        seed('Acme.Wf' + i, 'Running');
      }
      WorkflowEngine.publishMetricsEvents = true;
      WorkflowMetricsPublisher.chunkCharBudget = 600;

      WorkflowMetricsPublisher.publishSnapshot(System.now());

      List<Workflow_Metrics__e> events = WorkflowMetricsPublisher.publishedEvents;
      Assert.isTrue(events.size() > 1, 'Snapshot splits into chunks');
      Set<String> names = new Set<String>();
      for (Integer i = 0; i < events.size(); i++) {
        Assert.areEqual(events[0].Snapshot_Id__c, events[i].Snapshot_Id__c);
        Assert.areEqual(i + 1, events[i].Chunk_Index__c.intValue());
        Assert.areEqual(events.size(), events[i].Chunk_Count__c.intValue());
        Assert.isFalse(events[i].Is_Truncated__c);
        for (
          WorkflowMetricsSnapshot.DefinitionMetrics row : WorkflowMetricsSnapshot.parse(
            events[i]
          )
        ) {
          names.add(row.workflowName);
        }
      }
      Assert.areEqual(6, names.size(), 'All definitions sent');
      Assert.isTrue(metricLogs('Warn').isEmpty(), 'No truncation log');
    }
  }

  @IsTest
  static void truncationSetsFlagAndLogs() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      for (Integer i = 0; i < 6; i++) {
        seed('Acme.Wf' + i, 'Running');
      }
      WorkflowEngine.publishMetricsEvents = true;
      WorkflowMetricsPublisher.chunkCharBudget = 600;
      WorkflowMetricsPublisher.maxChunks = 1;

      WorkflowMetricsPublisher.publishSnapshot(System.now());

      Assert.areEqual(1, WorkflowMetricsPublisher.publishedEvents.size());
      Assert.isTrue(
        WorkflowMetricsPublisher.publishedEvents[0].Is_Truncated__c
      );
      List<Workflow_Log__c> logs = metricLogs('Warn');
      Assert.areEqual(1, logs.size(), 'One warn log for each truncation');
      Assert.isTrue(logs[0].Message__c.contains('dropped'));
    }
  }

  @IsTest
  static void publishFailureDoesNotThrow() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.publishMetricsEvents = true;
      WorkflowMetricsPublisher.throwTestException = true;

      WorkflowMetricsPublisher.publishSnapshot(System.now());

      Assert.isTrue(WorkflowMetricsPublisher.publishedEvents.isEmpty());
      Assert.areEqual(1, metricLogs('Error').size(), 'Failure is logged');
    }
  }

  @IsTest
  static void lowDmlBudgetSkips() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.publishMetricsEvents = true;
      WorkflowMetricsPublisher.forceDmlBudgetExhausted = true;

      Integer d0 = Limits.getDmlStatements();
      WorkflowMetricsPublisher.publishSnapshot(System.now());

      Assert.isTrue(WorkflowMetricsPublisher.publishedEvents.isEmpty());
      Assert.areEqual(0, Limits.getDmlStatements() - d0, 'No DML');
    }
  }

  @IsTest
  static void nullTimeDoesNothing() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.publishMetricsEvents = true;

      WorkflowMetricsPublisher.publishSnapshot(null);

      Assert.isTrue(WorkflowMetricsPublisher.publishedEvents.isEmpty());
    }
  }

  @IsTest
  static void heartbeatPublishesWhenOn() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      WorkflowEngine.publishMetricsEvents = true;
      Datetime now = System.now();
      WorkflowEngine.mockNow = now;

      Test.startTest();
      WorkflowEngine.processWatchdogHeartbeat();
      Test.stopTest();

      Assert.areEqual(1, WorkflowMetricsPublisher.publishedEvents.size());
      Assert.areEqual(
        now,
        WorkflowMetricsPublisher.publishedEvents[0].Snapshot_At__c
      );
      Assert.areEqual(
        now,
        Watchdog_Liveness__c.getOrgDefaults().Last_Sweep_At__c,
        'The sweep stamp comes after the snapshot'
      );
    }
  }

  @IsTest
  static void heartbeatOffPublishesNothing() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      WorkflowEngine.publishMetricsEvents = false;

      Test.startTest();
      WorkflowEngine.processWatchdogHeartbeat();
      Test.stopTest();

      Assert.isTrue(WorkflowMetricsPublisher.publishedEvents.isEmpty());
    }
  }

  @IsTest
  static void heartbeatContinuesWhenPublishFails() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      WorkflowEngine.publishMetricsEvents = true;
      WorkflowMetricsPublisher.throwTestException = true;
      Datetime now = System.now();
      WorkflowEngine.mockNow = now;

      Test.startTest();
      WorkflowEngine.processWatchdogHeartbeat();
      Test.stopTest();

      Assert.isTrue(WorkflowMetricsPublisher.publishedEvents.isEmpty());
      Assert.areEqual(
        now,
        Watchdog_Liveness__c.getOrgDefaults().Last_Sweep_At__c,
        'The sweep completes after a failed publish'
      );
    }
  }

  @IsTest
  static void watchdogStepCompletesWhenPublishFails() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      WorkflowEngine.publishMetricsEvents = true;
      WorkflowMetricsPublisher.throwTestException = true;

      Test.startTest();
      StepResult result = new WatchdogWorkflow.WatchdogHeartbeatStep()
        .execute(null);
      Test.stopTest();

      Assert.areEqual(
        StepResult.ActionType.COMPLETE,
        result.directive().action,
        'Heartbeat step completes'
      );
      Assert.areEqual(
        'WatchdogWorkflow.WatchdogSleepStep',
        new WatchdogWorkflow()
          .getNextStep('WatchdogWorkflow.WatchdogHeartbeatStep', result),
        'The chain goes on to sleep, then continue-as-new'
      );
    }
  }
}
