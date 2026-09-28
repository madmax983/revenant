# Rate Limiting: Durable Back-off

`RateLimiter` is a token bucket for each integration key. Use it to keep
outbound calls to an external API (for example, Stripe or Slack) below a quota
across all workflow instances.

Reference: [ThrottledCalloutWorkflowExample](../examples/main/default/classes/ThrottledCalloutWorkflowExample.cls)
and its [test](../examples/main/default/classes/ThrottledCalloutWorkflowExampleTest.cls).

Distinct from `Concurrency_Config__mdt` ([in-flight count](concurrency-limits.md))
and the [circuit breaker](circuit-breaker.md) (dependency health).

## Contract

1. **Empty bucket → durable sleep, not failure.** When
   `RateLimiter.acquire(key).isAllowed` is false, return
   `StepResult.sleep(token.sleepDurationSeconds)`. The instance suspends. The
   engine runs the step again after the sleep.
2. **Callout → `idempotencyKey`.** Send `ctx.idempotencyKey` to the API (for
   example, as the `Idempotency-Key` header). A step visit starts when the
   workflow moves to the step. A sleep, a retry, or a re-drive does not start a
   new visit. The key is the same for all runs in one visit, so the API
   applies one effect. Send the same body on each run.
3. **HTTP 429 → durable sleep.** When the API returns HTTP 429 (Too Many
   Requests), return `StepResult.sleep` for the `Retry-After` time. Do not
   fail the step.
4. **Unknown result → retry with the same key.** A thrown `CalloutException`
   (for example, a timeout) or HTTP 408, 409, or 5xx does not tell you if the
   API applied the effect. Retry the step. The key does not change.
5. **Two steps.** `acquire()` does DML. Apex blocks a callout after DML in the
   same transaction. Take the token in one step. Call the API in the next step.
   The engine runs each step in a new transaction. The callout step must
   implement `CalloutStep`. Without it, the engine can do DML before
   `execute()`, and the callout fails.

```apex
// Step 1: take a token.
RateLimiter.AcquireResult token = RateLimiter.acquire('ThrottledService');
if (!token.isAllowed) {
  return StepResult.sleep(token.sleepDurationSeconds);
}
return StepResult.complete(null, null); // getNextStep() routes to step 2.

// Step 2 (implements CalloutStep, AutoRetryConfigurable): call the API.
req.setHeader('Idempotency-Key', ctx.idempotencyKey);
HttpResponse res = transport.send(req);
if (res.getStatusCode() == 429) {
  return StepResult.sleep(retryAfterSeconds(res));
}
```

## Do Not

| Do not                                            | Result                                        |
| ------------------------------------------------- | --------------------------------------------- |
| Throw or return `StepResult.fail` when throttled. | The saga rolls back.                          |
| Loop on `acquire()` until it returns true.        | CPU limit. No real wait.                      |
| Take the token and call out in one step.          | `CalloutException`: uncommitted work pending. |
| Make a new key on each run (time, random).        | Two effects after a resume.                   |
| Fail on a timeout or HTTP 5xx.                    | Rollback, but the remote effect can stay.     |
| Make the callout step `CircuitBreakerGuarded`.    | The gate can do DML before the callout.       |

## Setup

1. Create a `Rate_Limit_Config__mdt` record. `DeveloperName` is the
   integration key. Set `Capacity__c` (1 or more) and
   `Refill_Rate_Per_Second__c` (more than 0).
2. Calculate the values from the quota. In a window of `t` seconds, the bucket
   admits up to `Capacity__c + Refill_Rate_Per_Second__c × t` calls. Example:
   for at most 10 calls in any 60 s, use capacity 5 and refill 0.0833
   (5 + 0.0833 × 60 = 10). Keep a margin below the real quota.
3. Copy `ThrottledCalloutWorkflowExample`. Rename the class. Change
   `INTEGRATION_KEY`, `ENDPOINT`, and the request body.
4. Give the org access to the endpoint. Use a Named Credential in production.
   The example uses the `HttpBin` Remote Site Setting.

If the config is missing or not valid, `acquire()` throws a
`WorkflowException`. This is a setup error, not a throttle.

## Limits

- The bucket controls admissions to the callout step, not calls. A 429
  resume, a retry, or an operator re-drive calls the API again without a new
  token. To take a token for each call, make `getNextStep()` return the
  acquire step after the callout step. A loop starts a new step visit, so the
  callout gets a new key. Use a loop only when the API applied no effect.
- The example fails the step when the API still returns HTTP 429
  `MAX_REMOTE_THROTTLE_SECONDS` (24 h) after the first 429. It keeps the time
  of the first 429 with `ctx.captures().once()`, because a retry clears the
  step state. A daily quota or a bad endpoint does not loop forever. An
  operator re-drive keeps the time too, so after a re-drive, a new 429 fails
  the step at once.
- When the bucket is empty, `acquire()` gives each waiter the time to the next
  token, plus 0.5 to 1.5 s. Many waiters wake at almost the same time. One
  gets the token and the others sleep again. For a large backlog, this uses
  many async jobs. A long sleep uses a scheduled job or the watchdog.
- `acquire()` locks one `Rate_Limit_State__c` row for each key until the
  acquire step commits. Keep the acquire step short. A very large backlog can
  get lock errors. The engine retries them, but a long lock wait can fail the
  instance.
- The **Rate Limits** panel in System Doctor shows the live bucket for each
  key.

## Test It

- Set `RateLimiter.mockConfigs` for the key. You do not have to deploy CMDT.
- Insert a `Rate_Limit_State__c` row with `Tokens_Remaining__c = 0` to make
  the bucket empty.
- Move `Last_Refill_Time_Ms__c` back to refill the bucket.
- Replace the HTTP transport with a fake (`MockThrottledApi`). Harness tests
  do DML, and Apex blocks a real callout after DML.
- Drive with `WorkflowTestHarness`. Set `disableAutoTimeSkip = true` to stop
  at the sleep. Use `fireSleep(stepName)` to wake it.
