# Notify Approvers When a Workflow Waits (Issue #123)

## Goal

When a step suspends to wait for a human signal, the engine sends a native Custom Notification (bell and mobile push) to the approver. The author does not write `Messaging.*` code.

## Facts About The Engine

- `StepResult.suspend()` and `StepResult.waitForApproval(key, role)` stop a step. `WorkflowStepSuspension` writes the SUSPEND. The step row changes to `Pending`. The instance changes to `Suspended`.
- On resume, the engine uses the same `Workflow_Step_Execution__c` row again (`WorkflowStepExecLock.buildOrReuseStepExec`). A new visit of the step writes a new row. Thus the row Id identifies one logical suspend.
- Each signal wakes a suspended instance. The step runs again. When its signal is not there, it suspends again on the same row.
- `Workflow_Event__e` is `PublishAfterCommit`. A rolled-back transaction publishes nothing. `WorkflowEventTriggerHandler` routes it by `Event_Type__c` in a new transaction (Automated Process user).
- `Workflow_Log__c.Fire_Key__c` is a unique external Id. `WorkflowStepHistoryGuard` uses it as a once-only anchor.
- `Messaging.CustomNotification.send(Set<String>)` takes max 500 recipients for each call. A recipient can be a user, group or queue Id. The type Id comes from `SELECT Id FROM CustomNotificationType WHERE DeveloperName = :name`.
- An Apex test cannot see a sent notification. A test cannot always query `CustomNotificationType`.

## Brainstorming (options)

| # | Idea | Keep? |
|---|------|-------|
| B1 | Call `Messaging.CustomNotification.send()` in the SUSPEND transaction. | No. It is not coupled to the commit. A rollback and a re-run can send two notifications. |
| B2 | Publish one `NOTIFY` `Workflow_Event__e` in the SUSPEND transaction. The event trigger sends the notification. | Yes. `PublishAfterCommit` couples the send to the SUSPEND commit. No new object. |
| B3 | New `Workflow_Notification__e` event. | No. A new object. B2 is sufficient. |
| B4 | Enqueue a Queueable that sends. | No. A Queueable can enqueue only one child job. It can block the orchestrator hand-off. |
| B5 | Dedup anchor: one `Workflow_Log__c` row, key `Notify:<stepExecId>` in `Fire_Key__c`. Insert with `allOrNone = false`. Publish only when the insert succeeds. | Yes. Atomic. No SOQL. The row rolls back with the SUSPEND. It is also the audit row. |
| B6 | Dedup marker in `Workflow_Step_Execution__c.Output__c`. | No. `suspend()` keeps encoded author state there. |
| B7 | New checkbox on `Workflow_Step_Execution__c`. | No. The issue forbids new fields on data objects. |
| B8 | Fluent `StepResult.withNotification(WorkflowNotification)` on SUSPEND and WAIT_FOR_APPROVAL results. | Yes. Same style as `withStepState` and `withApprovalTimeout`. |
| B9 | `WorkflowNotification` builder: `create(title, body)`, `toRecipient(Id)`, `toRecipients(Set<Id>)`, `toInputKey(key)`, `toRecordOwner(recordId)`, `withTarget(recordId)`, `withNotificationType(developerName)`. (`of` is an Apex reserved word.) | Yes. Static, input and record-owner recipients. |
| B10 | Resolve `toInputKey` at the SUSPEND from the decoded workflow input in memory. | Yes. No SOQL. The trigger does not see the decoded input. |
| B11 | Resolve `toRecordOwner` in the event trigger. | Yes. The SOQL is not on the SUSPEND path. |
| B12 | Default deep link: the workflow instance record. | Yes. `withTarget` sets an author record. |
| B13 | Ship `CustomNotificationType` `Revenant_Workflow_Notification` in `force-app`. | Yes. It is the default type. The example works with no setup. |
| B14 | Toggle `Revenant_Config__mdt.Send_Notifications__c` (default on). Read in the existing static config query. Check it at the SUSPEND and in the trigger. | Yes. No new SOQL. |
| B15 | The trigger updates the log row to `Sent` or `Failed` (upsert on `Fire_Key__c`). | Yes. One row for each logical suspend shows the final state. |
| B16 | Put the notify call last in the SUSPEND handler, after the required DML. | Yes. Same as the SPLIT emit. It cannot use the budget of the required DML. |
| B17 | Also notify on SLEEP, START_CHILD and YIELD. | No. No human waits there. `withNotification` rejects them. |

