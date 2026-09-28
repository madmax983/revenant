# ADR 0003: Operator Retry Policy Through Custom Metadata

- **Status:** Accepted
- **Date:** 2026-09-28
- **Issue:** #103

## Context

A `RetryPolicy` is Apex code. To change retry pacing or the attempt limit
during an incident, an operator must deploy code.

## Decision

1. Add `Workflow_Retry_Config__mdt`. Text fields `Workflow_Definition__c` and
   `Step_Name__c` give the match key. `DeveloperName` is too short (40
   characters) for a workflow name and a step name.
2. Resolution: start with the author policy, else the engine default. With
   no author policy, put the most specific record over it. Then put the most
   specific override record over the result. "Most specific" is the step
   record, else the definition record. The match ignores case and outer
   spaces. For a duplicate key, the lowest `DeveloperName` wins.
3. `Override_Author_Policy__c` (default `false`) has priority over an author
   policy and over a record without override. So a definition override
   record caps each step during an incident.
4. Add `RetryPolicy.fromConfig()` to mean "no author policy". Its values
   are the start value. `StepResult.retry(...)` does not change.
5. The engine ignores a blank or bad record field. The resolver always
   sanitizes the result.
6. `WorkflowRetryConfigResolver` reads `getAll()` (0 SOQL) and does no DML.
   The forward and compensation retry outcomes call it. The step and
   compensation context builders call it for `ctx.isFinalAttempt()`.

## Consequences

- An org with no records keeps its current behavior.
- `RetryPolicy` gets two public members: `fromConfig()` and `isFromConfig()`.
  The issue asks for no public API change. AC 2 needs a signal for "no author
  policy", because `StepResult.retry(null)` fails. This is the smallest
  additive signal. It needs the sign-off of the issue owner.
- Apex tests ignore org records by default. An incident record cannot block
  a deploy.
- The retry delay is capped at 86400 s before the Integer cast. A large
  interval or backoff cannot overflow.
- A new cap below the current retry count fails the step at its next retry
  outcome. This is the wanted incident result.
- A retry job that is already scheduled keeps its delay.
- For `ctx.isFinalAttempt()`, a `RetryConfigurable` step that returns `null`
  now uses a matching record. Before, it used the engine default. With no
  record, the result is the same.

## Rejected Options

- **No-argument `StepResult.retry()`:** `StepResult` then has 20 public
  members (PMD `ExcessivePublicCount`). The issue also keeps the
  `StepResult.retry(...)` surface.
- **Treat `new RetryPolicy()` as no author policy:** cannot tell it from an
  author who wants the defaults.
- **Merge the step record and the definition record field by field:** harder
  to explain. The issue asks for "most specific record wins".
- **SOQL on the CMDT:** uses the query limit in the retry path.
