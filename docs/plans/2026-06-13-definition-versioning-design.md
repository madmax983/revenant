# Definition Versioning (Hot Upgrades) Design

This document details the architectural design for introducing versioning (hot upgrades) to the Revenant durable workflow engine.

## Overview
Because workflows can be long-running (suspended for days or weeks waiting for sleep timers or manual approvals), developers must be able to deploy new workflow configurations without disrupting active, running instances. By capturing the version number at start time and propagating it to routing and step contexts, instances remain locked to their baseline definitions.

---

## 1. Data Model & Schema Updates

We will add a version tracking field to the custom objects metadata:

1. **New Field `Definition_Version__c` on `Workflow_Instance__c`**:
   * **Type**: Number (18, 0).
   * **Label**: Definition Version.
   * **Default Value**: `1`.
   * **Purpose**: Tracks the version number of the workflow definition under which this instance was started.

---

## 2. The `VersionedWorkflow` Interface & Engine Start Flow

Workflow definitions that require versioning can implement the new `VersionedWorkflow` interface:

```java
public interface VersionedWorkflow extends WorkflowDefinition {
    Integer getLatestVersion();
    String getNextStep(String currentStepName, StepResult result, Integer version);
}
```

### Version Capture on Start
In `WorkflowEngine.start()`:
1. When instantiating the definition class, the engine checks if the class implements `VersionedWorkflow`.
2. If it does, the engine calls `getLatestVersion()` and saves it to `Definition_Version__c` on the `Workflow_Instance__c` record.
3. If it does not, the engine defaults `Definition_Version__c` to `1`.

---

## 3. Routing & Step Context Integration

### Version-Aware Routing
When a step completes and the engine resolves the next step:
1. The engine checks if the workflow definition class implements `VersionedWorkflow`.
2. If it does, it invokes the 3-argument method:
   `def.getNextStep(currentStep, result, (Integer)instance.Definition_Version__c)`
3. If it does not, it falls back to the legacy 2-argument method:
   `def.getNextStep(currentStep, result)`

### Step Context Access
We will extend `StepContext` to include a public `workflowVersion` field:
```java
public class StepContext {
    public Id workflowInstanceId;
    public String workflowName;
    public String stepName;
    public String workflowInputJson;
    public String previousStepOutput;
    public String stepStateJson;
    public String rawWorkflowInputJson;
    public Integer workflowVersion; // New field
}
```

During step execution, the engine populates `workflowVersion` from `instance.Definition_Version__c`. This allows individual step classes (both forward and compensation steps) to run version-specific logic directly:

```java
public StepResult execute(StepContext ctx) {
    if (ctx.workflowVersion >= 2) {
        // Version 2+ logic
    } else {
        // Legacy version 1 logic
    }
    return StepResult.complete(null, output);
}
```

```mermaid
graph TD
    Start([Start Workflow]) --> CheckInterface{Implements VersionedWorkflow?}
    CheckInterface -- Yes -- GetVersion[Call getLatestVersion]
    CheckInterface -- No -- DefaultVersion[Default to Version 1]
    
    GetVersion --> SaveInstance[Save to Definition_Version__c]
    DefaultVersion --> SaveInstance
    
    SaveInstance --> ExecStep[Execute Step: ctx.workflowVersion injected]
    ExecStep --> CompleteStep[Step Completes]
    
    CompleteStep --> RouteInterface{Implements VersionedWorkflow?}
    RouteInterface -- Yes -- NextStep3[Call getNextStep with version]
    RouteInterface -- No -- NextStep2[Call legacy getNextStep]
```
