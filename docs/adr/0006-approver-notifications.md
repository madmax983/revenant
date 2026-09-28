# ADR 0006: Approver notifications

- **Status:** Accepted
- **Date:** 2026-09-28
- **Issue:** #123

## Context

A step that waits for a human signal tells nobody. The author must write a notifier. `Messaging.CustomNotification.send()` in the SUSPEND transaction does not wait for the commit. A rollback and a re-run can send two notifications. A send error can fail the SUSPEND.

## Decision

1. Author API: `StepResult.withNotification(WorkflowNotification)` on a SUSPEND or WAIT_FOR_APPROVAL result. `WorkflowNotification` has static, input-key and record-owner recipients, a target and a type. A second call on the same result throws.
2. Dedup anchor: one `Workflow_Log__c` row, key `Notify:<stepExecId>` in the unique `Fire_Key__c`. Insert with `allOrNone = false`. A logical suspend is one step row.
3. Transport: one `NOTIFY` `Workflow_Event__e` (`PublishAfterCommit`) with only the key, published only when the anchor insert succeeds. A separate trigger, `WorkflowNotifyTrigger`, sends in its own transaction. The engine trigger ignores `NOTIFY`. Engine work cannot use the notify budget, and a notify error cannot fail engine work.
4. The notify call is the last call in the SUSPEND and WAIT_FOR_APPROVAL handlers. It checks the DML budget and catches all errors.
5. Resolve input keys at the SUSPEND (decoded input, in memory). Resolve record owners in the trigger.
6. The trigger reads the request from the `Requested` anchor row, not from the event. A replay, a copy or a forged event sends nothing. It makes max 10 send calls in a pass (the Apex limit for notification calls) and publishes the rest again. It sends only to user and group Ids. It updates each row to `Sent`, `Failed` or `Skipped`.
7. Toggle: `Revenant_Config__mdt.Send_Notifications__c` (default on). Ship `CustomNotificationType` `Revenant_Workflow_Notification`.

## Consequences

- No new object. No new field on `Workflow_Instance__c` or `Workflow_Step_Execution__c`. No change to the Queueable hand-off or the compensation stack.
- An opted-in SUSPEND uses maximum 3 DML statements and 0 SOQL.
- A step that waits again on the same row with a new notification does not send it. A second notification needs a new step.
- One `Workflow_Log__c` row for each logical suspend. It is also the audit row. `CleanupWorkflow` does not delete `Workflow_Log__c` rows. When it deletes the instance, the row stays with a blank instance lookup.
- The Automated Process user sends the notification, unless a `PlatformEventSubscriberConfig` for `WorkflowNotifyTrigger` sets a user.
- The notify trigger also receives each engine event. It ignores them. The cost is one loop over the batch.
- Tests cannot see delivery. Test context records each send call.

## Rejected Options

- Send in the SUSPEND transaction: the send does not wait for the commit.
- A new `Workflow_Notification__e`: a new object. `Workflow_Event__e` can do this work.
- A Queueable that sends: a Queueable can enqueue only one child job. It can block the hand-off.
- A marker in `Workflow_Step_Execution__c.Output__c`: `suspend()` keeps encoded author state there.
- A checkbox on `Workflow_Step_Execution__c`: a new data field.
- Notify on SLEEP, YIELD and START_CHILD: no human waits there.
- The request in the event payload: a user with publish access can forge it. The anchor row is written only by the engine.
- Send in the engine trigger transaction: engine work can use the query and DML budget first. This caused many budget edge cases in review.
- A `ctx.notifications()` accessor, as `ctx.events()`: the notification belongs to one suspend, not to the step run.
- The approval key in the fire key: a plain `suspend()` has no key. Keep one rule: one step row, one notification.
