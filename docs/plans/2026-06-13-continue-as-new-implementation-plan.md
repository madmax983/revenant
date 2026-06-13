# Continue-As-New Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Implement the Continue-As-New execution pattern to allow long-running or perpetual workflows to start fresh executions with clean step histories.

**Architecture:** We will add a `Previous_Instance__c` self-lookup and a `ContinuedAsNew` status value to the schema. The engine will detect when a step returns `CONTINUE_AS_NEW`, dynamically resolve/increment the correlation key suffix, transition the current instance to a terminal `ContinuedAsNew` status, and spawn the successor run.

**Tech Stack:** Salesforce DX (SFDX) Metadata, Apex, LWC.

---

### Task 1: Schema Metadata Updates

Modify picklists and create the self-lookup field.

**Files:**
* Create: `force-app/main/default/objects/Workflow_Instance__c/fields/Previous_Instance__c.field-meta.xml`
* Modify: `force-app/main/default/objects/Workflow_Instance__c/fields/Status__c.field-meta.xml`
* Modify: `force-app/main/default/objects/Workflow_Step_Execution__c/fields/Status__c.field-meta.xml`

**Step 1: Create Previous_Instance__c field metadata**
Write `force-app/main/default/objects/Workflow_Instance__c/fields/Previous_Instance__c.field-meta.xml`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
    <fullName>Previous_Instance__c</fullName>
    <deleteConstraint>SetNull</deleteConstraint>
    <description>Points to the predecessor workflow instance that continued-as-new into this one.</description>
    <externalId>false</externalId>
    <label>Previous Instance</label>
    <referenceTo>Workflow_Instance__c</referenceTo>
    <relationshipLabel>Next Runs</relationshipLabel>
    <relationshipName>Next_Runs</relationshipName>
    <required>false</required>
    <trackTrending>false</trackTrending>
    <type>Lookup</type>
</CustomField>
```

**Step 2: Modify Workflow_Instance__c.Status__c picklist values**
In `force-app/main/default/objects/Workflow_Instance__c/fields/Status__c.field-meta.xml`, add the `ContinuedAsNew` picklist value. Let's make sure it is added under `<valueSetDefinition>`.
```xml
                <value>
                    <fullName>ContinuedAsNew</fullName>
                    <default>false</default>
                    <label>Continued As New</label>
                </value>
```

**Step 3: Modify Workflow_Step_Execution__c.Status__c picklist values**
In `force-app/main/default/objects/Workflow_Step_Execution__c/fields/Status__c.field-meta.xml`, add the `ContinuedAsNew` picklist value.
```xml
                <value>
                    <fullName>ContinuedAsNew</fullName>
                    <default>false</default>
                    <label>Continued As New</label>
                </value>
```

**Step 4: Deploy and Commit**
Run: `sf project deploy start`
Run:
`git add force-app/main/default/objects/`
`git commit -m "feat: add Previous_Instance__c field and ContinuedAsNew picklist values"`

---

### Task 2: Update StepResult Class

Modify `StepResult` class to add properties, enum values, and static constructors.

**Files:**
* Modify: `force-app/main/default/classes/StepResult.cls`

**Step 1: Modify Enum and Add Properties**
Open `force-app/main/default/classes/StepResult.cls`.
Add `CONTINUE_AS_NEW` to the `ActionType` enum (around line 2).
Add the following properties (around line 17):
```java
    public String nextInputJson { get; set; }
    public String newCorrelationKey { get; set; }
```

**Step 2: Add Static Constructors**
Add the following methods at the end of the class (before the last closing brace):
```java
    public static StepResult continueAsNew(Object nextInput) {
        StepResult r = new StepResult();
        r.action = ActionType.CONTINUE_AS_NEW;
        r.nextInputJson = (nextInput != null) ? JSON.serialize(nextInput) : null;
        r.newCorrelationKey = null;
        return r;
    }

    public static StepResult continueAsNew(Object nextInput, String customKey) {
        StepResult r = new StepResult();
        r.action = ActionType.CONTINUE_AS_NEW;
        r.nextInputJson = (nextInput != null) ? JSON.serialize(nextInput) : null;
        r.newCorrelationKey = customKey;
        return r;
    }
