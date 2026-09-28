# Rate Limiting: Durable Back-off

`RateLimiter` is a token bucket for each integration key. Use it to keep
outbound calls to an external API (Stripe, Slack, a REST limit) at or below a
quota across all workflow instances.

Reference: [ThrottledCalloutWorkflowExample](../examples/main/default/classes/ThrottledCalloutWorkflowExample.cls)
and its [test](../examples/main/default/classes/ThrottledCalloutWorkflowExampleTest.cls).

## Contract

1. **Empty bucket → durable sleep, not failure.** When
   `RateLimiter.acquire(key).isAllowed` is false, return
   `StepResult.sleep(result.sleepDurationSeconds)`. The instance suspends and
   the engine runs the step again after the sleep.
2. **Callout → `idempotencyKey`.** Send `ctx.idempotencyKey` to the API (for
   example, as the `Idempotency-Key` header). A step can run more than one time.
   The key is the same on each run of one step visit, so the API applies one
   effect.
3. **HTTP 429 → durable sleep.** When the API says "too many requests", return
   `StepResult.sleep` for the `Retry-After` time. Do not fail the step.
4. **Two steps.** `acquire()` does DML. Apex blocks a callout after DML in the
   same transaction. Take the token in one step. Call the API in the next step.
   The engine runs each step in a new transaction.

```apex
// Step 1: take a token.
RateLimiter.AcquireResult token = RateLimiter.acquire('ThrottledService');
if (!token.isAllowed) {
  return StepResult.sleep(token.sleepDurationSeconds);
}
return StepResult.complete('MyWorkflow.CalloutStep', null);

// Step 2 (implements CalloutStep): call the API.
req.setHeader('Idempotency-Key', ctx.idempotencyKey);
HttpResponse res = new Http().send(req);
if (res.getStatusCode() == 429) {
  return StepResult.sleep(retryAfterSeconds(res));
}
```

## Do Not

| Do not | Result |
| --- | --- |
| Throw or return `StepResult.fail` when throttled. | The saga rolls back. |
| Loop on `acquire()` until it returns true. | CPU limit. No real wait. |
| Take the token and call out in one step. | `CalloutException`: uncommitted work pending. |
| Make a new key on each run (time, random). | Two effects after a resume. |

## Setup

1. Create a `Rate_Limit_Config__mdt` record. `DeveloperName` is the integration
   key. Set `Capacity__c` (at least 1) and `Refill_Rate_Per_Second__c` (more
   than 0). Example: 10 calls in 60 s is capacity 10, refill 0.1667.
2. Copy the two steps. Change the key, the endpoint, and the body.
3. In production, use a Named Credential for the endpoint.

A missing or bad config makes `acquire()` throw. That is a setup error, not a
throttle.

## Notes

- A `RetryPolicy` retry, an HTTP 429 resume, or an operator re-drive runs the
  callout step again without a new token. The back-off delay limits these
  calls. To take a token for each call, route the callout step back to the
  acquire step.
- The sleep time from `acquire()` has 0.5 to 1.5 s of jitter. Many instances
  do not wake at the same time.
- The **Rate Limits** panel in System Doctor shows the live bucket for each key.

## Test It

- Set `RateLimiter.mockConfigs` for the key. No CMDT deploy is necessary.
- Insert a `Rate_Limit_State__c` row with `Tokens_Remaining__c = 0` to make the
  bucket empty.
- Move `Last_Refill_Time_Ms__c` back to refill the bucket.
- Replace the HTTP transport with a fake. Harness tests do DML, and Apex blocks
  a real callout after DML.
- Drive with `WorkflowTestHarness`. Set `disableAutoTimeSkip = true` to stop at
  the sleep. Use `fireSleep(stepName)` to wake it.
