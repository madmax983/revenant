# Auto-Reclaim Orphaned Instances Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Implement automatic detection and re-driving of stranded workflow instances whose referenced async jobs have died under platform pressure, ensuring they self-heal within one watchdog cycle without operator intervention.

**Architecture:** Extend the `WorkflowWatchdog` heartbeat sweep in `WorkflowEngine.processWatchdogHeartbeat()` to identify candidate active, non-terminal instances that have been idle past a configurable threshold, verify if their referenced `CronTrigger` or `AsyncApexJob` is still active, reset stuck/pending step execution logs, write an operator-visible audit log, and re-enqueue them via a fresh orchestrator.

**Tech Stack:** Salesforce Apex, Custom Metadata (`Revenant_Config__mdt`), Platform Events (`Workflow_Event__e`).

---

### Task 1: Create Custom Metadata Field for Reclaim Threshold

**Files:**
- Create: `force-app/main/default/objects/Revenant_Config__mdt/fields/Reclaim_Threshold_Minutes__c.field-meta.xml`

**Step 1: Write Custom Field Metadata**
Write the following definition to the new metadata file:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
    <fullName>Reclaim_Threshold_Minutes__c</fullName>
    <description>Minutes of inactivity after which an active self-driving instance (Pending/Running/Compensating/Cancelling) whose async job is dead is automatically reclaimed by the watchdog. Leave blank or set to 0 to disable automatic reclaim.</description>
    <externalId>false</externalId>
    <fieldManageability>DeveloperControlled</fieldManageability>
    <label>Reclaim Threshold Minutes</label>
    <precision>9</precision>
    <required>false</required>
    <scale>0</scale>
    <type>Number</type>
</CustomField>
```

**Step 2: Commit**
```bash
git add force-app/main/default/objects/Revenant_Config__mdt/fields/Reclaim_Threshold_Minutes__c.field-meta.xml
git commit -m "feat: add Reclaim_Threshold_Minutes__c metadata field"
```

---

### Task 2: Update WorkflowEngine Configuration Loading

**Files:**
- Modify: `force-app/main/default/classes/WorkflowEngine.cls` (Add `reclaimThresholdMinutes` static variable and load it in the static block)

**Step 1: Declare static variable**
Add the following line to `WorkflowEngine.cls`:
```apex
  // Minutes of inactivity after which a self-driving instance whose async job is dead
  // is automatically reclaimed. Configurable via Revenant_Config__mdt.Reclaim_Threshold_Minutes__c.
  // Disabled by default (null or <= 0).
  public static Integer reclaimThresholdMinutes = null;
```

**Step 2: Query and Load value in static block**
Update the query in the static constructor block of `WorkflowEngine.cls` to select `Reclaim_Threshold_Minutes__c`, and load its value:
```apex
      List<Revenant_Config__mdt> configs = [
        SELECT
          Watchdog_Delay_Minutes__c,
          Use_Dynamic_Scheduling__c,
          Publish_Lifecycle_Events__c,
          Dedup_Window_Minutes__c,
          Stale_Threshold_Minutes__c,
          Reclaim_Threshold_Minutes__c
        FROM Revenant_Config__mdt
        WHERE DeveloperName = 'Default'
        WITH SYSTEM_MODE
        LIMIT 1
      ];
      if (!configs.isEmpty()) {
        // ... other properties
        if (configs[0].Reclaim_Threshold_Minutes__c != null) {
          reclaimThresholdMinutes = configs[0].Reclaim_Threshold_Minutes__c.intValue();
        }
      }
