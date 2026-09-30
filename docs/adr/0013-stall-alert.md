# ADR 0013: Stall alert for a non-terminal instance

- **Status:** Accepted
- **Date:** 2026-09-30
- **Issue:** #139

## Context

An instance can stop and stay non-terminal. Failure alerts do not find it.
A stall detector existed, but it skipped each suspended instance with a
`Pending` step. Each signal, child, approval and sleep wait writes such a
step, so the main cases of the issue got no alert. Its config lookup used
`Default` when the matched record disabled stall alerts. Its dedup row had
no unique key, and its email call had no budget guard.

## Decision

1. Keep `Stall_Threshold_Minutes__c` as the threshold. Blank disables.
2. Include suspended waits. Skip only a suspended instance with a future
   `Sleep_Until__c`.
3. Clock = newest step `CreatedDate` (else instance `CreatedDate`). A later,
   past `Sleep_Until__c` moves the clock to the wake time.
4. Resolve config with the failure-alert rule. A matched record wins, also
   when it disables stall alerts.
5. Claim each stall with a `Workflow_Log__c` row and the unique key
   `Stall:<instanceId>:<clockMillis>`. Delete the claim when no channel
   sends.
6. One query with an anti-join on recent steps, sorted by
   `LastModifiedDate DESC`, `LIMIT 1000`. At most 100 alerts per sweep.
7. One email call per sweep with per-email results. Budget guard as in
   ADR 0008.

## Consequences

- No new schema and no new scheduled job.
- Orgs with a threshold now get alerts for long approval and signal waits.
  `MIGRATION.md` tells them to set a per-definition record.
- The detector does 1 query when a threshold is set, and 0 when none is.
- It writes only `Workflow_Log__c` rows.

## Alternatives

- A new field `Stuck_Threshold_Minutes__c`. Rejected: the existing field
  does the same thing.
- A dedup field on `Workflow_Instance__c`. Rejected: a write locks the row
  and races the chain.
- `Terminal_At__c` as the marker. Rejected: the issue forbids it.
- One digest email for each recipient list. Rejected: the issue asks for
  one email per instance.
