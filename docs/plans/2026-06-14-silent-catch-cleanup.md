# Silent Catch Block Cleanup Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Clean up all empty, silent, or unlogged catch blocks in the Revenant Workflow Engine codebase to ensure no failures are swallowed without developer visibility.

**Architecture:** Add appropriate warning/error logging (`System.debug(LoggingLevel.WARN/ERROR/FINE, ...)`) to catch blocks that previously did nothing or rethrown without logging. For LWC controller methods, ensure `AuraHandledException` blocks log the full error stack trace to the system debug log before throwing. Avoid exception-based control flow for Salesforce ID casting by checking length and prefix before casting.

**Tech Stack:** Salesforce Apex, Salesforce CLI (sf)

---

### Task 1: Clean up StepResult.cls Fallback Catch

**Files:**
- Modify: `c:/Users/markm/revenant/force-app/main/default/classes/StepResult.cls:120-126`
- Test: `c:/Users/markm/revenant/force-app/main/default/classes/StepContextTest.cls`

**Step 1: Write the failing test**
*Note: This is a logging enhancement, so existing tests already exercise this path. We will verify the logic.*

**Step 2: Run test to verify it passes currently**
Run: `sf apex run test -n StepContextTest -y`
Expected: PASS

**Step 3: Write implementation**
Modify `c:/Users/markm/revenant/force-app/main/default/classes/StepResult.cls`:
```apex
      try {
        JSON.deserializeUntyped(strInput);
        r.parallelInputJson = strInput;
      } catch (Exception e) {
        System.debug(LoggingLevel.FINE, 'Parallel input is not a JSON string, serializing: ' + e.getMessage());
        r.parallelInputJson = JSON.serialize(strInput);
      }
```

**Step 4: Run test to verify it still passes**
Run: `sf apex run test -n StepContextTest -y`
Expected: PASS

**Step 5: Commit**
```bash
git add force-app/main/default/classes/StepResult.cls
git commit -m "chore: add fine logging to StepResult JSON parsing fallback catch"
```

---

### Task 2: Harden WorkflowDashboardController.cls Catch Blocks and ID Casting

**Files:**
- Modify: `c:/Users/markm/revenant/force-app/main/default/classes/WorkflowDashboardController.cls`
- Test: `c:/Users/markm/revenant/force-app/main/default/classes/WorkflowDashboardControllerTest.cls`

**Step 1: Write/verify test coverage**
*Note: We already have comprehensive tests in `WorkflowDashboardControllerTest.cls` covering all Aura methods and fallback scenarios.*

**Step 2: Run test to verify it passes currently**
Run: `sf apex run test -n WorkflowDashboardControllerTest -y`
Expected: PASS