```

**Step 3: Commit**
```bash
git add force-app/main/default/classes/WorkflowEngine.cls
git commit -m "feat: query and load Reclaim_Threshold_Minutes__c in WorkflowEngine"
```

---

### Task 3: Implement Reclaim Sweep and Re-Drive Execution

**Files:**
- Modify: `force-app/main/default/classes/WorkflowEngine.cls` (Add `reclaimOrphanedInstances` method and wire it inside `processWatchdogHeartbeat`)

**Step 1: Wire the sweep inside `processWatchdogHeartbeat`**
Insert the reclaim sweep logic right after the transient-lock sweep in `processWatchdogHeartbeat`:
```apex
    // 6. Auto-reclaim orphaned instances. Sweeps for instances stuck in a self-driving status
    // (Pending/Running/Compensating/Cancelling) whose referenced async job is no longer alive,
    // and re-enqueues them at their last durable step.
    try {
      if (reclaimThresholdMinutes != null && reclaimThresholdMinutes > 0 && !WorkflowPauseGate.wildcardPaused()) {
        Set<String> pausedDefNames = WorkflowPauseGate.pausedNames();
        List<Workflow_Instance__c> candidates = [
          SELECT Id, Name, Status__c, Current_Step__c, Compensation_Stack__c, Async_Job_Id__c, Workflow_Name__c, Correlation_Key__c
          FROM Workflow_Instance__c
          WHERE Status__c IN ('Pending', 'Running', 'Compensating', 'Cancelling')
            AND LastModifiedDate <= :now.addMinutes(-reclaimThresholdMinutes)
            AND Workflow_Name__c NOT IN :pausedDefNames
          WITH SYSTEM_MODE
          ORDER BY LastModifiedDate ASC, Id ASC
          LIMIT 50
        ];

        if (!candidates.isEmpty()) {
          Set<Id> jobIds = new Set<Id>();
          for (Workflow_Instance__c inst : candidates) {
            if (String.isNotBlank(inst.Async_Job_Id__c)) {
              String jobIdStr = inst.Async_Job_Id__c;
              if ((jobIdStr.length() == 15 || jobIdStr.length() == 18) &&
                  (jobIdStr.startsWith('08e') || jobIdStr.startsWith('707'))) {
                try {
                  jobIds.add((Id) jobIdStr);
                } catch (Exception e) {}
              }
            }
          }

          Set<Id> activeCronIds = new Set<Id>();
          Set<Id> activeAsyncIds = new Set<Id>();
          
          Set<Id> cronIds = new Set<Id>();
          Set<Id> asyncIds = new Set<Id>();
          for (Id jobId : jobIds) {
            if (jobId.getSobjectType() == CronTrigger.SObjectType) {
              cronIds.add(jobId);
            } else if (jobId.getSobjectType() == AsyncApexJob.SObjectType) {
              asyncIds.add(jobId);
            }
          }

          if (!cronIds.isEmpty()) {
            for (CronTrigger ct : [
              SELECT Id FROM CronTrigger
              WHERE Id IN :cronIds AND State IN ('WAITING', 'ACQUIRED', 'QUEUED', 'EXECUTING')
              WITH SYSTEM_MODE
            ]) {
              activeCronIds.add(ct.Id);
            }
          }

          if (!asyncIds.isEmpty()) {
            for (AsyncApexJob aaj : [
              SELECT Id FROM AsyncApexJob
              WHERE Id IN :asyncIds AND Status IN ('Queued', 'Holding', 'Preparing', 'Processing')
              WITH SYSTEM_MODE
            ]) {
              activeAsyncIds.add(aaj.Id);
            }
          }

          List<Workflow_Instance__c> orphanedInstances = new List<Workflow_Instance__c>();
          for (Workflow_Instance__c inst : candidates) {
            Boolean isOrphaned = false;
            if (String.isBlank(inst.Async_Job_Id__c)) {
              isOrphaned = true;
            } else {
              String jobIdStr = inst.Async_Job_Id__c;
              if ((jobIdStr.length() == 15 || jobIdStr.length() == 18) &&
                  (jobIdStr.startsWith('08e') || jobIdStr.startsWith('707'))) {
                try {
                  Id jobId = (Id) jobIdStr;
                  Boolean jobIsAlive = false;
                  if (jobId.getSobjectType() == CronTrigger.SObjectType && activeCronIds.contains(jobId)) {
                    jobIsAlive = true;
                  } else if (jobId.getSobjectType() == AsyncApexJob.SObjectType && activeAsyncIds.contains(jobId)) {
                    jobIsAlive = true;
                  }
                  if (!jobIsAlive) {
                    isOrphaned = true;
                  }
                } catch (Exception ex) {
                  isOrphaned = true;
                }
              } else {
                isOrphaned = true;
              }
            }

            if (isOrphaned) {
              orphanedInstances.add(inst);
            }
          }

          if (!orphanedInstances.isEmpty()) {
            reclaimOrphanedInstances(orphanedInstances);
          }
        }
      }
    } catch (Exception reclaimEx) {
      System.debug(
        LoggingLevel.ERROR,
        'WorkflowEngine: auto-reclaim sweep failed: ' + reclaimEx.getMessage()
      );
    }
