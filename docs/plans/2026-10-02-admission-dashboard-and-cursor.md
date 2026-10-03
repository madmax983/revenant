# Dashboard Queue Flag and Backfill Cursor (Issue #277)

## Goal

1. The dashboard shows which queues it did not load, in a fixed order.
2. The backfill passes more than 5 failing pages across calls.

## Facts

- `waitingQueue` runs one query per governed workflow. It iterates a `Set`, so the order is not fixed.
- `backfillQueue` starts at `afterId = null` on each call.
- `Watchdog_Liveness__c` is a hierarchy setting. It shows the pattern: state with 0 SOQL.
- The author has no org. Jest runs here. Apex tests run in CI.

## Brainstorm

| #   | Idea                                        | Keep?                                                  |
| --- | ------------------------------------------- | ------------------------------------------------------ |
| B1  | Sort workflow names before the read.        | Yes. The same queues are skipped each time.            |
| B2  | Read only workflows that have waiting rows. | Yes. Fewer queries. Less truncation.                   |
| B3  | `waitingTruncated` flag and an LWC notice.  | Yes.                                                   |
| B4  | Page the panel.                             | No. Larger change. Follow-up if needed.                |
| B5  | Hierarchy setting for the cursor.           | Yes. New setting. Same pattern as the liveness marker. |
| B6  | `afterId` parameter and a returned cursor.  | No. The heartbeat has no state between calls.          |
| B7  | Mark failed rows with a field.              | No. A new field on a hot object. A trigger loop.       |

## Reverse Brainstorm (how can this fail?)

| Way to fail                                 | Prevention                                       |
| ------------------------------------------- | ------------------------------------------------ |
| The cursor never resets. Rows stay skipped. | Reset on progress or on an empty or short page.  |
| A stale cursor Id points to a deleted row.  | `Id > cursor` still works.                       |
| The cursor write fails. The call fails.     | Catch, log. The next call reads from the old Id. |
| Each call writes DML when nothing changed.  | Write only when the value changes.               |
| An empty queue shows as truncated.          | Flag only when the workflow has waiting rows.    |
| An old server sends no flag.                | The LWC treats a missing flag as false.          |

## Six Hats

- White: facts above. Seams: `backfillFailIds`, `maxQueueReadsOverride`.
- Red: operators do not trust a silent empty list. The notice fixes this.
- Black: one extra DML statement per failing call. A limit check guards it.
- Yellow: no new field on `Workflow_Instance__c`. No global API change.
- Green: a later version can page the panel.
- Blue: RED tests (Apex and Jest), then GREEN, then REFACTOR, then review.

## Decision

B1, B2, B3, B5. B5 is a new hierarchy setting, `Admission_Backfill_Cursor__c`, with field `After_Id__c`.
