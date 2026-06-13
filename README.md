# Revenant — Durable Workflow Engine for Salesforce

A native, database-backed durable execution engine for Apex, inspired by Temporal and DBOSS. Revenant leverages Salesforce platform features (Queueables, Platform Events, Transaction Finalizers, and Apex Cursors) to run reliable, resumable state machines that survive transaction failures and governor limits.

---

## Key Capabilities

*   **Resumable Execution (Yielding)**: Long-running loops or paginated tasks can call `shouldYield()` to detect governor limits and automatically checkpoint state to custom objects, resuming in a fresh transaction.
*   **Distributed Rollbacks (Sagas)**: Steps implementing the [CompensatableStep](file:///C:/Users/markm/Documents/antigravity/focused-hopper/force-app/main/default/classes/CompensatableStep.cls) interface register on a LIFO rollback stack. If forward execution fails permanently, the engine automatically rolls back steps in reverse order.
*   **Scatter-Gather (Parallel Processing)**: Split execution across multiple parallel branches and rejoin their outputs before proceeding to subsequent steps.
*   **Watchdog Step Timeouts**: Custom step timeouts scheduled via Scheduled Apex. If a step hangs or exceeds its limits, the watchdog terminates the run and flags the failure.
*   **Continue-As-New (Perpetual Runs)**: Perpetual pollers and daemons can transition to a successor run link (`Previous_Instance__c`) to clear heap/log/database limits and avoid storage leaks.
*   **Platform Event Signals**: External updates and human-in-the-loop approvals wake up suspended workflows via `Workflow_Event__e` platform events.
*   **Large Payload Offloading**: Transparently offloads inputs, outputs, and states exceeding the 131,072-character text area limit into `ContentVersion` attachments.
*   **Metadata failure alerting**: Operators can configure thresholds (consecutive failures, sliding rate counts) via `Workflow_Alert_Config__mdt` records in Setup to trigger notifications on terminal failures.
*   **Salesforce Flow Interoperability**: Invocable actions to launch or signal workflows from standard Flows, plus a generic `WorkflowFlowStep` to execute standard flows as durable workflow steps.

---

## Core Engine Architecture

```mermaid
graph TD
    Start([Start Workflow]) --> Enqueue[Enqueue WorkflowOrchestrator]
    Enqueue --> Run[WorkflowOrchestrator runs runStep]
    Run --> Hydrate[Hydrate Instance & Step State]
    Hydrate --> Exec{Execute Step}
    
    Exec -- COMPLETE --> Next{Has Next Step?}
    Next -- Yes --> SaveStack[Append Compensatable Steps]
    SaveStack --> Run
    Next -- No --> Finish[Status: Completed]
    
    Exec -- YIELD / SLEEP --> Suspend[Save State & Suspend]
    Suspend --> Resume[Signal Event / Timer Fired]
    Resume --> Enqueue
    
    Exec -- ERROR / CRASH --> Fail{Has Compensation Stack?}
    Fail -- Yes --> TransitionComp[Status: Compensating]
    TransitionComp --> Rollback[Run Compensation Steps LIFO]
    Rollback --> CompSuccess{All Rollbacks Done?}
    CompSuccess -- Yes --> TerminalComp[Status: Compensated]
    CompSuccess -- No -- RollbackFail{Compensation Step Fails?}
    RollbackFail -- Yes --> TerminalFail[Status: Failed]
    RollbackFail -- No --> Rollback
    
    Fail -- No --> TerminalFail[Status: Failed]
    TerminalFail --> Alert[WorkflowAlertManager Evaluates CMDT & Sends Email]
```

---

## Getting Started

### 1. Write a Step
Steps implement the [WorkflowStep](file:///C:/Users/markm/Documents/antigravity/focused-hopper/force-app/main/default/classes/WorkflowStep.cls) interface (or [CompensatableStep](file:///C:/Users/markm/Documents/antigravity/focused-hopper/force-app/main/default/classes/CompensatableStep.cls) if rollback logic is required):

```java
public class ProvisionSandboxStep implements CompensatableStep {
    public StepResult execute(StepContext ctx) {
        // Run sandbox creation logic...
        String sandboxId = 'sb_98765';
        return StepResult.complete(null, new Map<String, Object>{'sandboxId' => sandboxId});
    }

    public StepResult compensate(StepContext ctx) {
        // Rollback sandbox creation if later steps fail
        Map<String, Object> state = (Map<String, Object>)JSON.deserializeUntyped(ctx.stepStateJson);
        String sandboxId = (String)state.get('sandboxId');
        // Delete sandbox...
        return StepResult.complete(null, 'Deprovisioned');
    }
}
```

### 2. Define the Workflow DAG
Implement [WorkflowDefinition](file:///C:/Users/markm/Documents/antigravity/focused-hopper/force-app/main/default/classes/WorkflowDefinition.cls) to model transitions:

```java
public class OnboardingWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
        return new List<String>{
            'VerifyOrderStep',
            'ProvisionSandboxStep',
            'SendWelcomeEmailStep'
        };
    }

    public String getInitialStep() {
        return 'VerifyOrderStep';
    }

    public String getNextStep(String currentStepName, StepResult result) {
        if (currentStepName == 'VerifyOrderStep') {
            return 'ProvisionSandboxStep';
        }
        if (currentStepName == 'ProvisionSandboxStep') {
            return 'SendWelcomeEmailStep';
        }
        return null; // Terminal step
    }
}
```

### 3. Start Execution
Invoke the engine from Apex triggers, queueables, or invocables:

```java
Id instanceId = WorkflowEngine.start(
    'OnboardingWorkflow', 
    'Opp_Onboarding_006As00000abcde', 
    '{"accountId": "001As0000012345", "vip": true}'
);
```

---

## Directory Layout

*   `/force-app/main/default/` - Core Framework
    *   `classes/` - Main orchestrator classes, finalizers, and utility helpers.
    *   `objects/` - Custom objects, platform events, and alert config custom metadata models.
    *   `lwc/` - Timeline dashboard visualization LWC.
*   `/examples/main/default/` - Concrete Use Cases
    *   `classes/` - Onboarding, Saga rollbacks, Cursor parallel fan-out, and Versioning examples.
    *   `triggers/` - Opportunity stage triggers initiating workflows.

---

## Testing & Verification

Run the test suite using Salesforce CLI:

```bash
sf apex run test -w 10
```

All 59 test cases verify:
*   DAG progression, step-to-step state handoffs, and finalization.
*   Cursor pagination query limits yielding.
*   Saga distributed transaction rollbacks.
*   Scatter-gather concurrent executions and output joins.
*   ContentVersion large payload offloading.
*   Custom metadata failure threshold evaluations.
