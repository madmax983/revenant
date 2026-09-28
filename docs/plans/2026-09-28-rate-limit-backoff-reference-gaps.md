# Rate-Limit Back-off Reference: Gap Closure (#106)

## Status

PR #189 added `ThrottledCalloutWorkflowExample`. This plan closes the gaps between
that example and the acceptance criteria (AC) of #106.

## Gaps Found

| AC     | Gap                                                                                                                                                       |
| ------ | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1      | The "callout" is a static counter. It is not an HTTP request. Authors cannot copy it.                                                                     |
| 2      | No test has a compensation stack. No test proves that a throttle does not roll back a saga.                                                               |
| 3      | No test runs the callout step two times. The test cannot fail if the key is wrong.                                                                        |
| 4a     | The test does not check the wake marker (`Sleep_Until__c`).                                                                                               |
| 4c     | The test does not check for zero compensations or zero failed rows.                                                                                       |
| 5      | The README entry does not give the full contract. Fix: the README states the contract and links `docs/rate-limiting.md`, which gives the rules as a list. |
| Metric | No test shows a bucket cap across many instances.                                                                                                         |

## Brainstorming

- Send a real `HttpRequest` with an `Idempotency-Key` header.
- Put a small `Transport` seam in front of `Http.send`. Tests use a fake transport.
  Harness tests do DML, and Apex blocks a callout after DML.
- Let one fake class be both the `Transport` and the `HttpCalloutMock`.
- Treat HTTP 429 as a throttle too. Sleep for `Retry-After`. The callout step then
  runs again with the same key. This is the "sleep, resume, same key" case of AC 3.
- Add a test-only saga: a compensatable step, then the two example steps.
- Run the acquire step 20 times on a 3-token bucket. Expect 3 calls and 17 sleeps.
- Add `docs/rate-limiting.md` with the contract and the anti-patterns.

## Reverse Brainstorming (How To Make It Fail)

| Bad idea                          | Result                                    | Rule in the example           |
| --------------------------------- | ----------------------------------------- | ----------------------------- |
| Throw when the bucket is empty.   | The saga rolls back.                      | Return `StepResult.sleep`.    |
| Loop on `acquire()`.              | CPU limit. No real wait.                  | Return `StepResult.sleep`.    |
| Acquire and call out in one step. | `CalloutException`: uncommitted work.     | Two steps.                    |
| Make a new key on each run.       | Two charges after a resume.               | Send `ctx.idempotencyKey`.    |
| Fail on HTTP 429.                 | The saga rolls back on a remote throttle. | Sleep for `Retry-After`.      |
| Trust any `Retry-After` value.    | Parse error or a very long sleep.         | Use a default for bad values. |
| Call real HTTP in a harness test. | Test error: callout after DML.            | Fake transport.               |

## Six Thinking Hats

- **White (facts):** `acquire()` does DML. Apex blocks a callout after DML. The
  orchestrator runs one step for each Queueable. A sleep does not complete a step
  visit, so `idempotencyKey` stays the same on resume. `fireSleep` wakes a step.
- **Red (feeling):** A reader wants one short class and one clear test. Keep the
  step code short. Put the rules in the docs.
- **Black (risk):** This session has no scratch org, so the Apex tests did not
  run. Use only APIs that other tests use. Check syntax with Prettier. Run
  `sf apex run test -n ThrottledCalloutWorkflowExampleTest,PayloadCodecRoundTripTest -w 10`
  before merge.
  `PayloadCodecRoundTripTest` used the old static counters. It now uses the fake.
- **Yellow (value):** A copyable pattern for local and remote throttles. No engine
  change.
- **Green (ideas):** Take the key from the workflow input. Rejected: more code, no
  AC need.
- **Blue (process):** RED: tests and fake first. GREEN: example code. REFACTOR:
  docs, format, review.

## Scope

- In: example class, fake transport, tests, `PayloadCodecRoundTripTest` update, docs.
- Out: changes to `RateLimiter`, CMDT schema, engine, or public engine API.

## Review Changes

A review found more gaps. The example now also:

- Routes only through `getNextStep()`. The engine ignores the step name in
  `StepResult.complete`.
- Parses the HTTP-date form of `Retry-After`.
- Retries a timeout or HTTP 408, 409, or 5xx with the same key
  (`AutoRetryConfigurable`, `StepResult.retry`). Other 4xx codes fail.
- Fails when the API still returns HTTP 429 24 h after the first 429. The
  time of the first 429 is a capture (`once()`), because a retry clears the
  step state.

## Test Plan

| Test                                             | AC            |
| ------------------------------------------------ | ------------- |
| `emptyBucketSleepsThenCompletesAfterRefill`      | 1, 4a, 4b, 4c |
| `throttleNeverRollsBackTheSaga`                  | 2, 4c         |
| `remoteThrottleKeepsOneEffectAcrossSleepResume`  | 3             |
| `acquireStepSleepsWhenBucketIsEmpty`             | 1, 2          |
| `acquireStepRoutesToCalloutWhenTokenIsFree`      | 1             |
| `calloutSendsIdempotencyKeyHeader`               | 3             |
| `calloutRerunKeepsOneEffect`                     | 3             |
| `tooManyRequestsSleepsForRetryAfter`             | 2             |
| `badRetryAfterUsesDefaultOrCap`                  | 2             |
| `httpDateRetryAfterSleepsUntilThatTime`          | 2             |
| `tooManyRequestsBeforeTheDeadlineSleeps`         | 2             |
| `tooManyRequestsNearTheDeadlineSleepsOnlyToIt`   | contract      |
| `tooManyRequestsAfterTheDeadlineFailsTheStep`    | contract      |
| `retryBetweenThrottlesKeepsTheKeyAndTheDeadline` | 3             |
| `unknownResultRetriesWithTheSameKey`             | 3             |
| `clientErrorFailsTheStep`                        | contract      |
| `thrownCalloutExceptionHasAnAutoRetryPolicy`     | 3             |
| `httpTransportSendsTheRequest`                   | 1             |
| `bucketAdmitsCapacityThenSleepsTheRest`          | metric        |