```

**Step 2: Add `reclaimOrphanedInstances` method**
Add the helper method `reclaimOrphanedInstances` to `WorkflowEngine.cls`:
```apex
  private static void reclaimOrphanedInstances(List<Workflow_Instance__c> orphanedInstances) {
    Set<Id> instanceIds = new Set<Id>();
    Set<String> allTargetStepNames = new Set<String>();
    Map<Id, List<String>> targetStepsByInstanceId = new Map<Id, List<String>>();

    for (Workflow_Instance__c inst : orphanedInstances) {
      instanceIds.add(inst.Id);
      Boolean hasCompensations = false;
      List<String> stack = new List<String>();
      if (String.isNotBlank(inst.Compensation_Stack__c)) {
        try {
          stack = (List<String>) JSON.deserialize(
            inst.Compensation_Stack__c,
            List<String>.class
          );
          hasCompensations = !stack.isEmpty();
        } catch (Exception ex) {}
      }

      List<String> targetStepNames = new List<String>();
      if (hasCompensations) {
        targetStepNames.add(stack[stack.size() - 1] + '_Compensate');
      } else if (String.isNotBlank(inst.Current_Step__c)) {
        if (inst.Current_Step__c.contains(',')) {
          for (String pStep : inst.Current_Step__c.split(',')) {
            targetStepNames.add(pStep.trim());
          }
        } else {
          targetStepNames.add(inst.Current_Step__c);
        }
      }

      if (String.isBlank(inst.Current_Step__c) && !hasCompensations) {
        Type wflowType = Type.forName(inst.Workflow_Name__c);
        if (wflowType != null) {
          try {
            Object defObj = wflowType.newInstance();
            if (defObj instanceof WorkflowDefinition) {
              inst.Current_Step__c = ((WorkflowDefinition) defObj).getInitialStep();
              targetStepNames.add(inst.Current_Step__c);
            }
          } catch (Exception ex) {}
        }
      }

      targetStepsByInstanceId.put(inst.Id, targetStepNames);
      allTargetStepNames.addAll(targetStepNames);
    }

    // Query step executions to reset
    Map<String, Workflow_Step_Execution__c> latestStepByName = new Map<String, Workflow_Step_Execution__c>();
    if (!allTargetStepNames.isEmpty()) {
      for (Workflow_Step_Execution__c se : [
        SELECT Id, Workflow_Instance__c, Step_Name__c, Status__c, Retry_Count__c, Error_Details__c
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c IN :instanceIds
          AND Step_Name__c IN :allTargetStepNames
        WITH SYSTEM_MODE
        ORDER BY CreatedDate DESC, Id DESC
      ]) {
        String key = se.Workflow_Instance__c + ':' + se.Step_Name__c;
        if (!latestStepByName.containsKey(key)) {
          latestStepByName.put(key, se);
        }
      }
    }

    List<Workflow_Step_Execution__c> stepsToReset = new List<Workflow_Step_Execution__c>();
    for (Workflow_Instance__c inst : orphanedInstances) {
      List<String> targetStepNames = targetStepsByInstanceId.get(inst.Id);
      for (String targetStepName : targetStepNames) {
        String key = inst.Id + ':' + targetStepName;
        Workflow_Step_Execution__c stepExec = latestStepByName.get(key);
        if (
          stepExec != null &&
          stepExec.Status__c != 'Completed' &&
          stepExec.Status__c != 'OperatorSkipped'
        ) {
          stepExec.Status__c = 'Pending';
          stepExec.Retry_Count__c = 0;
          stepExec.Error_Details__c = null;
          stepsToReset.add(stepExec);
        }
      }
    }

    if (!stepsToReset.isEmpty()) {
      update as system stepsToReset;
    }

    // Write audit logs
    List<Workflow_Log__c> auditLogs = new List<Workflow_Log__c>();
    for (Workflow_Instance__c inst : orphanedInstances) {
      String stepDetail = String.isNotBlank(inst.Current_Step__c) ? inst.Current_Step__c : '(initial step)';
      auditLogs.add(new Workflow_Log__c(
        Workflow_Instance__c = inst.Id,
        Workflow_Name__c = inst.Workflow_Name__c,
        Correlation_Key__c = inst.Correlation_Key__c,
        Log_Type__c = 'OperatorIntervention',
        Message__c = 'Auto-reclaimed orphaned instance from step: ' + stepDetail,
        Outcome__c = 'Success',
        Level__c = 'INFO',
        Fire_Time__c = DateTime.now()
      ));
      inst.Async_Job_Id__c = null;
    }
    update as system orphanedInstances;
    insert as system auditLogs;

    // Enqueue fresh orchestrators
    List<Id> singleHopInstanceIds = new List<Id>();
    for (Workflow_Instance__c inst : orphanedInstances) {
      List<String> targetStepNames = targetStepsByInstanceId.get(inst.Id);
      Boolean hasCompensations = false;
      if (String.isNotBlank(inst.Compensation_Stack__c)) {
        try {
          List<String> stack = (List<String>) JSON.deserialize(
            inst.Compensation_Stack__c,
            List<String>.class
          );
          hasCompensations = !stack.isEmpty();
        } catch (Exception ex) {}
      }

      if (
        hasCompensations ||
        String.isBlank(inst.Current_Step__c) ||
        !inst.Current_Step__c.contains(',')
      ) {
        singleHopInstanceIds.add(inst.Id);
      } else {
        for (String targetStepName : targetStepNames) {
          String key = inst.Id + ':' + targetStepName;
          Workflow_Step_Execution__c stepExec = latestStepByName.get(key);
          if (
            stepExec == null ||
            (stepExec.Status__c != 'Completed' &&
            stepExec.Status__c != 'OperatorSkipped')
          ) {
            if (!(Test.isRunningTest() && disableQueueableInTest)) {
              enqueueOrchestrator(inst.Id, targetStepName);
            }
          }
        }
      }
    }

    if (!singleHopInstanceIds.isEmpty()) {
      if (!(Test.isRunningTest() && disableQueueableInTest)) {
        enqueueOrchestrators(singleHopInstanceIds);
      }
    }
  }
