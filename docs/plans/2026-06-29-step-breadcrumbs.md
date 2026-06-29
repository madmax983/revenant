# Step Breadcrumbs Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Implement issue #92 by exposing a log API in `StepContext`, buffering logs during step executions, persisting them to the database using `Workflow_Log__c` during checkpoint writes, retrieving them in the dashboard controller, and displaying them on the timeline LWC.

**Architecture:** Expose `StepContext.Level` and log APIs (`log()`). Buffer logs in-memory. In `WorkflowEngine.cls`, read logs from the context and insert them as `Workflow_Log__c` records of type `StepBreadcrumb` inside the same DML block as the step execution write (ensuring effectively-once behavior). Query these logs in `WorkflowDashboardController.cls` and group/show them in the LWC timeline with custom styling.

**Tech Stack:** Apex, Salesforce custom objects, Lightning Web Components (HTML/CSS/JS).

---

## Task 1: StepContext Log API Definition & Buffering
Add log enum, wrappers, and APIs to `StepContext`.

**Files:**
- Modify: [StepContext.cls](file:///c:/Users/markm/revenant/force-app/main/default/classes/StepContext.cls)

**Step 1: Write failing tests in `StepContextTest.cls`**
Add testing methods for logging, message truncation, and entry list limits.
```apex
  @isTest
  static void testLogApiBuffering() {
    Id dummyInstanceId = '00D000000000001EAA';
    StepContext ctx = new StepContext(dummyInstanceId, 'TestWorkflow', 'TestStep', null, null, null, null);
    
    ctx.log(StepContext.Level.INFO, 'Test message');
    ctx.log(StepContext.Level.WARN, 'Warning message', new Map<String, Object>{'status' => 'warn_status'});
    ctx.log(StepContext.Level.ERROR, 'Error message');

    List<StepContext.Breadcrumb> crumbs = ctx.getBreadcrumbs();
    System.assertEquals(3, crumbs.size());
    System.assertEquals(StepContext.Level.INFO, crumbs[0].level);
    System.assertEquals('Test message', crumbs[0].message);
    
    System.assertEquals(StepContext.Level.WARN, crumbs[1].level);
    System.assert(crumbs[1].message.contains('Warning message'));
    System.assert(crumbs[1].message.contains('warn_status'));

    System.assertEquals(StepContext.Level.ERROR, crumbs[2].level);
    System.assertEquals('Error message', crumbs[2].message);
  }

  @isTest
  static void testLogCharacterTruncation() {
    Id dummyInstanceId = '00D000000000001EAA';
    StepContext ctx = new StepContext(dummyInstanceId, 'TestWorkflow', 'TestStep', null, null, null, null);
    
    String longMsg = 'A'.repeat(5000);
    ctx.log(StepContext.Level.INFO, longMsg);

    List<StepContext.Breadcrumb> crumbs = ctx.getBreadcrumbs();
    System.assertEquals(1, crumbs.size());
    System.assertEquals(4016, crumbs[0].message.length()); // 4000 chars + '... [TRUNCATED]' length (16)
    System.assert(crumbs[0].message.endsWith('... [TRUNCATED]'));
  }

  @isTest
  static void testLogEntriesTruncation() {
    Id dummyInstanceId = '00D000000000001EAA';
    StepContext ctx = new StepContext(dummyInstanceId, 'TestWorkflow', 'TestStep', null, null, null, null);
    
    for (Integer i = 0; i < 120; i++) {
      ctx.log(StepContext.Level.INFO, 'Log ' + i);
    }

    List<StepContext.Breadcrumb> crumbs = ctx.getBreadcrumbs();
    System.assertEquals(101, crumbs.size()); // 100 logs + 1 truncation warning log
    System.assertEquals(StepContext.Level.WARN, crumbs[100].level);
    System.assert(crumbs[100].message.contains('Log limit of 100 entries reached'));
  }
```

**Step 2: Run test to verify it fails**
Run: `sf apex run test -n StepContextTest --synchronous`
Expected: Compile error due to missing Level enum, log method, etc.

**Step 3: Implement minimal code in `StepContext.cls`**
- Declare:
  ```apex
  public enum Level { INFO, WARN, ERROR }
  public class Breadcrumb {
    public Level level { get; set; }
    public String message { get; set; }
    public DateTime timestamp { get; set; }
    public Breadcrumb(Level level, String message) {
      this.level = level;
      this.message = message;
      this.timestamp = DateTime.now();
    }
  }
  private List<Breadcrumb> breadcrumbs = new List<Breadcrumb>();
  private static final Integer MAX_BREADCRUMBS = 100;
  private static final Integer MAX_MESSAGE_LENGTH = 4000;
  ```
- Implement:
  ```apex
  public void log(Level lvl, String message) {
    log(lvl, message, null);
  }

  public void log(Level lvl, String message, Map<String, Object> logContext) {
    if (breadcrumbs.size() >= MAX_BREADCRUMBS) {
      // Check if the last item is the warning breadcrumb
      if (breadcrumbs[breadcrumbs.size() - 1].level == Level.WARN && 
          breadcrumbs[breadcrumbs.size() - 1].message.contains('Log limit of')) {
        return;
      }
      breadcrumbs.add(new Breadcrumb(
        Level.WARN,
        '[TRUNCATED] Log limit of ' + MAX_BREADCRUMBS + ' entries reached. Subsequent step logs are discarded.'
      ));
      return;
    }

    String fullMsg = message != null ? message : '';
    if (logContext != null && !logContext.isEmpty()) {
      fullMsg += ' | Context: ' + JSON.serialize(logContext);
    }

    if (fullMsg.length() > MAX_MESSAGE_LENGTH) {
      fullMsg = fullMsg.left(MAX_MESSAGE_LENGTH) + '... [TRUNCATED]';
    }

    breadcrumbs.add(new Breadcrumb(lvl, fullMsg));
  }

  public List<Breadcrumb> getBreadcrumbs() {
    return this.breadcrumbs;
  }
  ```

**Step 4: Run test to verify it passes**
Run: `sf apex run test -n StepContextTest --synchronous`
Expected: Pass (100%)

---

## Task 2: Engine Integration for Breadcrumb DML
Integrate the log flushing into the step outcome handlers (`handleStepResult` and `handleCompensationStepResult`).

**Files:**
- Modify: [WorkflowEngine.cls](file:///c:/Users/markm/revenant/force-app/main/default/classes/WorkflowEngine.cls)

**Step 1: Write failing tests in `WorkflowEngineTest.cls`**
Add mock steps that log breadcrumbs and a test confirming they are written.
Add a test that verifies retry runs preserve exactly one set, and rollback on failure doesn't write anything.
```apex
  // Mock steps for logging tests
  public class LoggingStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      ctx.log(StepContext.Level.INFO, 'Executing logging step');
      return StepResult.complete(null, 'Success');
    }
  }

  public class LoggingThrowStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      ctx.log(StepContext.Level.INFO, 'Going to throw');
      throw new IllegalArgumentException('Error thrown from step');
    }
  }

  public class LoggingRetryStep implements WorkflowStep, RetryConfigurable {
    public RetryPolicy getRetryPolicy() {
      return new RetryPolicy().withMaximumAttempts(3).withInitialIntervalSeconds(1);
    }
    public StepResult execute(StepContext ctx) {
      ctx.log(StepContext.Level.INFO, 'Attempt ' + ctx.attempt);
      if (ctx.attempt < 3) {
        return StepResult.retry();
      }
      return StepResult.complete(null, 'Success');
    }
  }

  public class LoggingWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowEngineTest.LoggingStep' };
    }
    public String getInitialStep() {
      return 'WorkflowEngineTest.LoggingStep';
    }
    public String getNextStep(String currentStepName, StepResult result) {
      return null;
    }
  }

  public class LoggingThrowWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowEngineTest.LoggingThrowStep' };
    }
    public String getInitialStep() {
      return 'WorkflowEngineTest.LoggingThrowStep';
    }
    public String getNextStep(String currentStepName, StepResult result) {
      return null;
    }
  }

  public class LoggingRetryWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowEngineTest.LoggingRetryStep' };
    }
    public String getInitialStep() {
      return 'WorkflowEngineTest.LoggingRetryStep';
    }
    public String getNextStep(String currentStepName, StepResult result) {
      return null;
    }
  }

  @isTest
  static void testStepBreadcrumbsPersisted() {
    Test.startTest();
    Id instanceId = WorkflowEngine.start('WorkflowEngineTest.LoggingWorkflow', 'LogKey', null);
    Test.stopTest(); // runs LoggingStep

    List<Workflow_Log__c> logs = [
      SELECT Message__c, Level__c, Log_Type__c, Correlation_Key__c 
      FROM Workflow_Log__c 
      WHERE Workflow_Instance__c = :instanceId AND Log_Type__c = 'StepBreadcrumb'
    ];
    System.assertEquals(1, logs.size());
    System.assertEquals('Executing logging step', logs[0].Message__c);
    System.assertEquals('INFO', logs[0].Level__c);
    System.assertEquals('WorkflowEngineTest.LoggingStep', logs[0].Correlation_Key__c);
  }

  @isTest
  static void testStepBreadcrumbsRollbackOnFailure() {
    Test.startTest();
    try {
      WorkflowEngine.start('WorkflowEngineTest.LoggingThrowWorkflow', 'ThrowKey', null);
      Test.stopTest();
    } catch (Exception ex) {
      // expected throw
    }

    // Since the transaction rolled back, NO logs should be committed to the database.
    List<Workflow_Log__c> logs = [
      SELECT Id FROM Workflow_Log__c WHERE Log_Type__c = 'StepBreadcrumb'
    ];
    System.assertEquals(0, logs.size());
  }

  @isTest
  static void testStepBreadcrumbsEffectivelyOnceOnRetry() {
    Test.startTest();
    Id instanceId = WorkflowEngine.start('WorkflowEngineTest.LoggingRetryWorkflow', 'RetryKey', null);
    Test.stopTest(); // runs first attempt -> retry

    // Execute retries synchronously
    new WorkflowOrchestrator(instanceId).execute(null); // Attempt 2 -> retry
    new WorkflowOrchestrator(instanceId).execute(null); // Attempt 3 -> complete

    // There should be exactly ONE set of breadcrumbs for the committed attempt (Attempt 3)
    List<Workflow_Log__c> logs = [
      SELECT Message__c, Level__c FROM Workflow_Log__c 
      WHERE Workflow_Instance__c = :instanceId AND Log_Type__c = 'StepBreadcrumb'
      ORDER BY CreatedDate ASC
    ];
    // Each attempt logs "Attempt X". The first two attempts rolled back before their checkpoint,
    // so only the final committed attempt's logs persist.
    System.assertEquals(1, logs.size());
    System.assertEquals('Attempt 3', logs[0].Message__c);
  }
```

**Step 2: Run test to verify it fails**
Run: `sf apex run test -n WorkflowEngineTest --synchronous`
Expected: Compile error (or tests fail if we manually bypass compile) because breadcrumbs are not yet persisted.

**Step 3: Implement minimal code in `WorkflowEngine.cls`**
- Implement:
  ```apex
  private static void persistStepBreadcrumbs(
    Workflow_Instance__c instance,
    Workflow_Step_Execution__c stepExec,
    StepContext context
  ) {
    if (context == null || stepExec == null) {
      return;
    }
    List<StepContext.Breadcrumb> crumbs = context.getBreadcrumbs();
    if (crumbs == null || crumbs.isEmpty()) {
      return;
    }
    List<Workflow_Log__c> logsToInsert = new List<Workflow_Log__c>();
    for (StepContext.Breadcrumb b : crumbs) {
      logsToInsert.add(new Workflow_Log__c(
        Workflow_Instance__c = instance.Id,
        Workflow_Name__c = instance.Workflow_Name__c,
        Correlation_Key__c = stepExec.Step_Name__c,
        Log_Type__c = 'StepBreadcrumb',
        Level__c = b.level.name(),
        Message__c = b.message,
        Fire_Time__c = b.timestamp
      ));
    }
    insert as system logsToInsert;
  }
  ```
- Call this method inside:
  - `handleStepResult`:
    ```apex
    // Right after saveStepExec(stepExec) inside COMPLETE, YIELD, SUSPEND, SLEEP, START_CHILD, START_CHILDREN, WAIT_FOR_APPROVAL, SPLIT, RETRY outcome blocks.
    ```
  - `handleCompensationStepResult`:
    ```apex
    // Similarly inside COMPLETE (Compensated), YIELD, SUSPEND, SLEEP, RETRY outcome blocks.
    ```

**Step 4: Run test to verify it passes**
Run: `sf apex run test -n WorkflowEngineTest --synchronous`
Expected: Pass

---

## Task 3: Dashboard Controller Integration
Query the breadcrumbs when retrieving instance details for the operator timeline.

**Files:**
- Modify: [WorkflowDashboardController.cls](file:///c:/Users/markm/revenant/force-app/main/default/classes/WorkflowDashboardController.cls)
- Modify: [WorkflowDashboardControllerTest.cls](file:///c:/Users/markm/revenant/force-app/main/default/classes/WorkflowDashboardControllerTest.cls)

**Step 1: Write failing test in `WorkflowDashboardControllerTest.cls`**
Add a test that creates an instance, persists a step log, calls `getInstanceDetails()`, and checks the `'breadcrumbs'` list is returned and matches.

**Step 2: Run test to verify it fails**
Expected: Fail (missing `breadcrumbs` key in return Map)

**Step 3: Implement query in `WorkflowDashboardController.cls`**
In `getInstanceDetails` method:
```apex
    List<Workflow_Log__c> breadcrumbs = [
      SELECT Id, Correlation_Key__c, Message__c, Level__c, CreatedDate
      FROM Workflow_Log__c
      WHERE Workflow_Instance__c = :instanceId
        AND Log_Type__c = 'StepBreadcrumb'
      WITH SYSTEM_MODE
      ORDER BY CreatedDate ASC
    ];
```
Add to return Map:
`'breadcrumbs' => breadcrumbs`

**Step 4: Run test to verify it passes**
Expected: Pass

---

## Task 4: LWC Timeline Log rendering
Expose and render the step breadcrumbs inline inside the expanded step details.

**Files:**
- Modify: [workflowDashboard.js](file:///c:/Users/markm/revenant/force-app/main/default/lwc/workflowDashboard/workflowDashboard.js)
- Modify: [workflowDashboard.html](file:///c:/Users/markm/revenant/force-app/main/default/lwc/workflowDashboard/workflowDashboard.html)
- Modify: [workflowDashboard.css](file:///c:/Users/markm/revenant/force-app/main/default/lwc/workflowDashboard/workflowDashboard.css)

**Step 1: Write failing Jest tests (Optional/If applicable)**
Verify standard LWC behaviors.

**Step 2: Modify `workflowDashboard.js`**
Associate logs with step name (`step.Step_Name__c`).
```javascript
const stepBreadcrumbs = (result.breadcrumbs || [])
  .filter((b) => b.Correlation_Key__c === step.Step_Name__c)
  .map((b) => {
    return {
      Id: b.Id,
      Level__c: b.Level__c,
      Message__c: b.Message__c,
      formattedDate: this.formatDateTime(b.CreatedDate),
      className: `log-item log-${(b.Level__c || "INFO").toLowerCase()}`,
    };
  });
```
Add `breadcrumbs: stepBreadcrumbs` to step objects mapped on lines 964-1002.

**Step 3: Modify `workflowDashboard.html`**
Inside `<template if:true={step.showDetails}>`:
```html
<template if:true={step.breadcrumbs.length}>
    <div class="slds-m-top_small log-container">
        <div class="slds-text-title_caps slds-m-bottom_x-small text-secondary font-outfit">Step Logs</div>
        <div class="log-lines">
            <template for:each={step.breadcrumbs} for:item="log">
                <div key={log.Id} class={log.className}>
                    <span class="log-time">[{log.formattedDate}]</span>
                    <span class="log-level">{log.Level__c}</span>
                    <span class="log-message">{log.Message__c}</span>
                </div>
            </template>
        </div>
    </div>
</template>
```

**Step 4: Modify `workflowDashboard.css`**
Add styles for `.log-container`, `.log-item`, `.log-time`, `.log-level`, `.log-info`, `.log-warn`, `.log-error`, `.log-message`.

**Step 5: Run tests and verify everything is functional**
Run all tests.
