# Stuck Instance Alert (Issue #139)

## Goal

Send one email when a non-terminal instance makes no forward progress for
longer than a threshold. The operator sets the threshold in Setup.

## Facts About The Engine

- `Workflow_Alert_Config__mdt.Stall_Threshold_Minutes__c` exists. Blank
  disables stall alerts.
- `WorkflowStallDetector` runs in the heartbeat (step 7 of
  `WorkflowHeartbeatService`). It adds no scheduled job.
- The detector skips each `Suspended` instance that has a `Pending` step.
  Each signal, child, approval and sleep wait writes a `Pending` step. Thus
  the detector never finds a hung-child parent, a lost signal or a lost
  approval. These are the main cases of the issue.
- The detector resolves config only in the active stall configs. A
  per-definition record with `Enable_Alerts__c = false` or a blank threshold
  falls back to `Default`. Failure alerts do not do this.
- The email does not show the current step.
- The dedup marker is a `Workflow_Log__c` row with no unique key. Two
  sweeps at the same time can both send.
- One `Messaging.sendEmail` call has no budget guard. Over the email limit,
  the platform throws an error that the heartbeat cannot catch.
- The query takes the 1000 oldest candidates. Instances that make progress
  fill the window. A new stall can wait for many sweeps.
- `Workflow_Log__c.Fire_Key__c` is unique. An insert gives an atomic claim
  (the #113 and #126 pattern).

## Brainstorming (options)

| #   | Idea                                                                      | Keep?                                                                |
| --- | ------------------------------------------------------------------------- | -------------------------------------------------------------------- |
| B1  | Add a new field `Stuck_Threshold_Minutes__c`.                             | No. `Stall_Threshold_Minutes__c` does the same thing. No new schema. |
| B2  | Include suspended waits (signal, child, approval).                        | Yes. The issue names these cases.                                    |
| B3  | Skip an instance with a future `Sleep_Until__c`.                          | Yes. The engine holds a timer. It is not stuck.                      |
| B4  | Start the clock at a past `Sleep_Until__c` if it is after the last step.  | Yes. A wait for the wake time is not a stall.                        |
| B5  | Resolve config as failure alerts do: the name match wins, then `Default`. | Yes. The acceptance criteria give this convention.                   |
| B6  | Claim each stall with a unique key: `Stall:<instanceId>:<clockMillis>`.   | Yes. One alert per stall, also under a race. New progress = new key. |
| B7  | Put a dedup field on `Workflow_Instance__c`.                              | No. A write locks the row and races the chain.                       |
| B8  | Use `Terminal_At__c` as the marker.                                       | No. The acceptance criteria forbid it.                               |
| B9  | Anti-join on steps newer than the smallest threshold.                     | Yes. The query returns only idle instances. 1 SOQL.                  |
| B10 | Sort candidates by `LastModifiedDate DESC`.                               | Yes. A new stall comes before an old stall that has an alert.        |
| B11 | Cap alerts per sweep (100).                                               | Yes. The next sweep sends the rest.                                  |
| B12 | Delete the claim when no channel sends.                                   | Yes. The next sweep tries again.                                     |
| B13 | Send one digest email for each recipient list.                            | No. The acceptance criteria ask for one email per instance.          |
| B14 | Include `Held`, `Paused`, `DefinitionChanged`, `CompensationFailed`.      | No. An operator parked these, or a failure alert covers them.        |
| B15 | Add Slack or webhook channels.                                            | No. Out of scope. `Workflow_Alert__e` already exists.                |

## Reverse Brainstorming (how to make it fail)

| How to fail                                      | Counter                                                            |
| ------------------------------------------------ | ------------------------------------------------------------------ |
| Page on each sweep for the same stall.           | Unique claim key. Skip when the last stall row is after the clock. |
| Never page for a lost signal.                    | Do not skip suspended waits (B2).                                  |
| Page for each long sleep.                        | Skip a future `Sleep_Until__c`. Start the clock at the wake time.  |
| Page for an instance that ended.                 | The query reads only active statuses.                              |
| Page when the definition record disables alerts. | The name match wins over `Default` (B5).                           |
| Write a step row.                                | No DML on steps. A test checks `SystemModstamp`.                   |
| Write `Terminal_At__c`.                          | No DML on instances. A test checks it.                             |
| Spend the heartbeat email or DML budget.         | Budget guard. Keep one email call and `DML_RESERVE` free.          |
| SOQL grows with the instance count.              | 1 candidate query with `LIMIT`. A test checks 1 and 20 rows.       |
| A new stall waits behind old stalls.             | Anti-join (B9) and sort (B10).                                     |
| Two sweeps send the same alert.                  | Unique `Fire_Key__c` insert. Only the winner sends.                |
| An error stops the heartbeat.                    | Catch all errors. The heartbeat also catches.                      |
| Keep a claim when the email fails.               | Delete the claim (B12).                                            |

## Six Thinking Hats

- **White (facts):** Cadence 1–10 min, default 10. 10 email calls per
  transaction. 150 DML statements. The query reads at most 1000 instances.
- **Red (feel):** Operators want one email per stall. An alert storm makes
  them ignore all alerts.
- **Black (risk):** Orgs that set a threshold now get alerts for long
  approval waits. Tell them in `MIGRATION.md`. Tell them to set a
  per-definition record for slow approvals. More than 1000 idle
  instances can delay a check. The sort puts new stalls first.
- **Yellow (value):** A wedged instance shows in one sweep. No new schema.
  No new job slot. No change to the chain.
- **Green (ideas):** Show the current step and the idle time in the email
  and in `Workflow_Alert__e.Error_Message__c`.
- **Blue (process):** Write the spec. Write failing tests. Make them pass.
  Clean up. Then do an agent review. Then map each acceptance criterion to
  evidence.

## Spec

Terms:

- Active status = `Pending`, `Running`, `Suspended`, `Compensating` or
  `Cancelling`.
- Clock = the later of the newest step `CreatedDate` (or the instance
  `CreatedDate` when no step exists) and a past `Sleep_Until__c`.
- Config = the record for the workflow `DeveloperName`, else `Default`.

Rules. The detector sends a stall alert only when all are true:

1. The status is active. The definition is not paused. The instance is not
   an engine workflow. The sweep did not resume it in this transaction.
2. `Sleep_Until__c` is blank or in the past (or the status is not
   `Suspended`).
3. The config has `Enable_Alerts__c = true` and a threshold > 0.
4. now − clock ≥ threshold.
5. No stall row for this instance has a `CreatedDate` at or after the clock.
6. The insert of the claim row `Stall:<instanceId>:<clockMillis>` succeeds.

Invariants:

- The detector writes only `Workflow_Log__c` rows. It never writes step or
  instance rows.
- One stall (instance + clock) sends at most one alert.
- A claim stays only when a channel sent the alert, or when the config has
  no channel.
- SOQL does not grow with the instance count.

## Test Plan (RED)

`WorkflowStallDetectorTest`:

1. A suspended signal wait past the threshold sends one alert.
2. The email shows the definition, instance, current step, status and idle
   time.
3. A definition record with `Enable_Alerts__c = false` blocks `Default`.
4. A definition record with a blank threshold blocks `Default`.
5. A blank threshold in all records sends nothing and writes nothing.
6. A terminal instance sends nothing. `Terminal_At__c` stays blank.
7. The detector does not change step rows.
8. The claim row has the key. A second sweep sends nothing.
9. A claim that another sweep holds blocks the alert.
10. A failed email deletes the claim. The next sweep sends.
11. The clock starts at a past `Sleep_Until__c`.
12. SOQL is the same for 1 and 20 stalled instances.
13. The cap sends the rest in the next sweep.
14. An instance with a recent step sends nothing.