```

**Step 3: Commit**
```bash
git add force-app/main/default/classes/WorkflowEngine.cls
git commit -m "feat: implement auto-reclaim sweep and re-driving in processWatchdogHeartbeat"
```

---

### Task 4: Add Apex Unit Tests

**Files:**
- Modify: `force-app/main/default/classes/WorkflowWatchdogTest.cls` (Add test cases proving the reclaim scenarios)

**Step 1: Implement test methods**
Add the following test methods to `WorkflowWatchdogTest.cls`:
```apex
  @isTest
  static void testWatchdogAutoReclaimOrphanedInstance() {
    WorkflowWatchdog.forceBootstrapInTest = true;
    WorkflowEngine.disableQueueableInTest = true;
    WorkflowEngine.reclaimThresholdMinutes = 10;

    // Create candidate instance stuck in Running with a dead job ID
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
      Status__c = 'Running',
      Async_Job_Id__c = '707Sv00001rOraj' // Dead/mock job ID
    );
    insert inst;

    // Set LastModifiedDate to past threshold by updating via test
    Test.setCreatedDate(inst.Id, DateTime.now().addMinutes(-15));

    // Insert a running step execution log that got orphaned
    Workflow_Step_Execution__c stepExec = new Workflow_Step_Execution__c(
      Workflow_Instance__c = inst.Id,
      Step_Name__c = 'WorkflowEngineTest.HappyStep1',
      Status__c = 'Running',
      Retry_Count__c = 2,
      Error_Details__c = 'Stuck error'
    );
    insert stepExec;

    Test.startTest();
    // Run watchdog heartbeat to trigger reclaim
    WorkflowEngine.processWatchdogHeartbeat();
    Test.stopTest();

    // Verify step execution was reset to Pending
    Workflow_Step_Execution__c updatedStep = [
      SELECT Status__c, Retry_Count__c, Error_Details__c
      FROM Workflow_Step_Execution__c
      WHERE Id = :stepExec.Id
    ];
    System.assertEquals('Pending', updatedStep.Status__c);
    System.assertEquals(0, updatedStep.Retry_Count__c);
    System.assertNull(updatedStep.Error_Details__c);

    // Verify instance remains Running and Async_Job_Id__c was cleared
    Workflow_Instance__c updatedInst = [
      SELECT Status__c, Async_Job_Id__c
      FROM Workflow_Instance__c
      WHERE Id = :inst.Id
    ];
    System.assertEquals('Running', updatedInst.Status__c);
    System.assertNull(updatedInst.Async_Job_Id__c);

    // Verify audit log of type OperatorIntervention was written
    List<Workflow_Log__c> logs = [
      SELECT Message__c, Log_Type__c
      FROM Workflow_Log__c
      WHERE Workflow_Instance__c = :inst.Id AND Log_Type__c = 'OperatorIntervention'
    ];
    System.assertEquals(1, logs.size());
    System.assert(logs[0].Message__c.contains('Auto-reclaimed orphaned instance'));
  }

  @isTest
  static void testWatchdogAutoReclaimBypassesHealthyInstance() {
    WorkflowWatchdog.forceBootstrapInTest = true;
    WorkflowEngine.disableQueueableInTest = true;
    WorkflowEngine.reclaimThresholdMinutes = 10;

    // Healthy in-flight Running instance (recently modified)
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
      Status__c = 'Running'
    );
    insert inst;

    // Running step execution log
    Workflow_Step_Execution__c stepExec = new Workflow_Step_Execution__c(
      Workflow_Instance__c = inst.Id,
      Step_Name__c = 'WorkflowEngineTest.HappyStep1',
      Status__c = 'Running'
    );
    insert stepExec;

    Test.startTest();
    WorkflowEngine.processWatchdogHeartbeat();
    Test.stopTest();

    // Verify step was NOT reset
    Workflow_Step_Execution__c updatedStep = [
      SELECT Status__c
      FROM Workflow_Step_Execution__c
      WHERE Id = :stepExec.Id
    ];
    System.assertEquals('Running', updatedStep.Status__c);
  }

  @isTest
  static void testWatchdogAutoReclaimBypassesSuspendedInstance() {
    WorkflowWatchdog.forceBootstrapInTest = true;
    WorkflowEngine.disableQueueableInTest = true;
    WorkflowEngine.reclaimThresholdMinutes = 10;

    // Suspended instance waiting on signal/approval/timer
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
      Status__c = 'Suspended'
    );
    insert inst;
    Test.setCreatedDate(inst.Id, DateTime.now().addMinutes(-15));

    // Pending step execution log waiting on signal
    Workflow_Step_Execution__c stepExec = new Workflow_Step_Execution__c(
      Workflow_Instance__c = inst.Id,
      Step_Name__c = 'WorkflowEngineTest.HappyStep1',
      Status__c = 'Pending'
    );
    insert stepExec;

    Test.startTest();
    WorkflowEngine.processWatchdogHeartbeat();
    Test.stopTest();

    // Verify step was NOT reset
    Workflow_Step_Execution__c updatedStep = [
      SELECT Status__c
      FROM Workflow_Step_Execution__c
      WHERE Id = :stepExec.Id
    ];
    System.assertEquals('Pending', updatedStep.Status__c);
  }

  @isTest
  static void testWatchdogAutoReclaimBypassesCompletedStep() {
    WorkflowWatchdog.forceBootstrapInTest = true;
    WorkflowEngine.disableQueueableInTest = true;
    WorkflowEngine.reclaimThresholdMinutes = 10;

    // Candidate instance stuck in Running
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
      Status__c = 'Running'
    );
    insert inst;
    Test.setCreatedDate(inst.Id, DateTime.now().addMinutes(-15));

    // Completed step execution log
    Workflow_Step_Execution__c stepExec = new Workflow_Step_Execution__c(
      Workflow_Instance__c = inst.Id,
      Step_Name__c = 'WorkflowEngineTest.HappyStep1',
      Status__c = 'Completed'
    );
    insert stepExec;

    Test.startTest();
    WorkflowEngine.processWatchdogHeartbeat();
    Test.stopTest();

    // Verify completed step is untouched
    Workflow_Step_Execution__c updatedStep = [
      SELECT Status__c
      FROM Workflow_Step_Execution__c
      WHERE Id = :stepExec.Id
    ];
    System.assertEquals('Completed', updatedStep.Status__c);
  }
```

**Step 2: Commit**
```bash
git add force-app/main/default/classes/WorkflowWatchdogTest.cls
git commit -m "test: add unit tests for watchdog auto-reclaim"
```
