# ADR 0006: Approver notifications

- **Status:** Accepted
- **Date:** 2026-09-28
- **Issue:** #123

## Context

A step that waits for a human signal tells nobody. The author must write a notifier. `Messaging.CustomNotification.send()` in the SUSPEND transaction is not coupled to the commit. A rollback and a re-run can send two notifications. A send error can fail the SUSPEND.

## Decision

1. Author API: `StepResult.withNotification(WorkflowNotification)` on a SUSPEND or WAIT_FOR_APPROVAL result. `WorkflowNotification` has static, input-key and record-owner recipients, a target and a type.
2. Dedup anchor: one `Workflow_Log__c` row, key `Notify:<stepExecId>` in the unique `Fire_Key__c`. Insert with `allOrNone = false`. A logical suspend is one step row.
3. Transport: one `NOTIFY` `Workflow_Event__e` (`PublishAfterCommit`), published only when the anchor insert succeeds. The existing event trigger sends the notification in a new transaction.
4. The notify call is the last call in the SUSPEND and WAIT_FOR_APPROVAL handlers. It checks the DML budget and catches all errors.
5. Resolve input keys at the SUSPEND (decoded input, in memory). Resolve record owners in the trigger.
6. The trigger sets the anchor row to `Sent`, `Failed` or `Skipped` with one upsert on `Fire_Key__c`.
7. Toggle: `Revenant_Config__mdt.Send_Notifications__c` (default on). Ship `CustomNotificationType` `Revenant_Workflow_Notification`.

## Consequences

- No new object. No new field on `Workflow_Instance__c` or `Workflow_Step_Execution__c`. No change to the Queueable hand-off or the compensation stack.
- An opted-in SUSPEND uses max 3 DML statements and 0 SOQL.
- One `Workflow_Log__c` row for each logical suspend. It is also the audit row. `CleanupWorkflow` does not delete `Workflow_Log__c` rows. When it deletes the instance, the row stays with a blank instance lookup.
- The Automated Process user sends the notification, unless a `PlatformEventSubscriberConfig` sets a user.
- Tests cannot see delivery. Test context records each send call.

## Rejected Options

- Send in the SUSPEND transaction: not coupled to the commit.
- A new `Workflow_Notification__e`: a new object. `Workflow_Event__e` is sufficient.
- A Queueable that sends: a Queueable can enqueue only one child job. It can block the hand-off.
- A marker in `Workflow_Step_Execution__c.Output__c`: `suspend()` keeps encoded author state there.
- A checkbox on `Workflow_Step_Execution__c`: a new data field.
- Notify on SLEEP, YIELD and START_CHILD: no human waits there.