```

**Step 3: Deploy and Commit**
Run: `sf project deploy start -m ApexClass:StepResult`
Run:
`git add force-app/main/default/classes/StepResult.cls`
`git commit -m "feat: add CONTINUE_AS_NEW ActionType and methods to StepResult"`

---

### Task 3: Update Core Engine Execution

Modify `WorkflowEngine.cls` to process `CONTINUE_AS_NEW` actions.

**Files:**
* Modify: `force-app/main/default/classes/WorkflowEngine.cls`

**Step 1: Add Suffix Resolution Helper Method**
Add the following helper method near the bottom of `WorkflowEngine.cls`:
```java
    private static String resolveContinueAsNewKey(String currentKey, String customKey) {
        if (String.isNotBlank(customKey)) {
            return customKey;
        }
        if (String.isBlank(currentKey)) {
            return 'Run_' + System.currentTimeMillis();
        }
        
        Pattern p = Pattern.compile('^(.*)_run(\\d+)$');
        Matcher m = p.matcher(currentKey);
        if (m.matches()) {
            String base = m.group(1);
            Integer nextNum = Integer.valueOf(m.group(2)) + 1;
            return base + '_run' + nextNum;
        }
        return currentKey + '_run2';
    }
```

**Step 2: Add CONTINUE_AS_NEW branch in handleStepResult**
Inside `handleStepResult` in `WorkflowEngine.cls`, around the completion action checks:
Search for: `if (result.action == StepResult.ActionType.COMPLETE) {`
Add the following branch right before or after it:
```java
        else if (result.action == StepResult.ActionType.CONTINUE_AS_NEW) {
            stepExec.Status__c = 'ContinuedAsNew';
            stepExec.Output__c = savePayloadIfNeeded(instance.Id, result.nextInputJson, 'ContinueInput_' + stepExec.Step_Name__c.replaceAll('[^a-zA-Z0-9]', '_'));
            update stepExec;

            // Resolve the new correlation key
            String newKey = resolveContinueAsNewKey(instance.Correlation_Key__c, result.newCorrelationKey);

            // Mark current instance as ContinuedAsNew
            instance.Status__c = 'ContinuedAsNew';
            instance.Current_Step__c = null;
            update instance;

            // Spawn successor instance
            Workflow_Instance__c nextInstance = new Workflow_Instance__c(
                Workflow_Name__c = instance.Workflow_Name__c,
                Correlation_Key__c = newKey,
                Previous_Instance__c = instance.Id,
                Definition_Version__c = instance.Definition_Version__c
            );
            insert nextInstance;

            // Set input and save payload
            nextInstance.Input__c = savePayloadIfNeeded(nextInstance.Id, result.nextInputJson, 'Input_' + nextInstance.Id);
            update nextInstance;

            // Enqueue the successor run
            if (Test.isRunningTest()) {
                System.enqueueJob(new WorkflowOrchestrator(nextInstance.Id));
            } else {
                enqueueOrchestrator(nextInstance.Id, null);
            }
        }
```

**Step 3: Deploy and Commit**
Run: `sf project deploy start -m ApexClass:WorkflowEngine`
Run:
`git add force-app/main/default/classes/WorkflowEngine.cls`
`git commit -m "feat: handle CONTINUE_AS_NEW workflow transitions in engine"`

---

### Task 4: Update Dashboard, Purge Job, and LWC

Update query fields, dashboard CSS/JS, and cleanup execution logic.

**Files:**
* Modify: `force-app/main/default/classes/WorkflowDashboardController.cls`
* Modify: `force-app/main/default/classes/CleanupWorkflow.cls`
* Modify: `force-app/main/default/lwc/workflowDashboard/workflowDashboard.js`
* Modify: `force-app/main/default/lwc/workflowDashboard/workflowDashboard.css`

**Step 1: Update Dashboard Controller query**
In `WorkflowDashboardController.cls` line 16, update the SOQL query to select `Previous_Instance__c`:
```java
            SELECT Id, Name, Workflow_Name__c, Status__c, Correlation_Key__c, Input__c, Output__c, Current_Step__c, Error_Message__c, CreatedDate, Parent_Instance__c, Parent_Instance__r.Name, Previous_Instance__c
```

**Step 2: Update CleanupWorkflow Status Filter**
In `CleanupWorkflow.cls` line 38:
```java
                WHERE Status__c IN ('Completed', 'Failed', 'Compensated', 'Cancelled', 'ContinuedAsNew')
```

**Step 3: Update Dashboard LWC Javascript**
In `force-app/main/default/lwc/workflowDashboard/workflowDashboard.js`:
* In `getStatusBadgeClass(status)`:
  ```javascript
                  case 'ContinuedAsNew':
                      return 'badge badge-blue';
  ```
* In `calculateStats()`:
  Include `ContinuedAsNew` in the completed count:
  ```javascript
                  } else if (inst.Status__c === 'Completed' || inst.Status__c === 'ContinuedAsNew') {
                      stats.completed += 1;
  ```

**Step 4: Update Dashboard LWC CSS**
In `force-app/main/default/lwc/workflowDashboard/workflowDashboard.css`, add a style for `.badge-blue` if it doesn't exist:
```css
.badge-blue { background-color: hsl(210, 95%, 45%); color: white; }
```

**Step 5: Deploy and Commit**
Run: `sf project deploy start -p force-app/main/default/lwc/workflowDashboard,force-app/main/default/classes/WorkflowDashboardController.cls,force-app/main/default/classes/CleanupWorkflow.cls`
Run:
`git add force-app/main/`
`git commit -m "feat: update dashboard, cleanup, and badge styles for ContinuedAsNew"`

---

### Task 5: Implement Unit Tests and Verify

Add tests to verify continue-as-new execution logic.

**Files:**
* Modify: `force-app/main/default/classes/WorkflowEngineTest.cls`

**Step 1: Add Mock Workflow and Step**
Add the following classes inside `WorkflowEngineTest.cls` (e.g. around line 35):
```java
    public class DaemonWorkflow implements WorkflowDefinition {
        public String getInitialStep() {
            return 'WorkflowEngineTest.IncrementCounterStep';
        }
        public String getNextStep(String currentStepName, StepResult stepResult) {
            return null;
        }
    }
    
    public class IncrementCounterStep implements WorkflowStep {
        public StepResult execute(StepContext ctx) {
            Integer counter = 0;
            if (String.isNotBlank(ctx.workflowInputJson)) {
                counter = Integer.valueOf(ctx.workflowInputJson);
            }
            if (counter < 2) {
                return StepResult.continueAsNew(counter + 1);
            }
            return StepResult.complete(null, counter + 1);
        }
    }
```

**Step 2: Add testContinueAsNew Method**
Add the following test method inside `WorkflowEngineTest.cls` (at the end of the class):
```java
    @isTest
    static void testContinueAsNew() {
        WorkflowEngine.disableQueueableInTest = true;

        Test.startTest();
        Id instanceId = WorkflowEngine.start('WorkflowEngineTest.DaemonWorkflow', 'DaemonKey', 0);
        Test.stopTest(); // Runs the first execution run (counter 0 -> continueAsNew 1)
        
        // Manual triggers for execution runs 2 and 3
        
        // Query Run 1
        Workflow_Instance__c run1 = [SELECT Status__c, Correlation_Key__c, Input__c FROM Workflow_Instance__c WHERE Id = :instanceId];
        System.assertEquals('ContinuedAsNew', run1.Status__c);
        System.assertEquals('DaemonKey', run1.Correlation_Key__c);

        // Find and run Run 2
        Workflow_Instance__c run2 = [SELECT Id, Status__c, Correlation_Key__c, Input__c, Previous_Instance__c FROM Workflow_Instance__c WHERE Previous_Instance__c = :run1.Id];
        System.assertEquals('Pending', run2.Status__c);
        System.assertEquals('DaemonKey_run2', run2.Correlation_Key__c);
        System.assertEquals('1', run2.Input__c);

        // Execute Run 2 (counter 1 -> continueAsNew 2)
        new WorkflowOrchestrator(run2.Id).execute(null);

        run2 = [SELECT Status__c FROM Workflow_Instance__c WHERE Id = :run2.Id];
        System.assertEquals('ContinuedAsNew', run2.Status__c);

        // Find and run Run 3
        Workflow_Instance__c run3 = [SELECT Id, Status__c, Correlation_Key__c, Input__c, Previous_Instance__c FROM Workflow_Instance__c WHERE Previous_Instance__c = :run2.Id];
        System.assertEquals('Pending', run3.Status__c);
        System.assertEquals('DaemonKey_run3', run3.Correlation_Key__c);
        System.assertEquals('2', run3.Input__c);

        // Execute Run 3 (counter 2 -> complete 3)
        new WorkflowOrchestrator(run3.Id).execute(null);

        run3 = [SELECT Status__c, Output__c FROM Workflow_Instance__c WHERE Id = :run3.Id];
        System.assertEquals('Completed', run3.Status__c);
        System.assertEquals('3', run3.Output__c);
    }
```

**Step 3: Deploy and run tests**
Run: `sf project deploy start -m ApexClass:WorkflowEngineTest`
Run: `sf apex run test -n WorkflowEngineTest -w 10`
Expected: 100% pass rate.

**Step 4: Commit**
Run:
`git add force-app/main/default/classes/WorkflowEngineTest.cls`
`git commit -m "test: add testContinueAsNew verification tests"`
