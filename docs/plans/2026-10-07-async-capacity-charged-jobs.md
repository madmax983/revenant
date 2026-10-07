# Plan: count only charged, not-started executions (#280)

## Problem

1. The read counts all job types. `TestRequest`, `TestWorker` and
   `SharingRecalculation` rows do not use `DailyAsyncApexExecutions`. An
   async test run can give a false Critical, or fill the 2,000-row cap.
2. A non-batch job in `Processing` is in `dailyUsed` and also counts as 1
   pending execution. A batch in `Processing` counts its current chunk two
   times. Near the threshold, this gives a false Critical.

Salesforce docs: the daily limit counts batch Apex (`start`, `execute`,
`finish`), future, Queueable and scheduled Apex executions.

## Brainstorm

| Option                                                                                | Result                                                                          |
| ------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------- |
| A. Filter `JobType IN ('BatchApex','Future','Queueable','ScheduledApex')` in the SOQL | Fewer rows. The cap holds charged jobs only. Chosen.                            |
| B. Read all types. Skip uncharged types in Apex                                       | Test rows still fill the cap. Rejected.                                         |
| C. Pass `Status` to `executionsFor`                                                   | Removes the double count. Chosen.                                               |
| D. Uncharged types give 0 in `executionsFor`                                          | Safe if the filter changes. Chosen.                                             |
| E. Move the row loop to a `@TestVisible` method                                       | Unit test with in-memory rows. A test cannot force `Processing`. Chosen.        |
| F. Count a not-started batch `start` (+1)                                             | The issue says "as today". Unsized batches are already a lower bound. Rejected. |

## Reverse brainstorm: how can it fail?

| Risk                                                         | Control                                                                                      |
| ------------------------------------------------------------ | -------------------------------------------------------------------------------------------- |
| A `Processing` batch at its last chunk gives 0               | Formula keeps `finish`: `max(T − D − 1, 0) + 1`. Test it.                                    |
| `JobType` spelled wrong in the filter                        | One constant list. The helper test uses the same names.                                      |
| A `Processing` batch with `TotalJobItems` 0 shows as unsized | `start` is done in `Processing`. Not unsized. Test it.                                       |
| Job counts disagree with **Setup → Apex Jobs**               | Docs say the counts are charged job types only.                                              |
| `ORDER BY JobType` does not put batch first                  | SOQL sorts a picklist in setup order. Use `ORDER BY TotalJobItems DESC NULLS LAST` (review). |
| SOQL cost goes up                                            | Same query, one more filter. Test checks 1 SOQL.                                             |
| Salesforce docs do not name `SharingRecalculation`           | The issue says it is not charged. Keep it out. Rare jobs.                                    |
| `ScheduledApex` rows stay `Queued`                           | Each counts 1. Docs say so. No change (as today).                                            |

## Six hats

- White: 1 SOQL, max 2,001 rows. `BatchApexWorker` gives 0 today.
- Red: a false "Chain handoff at risk" makes operators stop trusting it.
- Black: a `Processing` batch between chunks is under by 1. Small; accept.
- Yellow: fewer rows, fewer false Critical. No cost change.
- Green: later, count batch `start` for a not-started batch.
- Blue: RED tests, GREEN code, REFACTOR docs, then agent review.

## Decision

Job counts (Holding, Queued, Processing, Preparing, Total) count charged
job types only. They come from the same filtered read.

## Steps

1. RED: `executionsFor` for each status and job type. Uncharged type
   gives 0. Row loop test with in-memory `Processing` rows.
2. GREEN: SOQL filter, `Status` in `executionsFor`, row loop method.
3. REFACTOR: comments, `async-capacity.md`, ADR 0006, README.
4. Review from several angles. Fix findings.
