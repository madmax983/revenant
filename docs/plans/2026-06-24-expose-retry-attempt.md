# Expose Retry Attempt Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Expose the 1-based current attempt number (`attempt`) and effective maximum attempts (`maxAttempts`) via `StepContext` to allow steps to inspect retry state and route to fallbacks on their final attempt.

**Architecture:** 
1. Define a new optional interface `RetryConfigurable` that steps can implement to define their `RetryPolicy` statically.
2. Extend `StepContext` to expose `attempt`, `maxAttempts`, and `isFinalAttempt()`.
3. In `WorkflowEngine`, resolve the `attempt` number (from `Retry_Count__c + 1`) and `maxAttempts` (first check `RetryConfigurable` interface on the step instance, then check a reserved key `__maxAttempts` in `Captured_Values__c` from previous retries, otherwise default to `1`).
4. In `WorkflowEngine` retry logic, store the resolved policy's `maximumAttempts` in the step's `Captured_Values__c` under the key `__maxAttempts`.
5. In `StepContext.withCapturedValues`, parse and extract `__maxAttempts` from the JSON to set the context's `maxAttempts` property, then strip the key from the captured values map to keep the accessor clean.

**Tech Stack:** Apex (Salesforce DX project)

---

### Task 1: Create RetryConfigurable Interface

**Files:**
- Create: [RetryConfigurable.cls](file:///c:/Users/markm/revenant/force-app/main/default/classes/RetryConfigurable.cls)
- Create: [RetryConfigurable.cls-meta.xml](file:///c:/Users/markm/revenant/force-app/main/default/classes/RetryConfigurable.cls-meta.xml)

**Step 1: Write the RetryConfigurable interface**
```java
public interface RetryConfigurable {
  RetryPolicy getRetryPolicy();
}
```

**Step 2: Run tests to verify the project still compiles**
Run: `sf apex run test -n StepContextTest --wait 5 -c -r human`
Expected: PASS (no compiling issues)

---

### Task 2: Modify StepContext to Expose Attempt Properties

**Files:**
- Modify: [StepContext.cls](file:///c:/Users/markm/revenant/force-app/main/default/classes/StepContext.cls)

**Step 1: Add properties and helper method**
```java
  public Integer attempt { get; private set; }
  public Integer maxAttempts { get; private set; }

  public Boolean isFinalAttempt() {
    return this.attempt >= this.maxAttempts;
  }
```

**Step 2: Initialize default values in StepContext constructor chain**
Default `attempt = 1` and `maxAttempts = 1` in all constructors, but allow passing them or setting them via overloaded factory methods.

**Step 3: Modify withCapturedValues factory methods**
Extract `__maxAttempts` if present, assign it to `maxAttempts`, then remove it from the map.
Support overloading to accept explicit `attempt` and `maxAttempts`.

**Step 4: Verify tests pass**
Run: `sf apex run test -n StepContextTest --wait 5 -c -r human`
Expected: PASS

---

### Task 3: Plumb Attempt and MaxAttempts in WorkflowEngine

**Files:**
- Modify: [WorkflowEngine.cls](file:///c:/Users/markm/revenant/force-app/main/default/classes/WorkflowEngine.cls)

**Step 1: Resolve attempt and maxAttempts before instantiating StepContext**
In both forward execute (around L2705) and backward compensate (around L6229):
```java
    Integer attempt = stepExec.Retry_Count__c != null ? (Integer) stepExec.Retry_Count__c + 1 : 1;
    Integer maxAttempts = 1;
    if (stepInstance instanceof RetryConfigurable) {
      RetryPolicy policy = ((RetryConfigurable) stepInstance).getRetryPolicy();
      if (policy != null && policy.maximumAttempts != null) {
        maxAttempts = policy.maximumAttempts;
      }
    } else if (String.isNotBlank(stepExec.Captured_Values__c)) {
      String resolvedCaptures = resolvePayload(stepExec.Captured_Values__c);
      if (String.isNotBlank(resolvedCaptures)) {
        Map<String, Object> captures = (Map<String, Object>) JSON.deserializeUntyped(resolvedCaptures);
        if (captures.containsKey('__maxAttempts')) {
          maxAttempts = (Integer) captures.get('__maxAttempts');
        }
      }
    }
```
Pass these into the constructor or set them on the context.

**Step 2: Save policy.maximumAttempts to Captured_Values__c on RETRY**
In `handleStepResult` and `handleCompensationResult`:
```java
      Map<String, Object> captures = new Map<String, Object>();
      if (String.isNotBlank(stepExec.Captured_Values__c)) {
        captures = (Map<String, Object>) JSON.deserializeUntyped(resolvePayload(stepExec.Captured_Values__c));
      }
      captures.put('__maxAttempts', policy.maximumAttempts);
      stepExec.Captured_Values__c = savePayloadIfNeeded(
        instance.Id,
        JSON.serialize(captures),
        'Captures_' + stepExec.Step_Name__c.replaceAll('[^a-zA-Z0-9]', '_')
      );
```

**Step 3: Verify tests pass**
Run: `sf apex run test -n StepContextTest --wait 5 -c -r human`
Expected: PASS

---

### Task 4: Add TDD Tests for Retry Expose and Fallback

**Files:**
- Modify: [StepContextTest.cls](file:///c:/Users/markm/revenant/force-app/main/default/classes/StepContextTest.cls)
- Modify: [WorkflowEngineTest.cls](file:///c:/Users/markm/revenant/force-app/main/default/classes/WorkflowEngineTest.cls)

**Step 1: Write unit tests in StepContextTest**
Assert that context correctly sets/parses `attempt`, `maxAttempts`, and `isFinalAttempt()`.

**Step 2: Write integration tests in WorkflowEngineTest**
1. Test progression of `attempt` across retries for both forward execute and backward compensate.
2. Test reset of `attempt` on fresh visits (e.g. looping).
3. Test agreement with the persisted/operator-visible `Retry_Count__c`.
4. Test a reference example of last-attempt fallback using `isFinalAttempt()` with **zero** author-maintained state.

**Step 3: Run all tests and ensure 100% pass**
Run: `sf apex run test --wait 5 -c -r human`
Expected: PASS
