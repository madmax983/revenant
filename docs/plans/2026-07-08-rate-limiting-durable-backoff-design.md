# Rate Limiting Durable Back-off Design

## 1. Brainstorming: Goals & Requirements

The primary goal is to provide a clear, copy-pasteable reference example of how to combine `RateLimiter` and `StepResult.sleep` to achieve a durable back-off.

### Key Requirements
- **Example Class**: `ThrottledCalloutWorkflowExample.cls`
- **TDD Test Class**: `ThrottledCalloutWorkflowExampleTest.cls`
- **Callout Pattern**: Must use `StepContext.idempotencyKey` for the outbound callout.
- **Throttling Contract**:
  - Check `RateLimiter.acquire(integrationKey)`.
  - If allowed: perform callout (effective-once).
  - If denied: return `StepResult.sleep(sleepDurationSeconds)`.
  - Never throw exceptions on throttle or fail the step permanently.
- **Test Verifications**:
  1. A step blocked by an empty bucket suspends with a sleep wake-marker.
  2. It resumes and completes once a token is available.
  3. The workflow reaches `Completed` (not `Failed` or `Compensated`).

---

## 2. Reverse Brainstorming: How to Fail?

To ensure a robust design, we ask: **"How can we design the worst possible rate-limited workflow step?"**

1. **Busy-Loop / Spin-Lock**:
   - *Failure*: Instead of using `StepResult.sleep()`, the step loops in a `while` loop calling `RateLimiter.acquire()` until it succeeds.
   - *Result*: Exhausts the Salesforce transaction CPU limit (10 seconds) instantly and crashes.
   - *Remedy*: Return `StepResult.sleep(sleepDuration)` to yield control back to the engine.

2. **Roll Back the Entire Saga on Throttling**:
   - *Failure*: Throw a custom `RateLimitExceededException` or return `StepResult.fail()`.
   - *Result*: Triggers saga rollback and starts compensating completed steps, when it should just pause and retry.
   - *Remedy*: Use `StepResult.sleep()` which is a non-failure suspend action.

3. **Double Callout on Resume**:
   - *Failure*: The step makes a callout, but fails to serialize completion or is retried due to a transient error, and on re-execution generates a new random token or timestamp.
   - *Result*: Duplicate API side-effects (e.g. double charging).
   - *Remedy*: Use `StepContext.idempotencyKey` to ensure the callout is deduplicated by the external API.

4. **Locking the Token Bucket Forever**:
   - *Failure*: Hold transaction lock (`FOR UPDATE`) across a long external HTTP callout.
   - *Result*: Blocks all other concurrent instances trying to throttle, leading to lock timeout failures.
   - *Remedy*: In Apex, callouts cannot be made while there are pending uncommitted DML operations or active locks. More importantly, `RateLimiter.acquire()` commits (releases the lock) before the callout. The example must show `acquire()` first, and then the callout.

---

## 3. Six Hats Thinking

### ⚪ White Hat (Facts & Constraints)
- `RateLimiter.acquire(key)` returns `AcquireResult` carrying `isAllowed` and `sleepDurationSeconds`.
- `RateLimiter` queries `Rate_Limit_Config__mdt` custom metadata. If missing, it throws an exception.
- Tests can mock the metadata configs using `RateLimiter.mockConfigs.put(key, config)`.
- `StepResult.sleep(seconds)` suspends the workflow instance and schedules a resume.
- `WorkflowTestHarness.drive()` executes the workflow to yield/sleep points and can simulate clock progression.

### 🔴 Red Hat (Intuition & Gut Checks)
- Authors might feel that sleeping for a few seconds is "slow" and be tempted to busy-wait. We must explain clearly in the docs why busy-waiting is a disaster in Apex.
- Testing asynchronous sleep transitions can feel intimidating. The test example must be extremely clear and easy to follow so authors aren't discouraged from writing tests.

### ⚫ Black Hat (Risks & Mitigations)
- **Risk**: The sleep duration returned by `RateLimiter` includes random jitter (0.5 to 1.5 seconds) on top of the calculated wait time. In tests, driving the harness through multiple sleeps could take time or fail if the test clock doesn't align.
- **Mitigation**: We will configure the mock `Rate_Limit_Config__mdt` in the test with high refill rate and capacity so it refills fast, or manipulate/mock timestamps if needed, or drive it using `WorkflowTestHarness` which handles sleep resume.

### 🟡 Yellow Hat (Benefits & Optimism)
- Providing this canonical composition turns a complex orchestration problem into a simple copy-paste pattern.
- Having a robust integration test using `WorkflowTestHarness` will validate that the engine's sleep/resume loop works flawlessly with rate limits.

### 🟢 Green Hat (Creativity & Alternatives)
- Could we pass the integration key dynamically from the workflow input? Yes, `ctx.workflowInputJson` can carry it. We will show this in the example for maximum flexibility.

### 🔵 Blue Hat (Process & Strategy)
- We will write a failing test first (Red phase) asserting the throttling behavior.
- We will implement the example to pass the test (Green phase).
- We will refactor to clean up name-spacing, mock configs, and verify documentation (Refactor phase).