## Reverse Brainstorming (how can this fail?)

| Way to fail | Prevention |
|-------------|-----------|
| A rolled-back SUSPEND sends a notification. | `PublishAfterCommit` event. The anchor row rolls back too. |
| A re-run of the same suspend sends again. | Unique `Fire_Key__c` per step row. A duplicate insert fails with no exception. No publish. |
| A notify error fails the SUSPEND. | `try`/`catch` on all notify code. A DML budget guard before each DML. |
| The notify DML uses the last DML statement. | Skip the notify when the budget is low (reserve, as in `WorkflowOutboundEventPublisher`). |
| The send error fails the trigger batch and loses `RESUME` events. | Each event has its own `try`/`catch`. `handleEvents` never throws. |
| A bad type name. | Log `Failed` with the reason. |
| No recipient. | `withNotification` requires a recipient source. An empty result at send time logs `Failed`. |
| More than 500 recipients. | Send in chunks of 500. |
| A title or body that is too long. | The builder rejects a title over 250 and a body over 750 characters. |
| Many NOTIFY events in one trigger batch use too much heap or CPU. The batch fails and loses RESUME events. (Added after review.) | Max 200 NOTIFY events for each pass. Publish the others again. |
| A replayed NOTIFY event sends again. (Added after review.) | Read the request from the `Requested` anchor row, not from the event. |
| A forged `NOTIFY` event sends attacker content. (Codex review.) | Same: the engine writes the anchor row. The event holds only the key. |
| More than 10 send calls in one trigger transaction hit an uncatchable limit. (Codex review.) | Max 10 send calls for each pass. Publish the rest again. |
| A recipient Id that is not a user or group fails the send. (Added after review.) | Send only to user and group Ids. |
| A caller changes the recipient sets after validation. (Added after review.) | The read accessors return copies. |
| A second `withNotification` call replaces the first. (Added after review.) | Throw. |
| The example has no approver in the input. (Added after review.) | Fall back to the instance owner. |
| The admin turns the feature off during a wait. | The trigger checks the toggle again. The row shows `Skipped`. |
| An author calls `withNotification` on a COMPLETE. | `IllegalArgumentException`. |
| A test depends on the real send. | Test context captures the request and does not call `send()`. Tests can set the type Id. |
| A matching signal is already buffered. The step resumes at once. | At send time, check that the step row is still `Pending`. Else `Skipped`. (Codex review.) |
| No SOQL is left in the trigger pass. Valid requests fail with "type not found". (Codex review.) | Check the query budget first. Publish the requests again. |
| Engine work in the shared trigger transaction uses the notify budget. Many edge cases. (Codex review, rounds 4 to 6.) | Root cause fix: a separate trigger, `WorkflowNotifyTrigger`, with its own transaction. Before a send, a low budget throws `EventBus.RetryableException`. |
| A buffered signal wakes the instance in the SUSPEND transaction. (Codex review.) | Read the instance status after redelivery. Woken: write no request. The next suspend sends. |
| 200 long requests in one pass use too much heap. (Codex review, round 9.) | Read max 10 keys in a pass (the send-call cap). Publish the rest again. |
| An error before the first send (a lock time-out) consumes the event. (Codex review, round 9.) | Before the first claim, an error asks the platform to deliver the batch again. |
| A result update fails after a send. The row stays `Requested` and a duplicate event sends again. (Codex review, round 8.) | Claim the row (`Sending`) before the send. Send only claimed rows. Lock the rows `FOR UPDATE`. |
| A parallel branch waits while the instance is `Running`, or an unrelated signal wakes the instance. Requiring `Suspended` loses the send. (Codex review, round 7.) | At send time, require a `Pending` step row and an active instance. |

## Six Thinking Hats