**Step 3: Write implementation**
Modify `c:/Users/markm/revenant/force-app/main/default/classes/WorkflowDashboardController.cls`:
1. Line 35 (`getAttachmentId`):
```apex
      try {
        Map<String, Object> marker = (Map<String, Object>) JSON.deserializeUntyped(
          textValue
        );
        return (Id) marker.get('$attachmentId');
      } catch (Exception ex) {
        System.debug(LoggingLevel.FINE, 'getAttachmentId parsing fallback: ' + ex.getMessage());
      }
```
2. Line 184 (`getFilteredInstances` ID cast):
```apex
        String jobIdStr = inst.Async_Job_Id__c;
        if ((jobIdStr.length() == 15 || jobIdStr.length() == 18) && 
            (jobIdStr.startsWith('08e') || jobIdStr.startsWith('707'))) {
          try {
            Id jobId = (Id) jobIdStr;
            if (jobId.getSobjectType() == CronTrigger.SObjectType) {
              cronIds.add(jobId);
            } else if (jobId.getSobjectType() == AsyncApexJob.SObjectType) {
              asyncIds.add(jobId);
            }
          } catch (Exception ex) {
            System.debug(LoggingLevel.WARN, 'Failed to cast Async Job ID: ' + jobIdStr + ', error: ' + ex.getMessage());
          }
        } else {
          System.debug(LoggingLevel.WARN, 'Invalid Async Job ID format: ' + jobIdStr);
        }
```
3. Line 226 (`getFilteredInstances` active checks):
```apex
          String jobIdStr = inst.Async_Job_Id__c;
          if ((jobIdStr.length() == 15 || jobIdStr.length() == 18) && 
              (jobIdStr.startsWith('08e') || jobIdStr.startsWith('707'))) {
            try {
              Id jobId = (Id) jobIdStr;
              if (jobId.getSobjectType() == CronTrigger.SObjectType && activeCronIds.contains(jobId)) {
                waitingOn = 'Scheduled Job';
              } else if (jobId.getSobjectType() == AsyncApexJob.SObjectType && activeAsyncIds.contains(jobId)) {
                waitingOn = 'Delayed Queueable';
              } else {
                waitingOn = 'Watchdog';
              }
            } catch (Exception ex) {
              System.debug(LoggingLevel.WARN, 'Failed to cast Async Job ID: ' + jobIdStr + ', error: ' + ex.getMessage());
              waitingOn = 'Watchdog';
            }
          } else {
            System.debug(LoggingLevel.WARN, 'Invalid Async Job ID format: ' + jobIdStr);
            waitingOn = 'Watchdog';
          }
```
4. Line 360 (`getInstanceDetails` ID cast):
```apex
        String jobIdStr = instance.Async_Job_Id__c;
        if ((jobIdStr.length() == 15 || jobIdStr.length() == 18) && 
            (jobIdStr.startsWith('08e') || jobIdStr.startsWith('707'))) {
          try {
            Id jobId = (Id) jobIdStr;
            if (jobId.getSobjectType() == CronTrigger.SObjectType) {
              List<CronTrigger> cronJobs = [SELECT Id FROM CronTrigger WHERE Id = :jobId AND State IN ('WAITING', 'ACQUIRED', 'QUEUED', 'EXECUTING') WITH SYSTEM_MODE LIMIT 1];
              if (!cronJobs.isEmpty()) {
                waitingOn = 'Scheduled Job';
              } else {
                waitingOn = 'Watchdog';
              }
            } else if (jobId.getSobjectType() == AsyncApexJob.SObjectType) {
              List<AsyncApexJob> asyncJobs = [SELECT Id FROM AsyncApexJob WHERE Id = :jobId AND Status IN ('Queued', 'Holding', 'Preparing', 'Processing') WITH SYSTEM_MODE LIMIT 1];
              if (!asyncJobs.isEmpty()) {
                waitingOn = 'Delayed Queueable';
              } else {
                waitingOn = 'Watchdog';
              }
            }
          } catch (Exception ex) {
            System.debug(LoggingLevel.WARN, 'Failed to cast Async Job ID: ' + jobIdStr + ', error: ' + ex.getMessage());
            waitingOn = 'Watchdog';
          }
        } else {
          System.debug(LoggingLevel.WARN, 'Invalid Async Job ID format: ' + jobIdStr);
          waitingOn = 'Watchdog';
        }
```
5. All AuraHandledException catches:
Add `System.debug(LoggingLevel.ERROR, 'Aura operation failed: ' + ex.getMessage() + '\n' + ex.getStackTraceString());` before `throw new AuraHandledException(...)` at lines 455, 465, 490, 500, 527, 626, and 636.

**Step 4: Run test to verify it still passes**
Run: `sf apex run test -n WorkflowDashboardControllerTest -y`
Expected: PASS

**Step 5: Commit**
```bash
git add force-app/main/default/classes/WorkflowDashboardController.cls
git commit -m "chore: clean up empty catches and add Aura debugging to WorkflowDashboardController"
```

---

### Task 3: Clean up WorkflowEngine.cls Silent Catch Blocks

**Files:**
- Modify: `c:/Users/markm/revenant/force-app/main/default/classes/WorkflowEngine.cls`
- Test: `c:/Users/markm/revenant/force-app/main/default/classes/WorkflowEngineTest.cls`

**Step 1: Verify test coverage**
*Note: Existing unit tests cover these execution paths.*

**Step 2: Run test to verify it passes currently**
Run: `sf apex run test -n WorkflowEngineTest -y`
Expected: PASS

