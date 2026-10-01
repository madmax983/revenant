# Breaker Sweep Starvation (Issue #236)

## Goal

The half-open sweep must not skip a due Open breaker because other Open rows fill the batch.

## Facts

- `CircuitBreakerReconciler.sweepHalfOpen` reads `Status__c = 'Open'` rows with `LIMIT 200` and `FOR UPDATE`. The query has no order.
- The open duration is on `Circuit_Breaker_Config__mdt`, not on the row. A key can resolve to the `Default` record. Thus SOQL cannot filter on "due".
- Rows that are not due (long duration, or no config) can fill the batch. A due row after the limit can wait for many heartbeats.
- SOQL does not allow `ORDER BY` with `FOR UPDATE`. SOQL rejects the fix in the issue text (add `ORDER BY` to the query).
- The sweep locks all 200 rows, also rows that it does not change. `tryAdmit` must wait for these locks.
- `tryAdmit` also flips a due row on demand. The sweep is the backstop for a key with no traffic.
- The engine already uses "find, then lock" (`WorkflowDebounceSweeper`, `WorkflowSignalSources`).

## Brainstorm

| #   | Idea                                                                   | Keep?                                                                  |
| --- | ---------------------------------------------------------------------- | ---------------------------------------------------------------------- |
| B1  | Add `ORDER BY Opened_At__c ASC` to the locked query.                   | No. SOQL rejects `ORDER BY` with `FOR UPDATE`.                         |
| B2  | Find: unlocked read, oldest first, more rows. Filter due rows in Apex. | Yes. One cheap read. No schema change.                                 |
| B3  | Lock: read the due Ids `FOR UPDATE`. Check again under the lock.       | Yes. Locks only rows that change. Safe against a race with `tryAdmit`. |
| B4  | Store a "due at" time on the row. Filter in SOQL.                      | No. Schema change. A config edit makes the stored value wrong.         |
| B5  | Build a SOQL filter per open duration from the config.                 | No. The `Default` fallback and the name mapping cannot go into SOQL.   |
| B6  | Seek cursor across heartbeats.                                         | No. Needs a durable store. B2 is sufficient for the risk.              |
| B7  | Close or delete Open rows that have no config.                         | No. Behavior change. A config that comes back must see the row.        |

## Reverse Brainstorm (how can this fail?)

| Way to fail                                                   | Prevention                                                                                    |
| ------------------------------------------------------------- | --------------------------------------------------------------------------------------------- |
| A due row stays behind more than 200 rows that are not due.   | Find reads up to 2,000 rows. It keeps only due rows, up to 200. Test.                         |
| The batch takes new due rows and skips old due rows.          | Find sorts by `Opened_At__c`, then `Id`. Test.                                                |
| A row changes between find and lock (`tryAdmit` flips it).    | Lock reads only `Open` rows and checks "due" again. Test.                                     |
| A row opens again between find and lock (new `Opened_At__c`). | The check under the lock uses the locked value. Test.                                         |
| More SOQL in the heartbeat.                                   | One more query only when a row is due. Tests check 1 and 2 queries.                           |
| A null `Opened_At__c`.                                        | Null sorts first. `openDurationElapsed` returns true for null, if a config exists. No change. |
| More than 2,000 Open rows that are not due.                   | Accepted. Needs 2,000 older Open rows that are not due. Traffic still flips the row.          |

## Six Hats

- White: one class changes. One query becomes two. No schema change. No global API change.
- Red: the issue is P2/P3. Keep the fix small. Do not add a store.
- Yellow: due rows go first. The sweep locks fewer rows, so `tryAdmit` waits less.
- Black: SOQL rejects the simple fix in the issue. A race between find and lock. Both have a test.
- Green: a stored "due at" field or a cursor is possible later if 2,000 is not sufficient.
- Blue: RED tests first, then GREEN, then REFACTOR, then review from many angles.

## Design

- `findDueIds(now, mockConfigs)`: unlocked read of `Open` rows, `ORDER BY Opened_At__c ASC NULLS FIRST, Id ASC`, `LIMIT sweepScanLimit` (2,000). Keep due rows, up to `sweepBatchSize` (200).
- `lockDueRows(ids, now, mockConfigs)`: read `Id IN :ids AND Status__c = 'Open'` with `FOR UPDATE`. Keep rows that are still due.
- `sweepHalfOpen`: find, lock, flip. No due row: one query, no lock.

## Tests

- Due row after many rows that are not due: it flips (failed before the fix).
- Due row after many rows with no config: it flips.
- Batch cap: the oldest due rows flip first (failed before the fix).
- Null `Opened_At__c`: sorts first and flips.
- No due row: one query. Due rows: two queries.
- Lock skips a row that is no longer `Open`.
- Lock skips a row that opened again (not due now).
- Scan limit: a due row after the scan window stays `Open` (the known bound).