- **White (facts):** The SUSPEND writes one step row. `Workflow_Event__e` is `PublishAfterCommit`. `Fire_Key__c` is unique. A send takes max 500 recipients.
- **Red (feelings):** Approvers want one clear notification, not spam. Authors want one line of code.
- **Black (risks):** Maximum three DML statements on an opted-in SUSPEND. A large trigger batch can use too much heap. The Automated Process user sends the notification. Tests cannot see delivery.
- **Yellow (benefits):** A turnkey approval inbox nudge. No new object and no new data field. The log row is an audit trail.
- **Green (ideas):** Owner lookup for queues. A `Sent`/`Failed` state on the log row. A later inbox LWC can read the log rows.
- **Blue (process):** Plan. RED tests with stubs. GREEN code. REFACTOR. Multi-angle review. Map each AC to evidence.

## Spec

`StepResult.withNotification(n)`:

| Input | Result |
|-------|--------|
| `n == null` | `IllegalArgumentException` |
| action not SUSPEND or WAIT_FOR_APPROVAL | `IllegalArgumentException` |
| `n` has no recipient source | `IllegalArgumentException` |
| the result already has a notification | `IllegalArgumentException` |
| else | Stores `n` on `directive().notification`. Returns the result. |

At the SUSPEND (`WorkflowNotifier.request`):

| Condition | Result |
|-----------|--------|
| No notification, or toggle off | Nothing. No DML. |
| DML budget low | Nothing. |
| Anchor insert fails (duplicate) | Nothing. The step already has a request. |
| Anchor insert fails (other error) | One `Notification` error row. |
| Anchor insert succeeds | Publish one `NOTIFY` event. The row has `Outcome__c = Requested`. |
| Publish fails | The row changes to `Failed`. The SUSPEND continues. |

In the trigger (`WorkflowNotifier.handleEvents`):

| Condition | Row `Outcome__c` |
|-----------|------------------|
| No `Requested` row for the key (replay, copy, forged event) | No send. No change. |
| Send calls for this pass used | The request waits. The trigger publishes it again. |
| Toggle off | `Skipped` |
| Type not found | `Failed` |
| No recipient after resolution | `Failed` |
| `send()` throws | `Failed` |
| Else | `Sent` |

## Acceptance Criteria Map

| AC | Test |
|----|------|
| Suspend API with recipients, title, body, target; no `Messaging` code in author code | `WorkflowNotificationTest`, `WorkflowNotifierTest.suspendRequestsOneNotification`, `approvalWaitRequestsOneNotification`, `timedSuspendAlsoNotifies` |
| Static or data-driven recipients | `inputFieldRecipientsResolvedAtSuspend`, `recordOwnerResolvedAtSend`, `nonUserRecipientsAreIgnored` |
| Once per logical suspend | `reSuspendDoesNotNotifyAgain`, `operatorResumeDoesNotNotifyAgain`, `rolledBackSuspendLeavesNoAnchor`, `replayedEventDoesNotSendAgain`, `copiesInOneBatchSendOnce`, `forgedEventWithNoAnchorSendsNothing`, `forgedPayloadIsIgnored`, `endedWaitIsSkipped` |
| Fire-and-forget | `publishFailureDoesNotBlockSuspend`, `lowDmlBudgetSkipsNotify`, `dmlReserveSkipsNotify`, `sendFailureIsLogged`, `eachRequestInABatchIsIsolated`, `badNotifyDoesNotBlockResumeInSameBatch`, `sendBudgetDefersTheRest`, `tooManyRecipientsForOnePassFails`, `lowResultDmlSendsNothingAndWaits`, `lowQueryBudgetWaits`, `deferredPublishFailureIsLogged` |
| Deep link | `suspendRequestsOneNotification` (default: instance), `authorTargetAndTypeAreUsed` |
| Toggle | `toggleReadsTheDefaultConfig`, `toggleOffPublishesNothing`, `toggleOffAtSendSkips` |
| Shipped type | `Revenant_Workflow_Notification.notiftype-meta.xml` |
| Example | `ApprovalWorkflowExampleTest.testApproverIsNotified`, `testGateRequestsNotificationForApprover`, `testGateFallsBackToInstanceOwner` |