**Step 3: Write implementation**
Modify the following catch blocks in `c:/Users/markm/revenant/force-app/main/default/classes/WorkflowEngine.cls`:
1. Line 24 (static metadata load):
```apex
    } catch (Exception ex) {
      System.debug(LoggingLevel.WARN, 'Revenant configuration metadata query failed: ' + ex.getMessage());
    }
```
2. Line 1208 (deserialize parallel step result):
```apex
          try {
            outputVal = JSON.deserializeUntyped(resolvedOutput);
          } catch (Exception ex) {
            System.debug(LoggingLevel.FINE, 'Parallel step output was not JSON, falling back to raw string: ' + ex.getMessage());
            outputVal = resolvedOutput;
          }
```
3. Line 1841 (signal cancellation JSON check):
```apex
        try {
          Map<String, Object> params = (Map<String, Object>) JSON.deserializeUntyped(
            payload
          );
          if (params.containsKey('runCompensations')) {
            runCompensations = (Boolean) params.get('runCompensations');
          }
        } catch (Exception e) {
          System.debug(LoggingLevel.WARN, 'Failed to parse cancel payload, using default runCompensations: ' + e.getMessage());
        }
```
4. Line 1878 (queueable job fallback):
```apex
          try {
            if (Limits.getQueueableJobs() < Limits.getLimitQueueableJobs()) {
              System.enqueueJob(new WorkflowOrchestrator(instance.Id));
            } else {
              enqueueOrchestrator(instance.Id, null);
            }
          } catch (Exception ex) {
            System.debug(LoggingLevel.WARN, 'Queueable enqueue failed, falling back to Platform Event: ' + ex.getMessage());
            enqueueOrchestrator(instance.Id, null);
          }
```
5. Line 2762 (abort scheduled jobs):
```apex
      try {
        System.abortJob(triggerJob.Id);
      } catch (Exception e) {
        System.debug(LoggingLevel.WARN, 'Failed to abort job ' + triggerJob.Id + ': ' + e.getMessage());
      }
```
6. Line 2776 (enqueue orchestrators in test):
```apex
        try {
          if (Limits.getQueueableJobs() < Limits.getLimitQueueableJobs()) {
            System.enqueueJob(new WorkflowOrchestrator(instId));
          }
        } catch (Exception e) {
          System.debug(LoggingLevel.WARN, 'Failed to enqueue WorkflowOrchestrator for ' + instId + ': ' + e.getMessage());
        }
```
7. Line 2860 (resolve offloaded payload):
```apex
      try {
        Map<String, Object> marker = (Map<String, Object>) JSON.deserializeUntyped(
          textValue
        );
        Id attachmentId = (Id) marker.get('$attachmentId');
        List<ContentVersion> cvs = [
          SELECT VersionData
          FROM ContentVersion
          WHERE ContentDocumentId = :attachmentId AND IsLatest = TRUE
          WITH SYSTEM_MODE
        ];
        if (!cvs.isEmpty()) {
          return cvs[0].VersionData.toString();
        }
      } catch (Exception ex) {
        System.debug(LoggingLevel.WARN, 'Failed to resolve offloaded payload, falling back to raw value: ' + ex.getMessage());
      }
```
8. Line 2894 (ContentDocumentLink default visibility failure):
```apex
      try {
        insert as system cdl;
      } catch (DmlException ex) {
        System.debug(LoggingLevel.FINE, 'ContentDocumentLink insert failed with default visibility, retrying with AllUsers: ' + ex.getMessage());
        cdl.Visibility = 'AllUsers';
        insert as system cdl;
      }
```
9. Line 3177 (getStepTimeoutSeconds dynamic Type check):
```apex
    try {
      Type stepType = Type.forName(className);
      if (stepType != null) {
        Object stepObj = stepType.newInstance();
        if (stepObj instanceof TimeoutConfigurable) {
          return ((TimeoutConfigurable) stepObj).getTimeoutSeconds();
        }
      }
    } catch (Exception e) {
      System.debug(LoggingLevel.FINE, 'Failed to instantiate type to read timeout duration for step: ' + className + ', error: ' + e.getMessage());
    }
```
10. Line 3295-3299 (scheduleTimeout scheduling catches):
```apex
    } catch (AsyncException ex) {
      System.debug(LoggingLevel.INFO, 'Async timeout scheduling limit reached, relying on watchdog: ' + ex.getMessage());
    } catch (Exception ex) {
      System.debug(LoggingLevel.WARN, 'Failed to schedule timeout job: ' + ex.getMessage());
    }
```
11. Line 3344-3350 (scheduleRetry scheduling catches):
```apex
    } catch (AsyncException ex) {
      System.debug(LoggingLevel.INFO, 'Async retry scheduling limit reached, relying on watchdog: ' + ex.getMessage());
      return null;
    } catch (Exception ex) {
      System.debug(LoggingLevel.WARN, 'Failed to schedule retry job: ' + ex.getMessage());
      return null;
    }
```
12. Line 3391-3397 (scheduleSleepResume scheduling catches):
```apex
    } catch (AsyncException ex) {
      System.debug(LoggingLevel.INFO, 'Async sleep scheduling limit reached, relying on watchdog: ' + ex.getMessage());
      return null;
    } catch (Exception ex) {
      System.debug(LoggingLevel.WARN, 'Failed to schedule sleep job: ' + ex.getMessage());
      return null;
    }
```
13. Line 3412 (cancelTimeoutJob abort job):
```apex
      try {
        System.abortJob(triggerJob.Id);
      } catch (Exception e) {
        System.debug(LoggingLevel.WARN, 'Failed to cancel timeout job ' + triggerJob.Id + ': ' + e.getMessage());
      }
```

**Step 4: Run test to verify it passes**
Run: `sf apex run test -n WorkflowEngineTest -y`
Expected: PASS

**Step 5: Commit**
```bash
git add force-app/main/default/classes/WorkflowEngine.cls
git commit -m "chore: clean up empty catches and add warning logging to WorkflowEngine"
```

---

### Task 4: Verify Full Codebase Integrity

**Files:**
- None (verification step)

**Step 1: Deploy all local changes to scratch org**
Run: `sf project deploy start`
Expected: Successful deployment with no compilation errors.

**Step 2: Run all tests in scratch org**
Run: `sf apex run test -w 10 -y`
Expected: All tests pass successfully (100% pass rate).
