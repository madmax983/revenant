# Fleet Health Summary (Issue #111)

## Goal

Show one row for each workflow definition with instances in a rolling window. Each row shows counts, success rate and approximate duration. The operator reads fleet health in one view. The view does not write data.

## Facts About The Engine

- The trigger sets `Terminal_At__c` for `Completed`, `Failed`, `Compensated`, `Cancelled` and `ContinuedAsNew`. `CompensationFailed` and `DefinitionChanged` are active statuses. They have no `Terminal_At__c`.
- SOQL cannot calculate `Terminal_At__c - CreatedDate`. `AVG` and `SUM` accept only number fields. The issue does not allow a new field.
- The sources do not agree on how an aggregate query uses query rows: one row for each group, or one row for each record. The design must be safe in both cases.
- `WorkflowDashboardController` is at the PMD public-member limit. The Rate Limits panel (#61) uses a separate controller for this reason.
- `WorkflowTrendService` (System Doctor, "Definition Health") counts by `Terminal_At__c`. It has no started, in-flight or duration data.

## Brainstorming (options)

| # | Idea | Keep? |
|---|------|-------|
| B1 | Add columns to `getDefinitionTrends`. | No. It changes the window of a released panel from terminal time to start time. |
| B2 | New endpoint and a new top-level "Fleet Health" view. | Yes. No change to released panels. |
| B3 | Put the endpoint on `WorkflowDashboardController`. | No. PMD public-member limit. |
| B4 | New `WorkflowFleetHealthController`, same view gate. | Yes. Same pattern as #61. |
| B5 | Counts use the instances that started in the window. | Yes. The numbers agree: started = completed + failed + in-flight. |
| B6 | Counts from one `COUNT(Id) GROUP BY Workflow_Name__c, Status__c` query. | Yes, after a probe. See B15. |
| B7 | Durations from hour buckets (`HOUR_IN_DAY`) and `MIN`/`MAX`. | No. One-hour error. The group count grows with time. |
| B8 | Durations from one sample query: rows with `Terminal_At__c` in the window, newest first, `LIMIT` cap + 1. | Yes. The cost has a fixed cap. The extra row shows if the sample is partial. |
| B9 | Scan all rows in a SOQL `for` loop. | No. Cost grows with volume. |
| B10 | Threshold on the client, default 95%. | Yes. No new field. The flag changes immediately. |
| B11 | Sort rows by success rate, lowest first. A row with no rate goes last. | Yes. A regression shows at the top. |
| B12 | Row click opens the instance list with the definition filter (`getFilteredInstances`). | Yes. Share one method with the Catalog deep link. |
| B13 | Put `DefinitionChanged` in in-flight. | Yes. It is an active status. The issue does not list it because #89 added it later. |
| B14 | Put `CompensationFailed` in failed. | Yes. The issue asks for it. Its outcome is a failure. |
| B15 | A `COUNT() LIMIT 20,001` probe. Above 20,000, count the newest 20,000 rows. | Yes (added after review). Safe in both cases of row accounting. |
| B17 | The aggregate only for 2,000 instances or fewer. Above that, a row query counts. | Yes (added after review). An Apex aggregate query cannot return more than 2,000 rows. |
| B16 | Durations only for instances that started in the window. | No (changed after review). The maximum can never be more than the window. |

## Reverse Brainstorming (how to make it fail)

| Way to fail | Prevention |
|-------------|------------|
| Query cost grows with volume and hits the 50,000-row limit. | Probe with a cap. Row query with a cap above the cap. Sample with a cap. Test: rows stay at or below the caps. |
| One busy definition fills the sample. Other rows show no duration. | The view shows "≈" and a note. |
| The view writes data or changes `Terminal_At__c`. | No DML, no jobs. Test: DML and job counts do not change. `Terminal_At__c` does not change. |
| A non-admin reads fleet data. | `checkAuthorization()` first. Test with a Standard User. |
| Divide by zero when no instance is terminal. | The success rate is `null`. The UI shows "—". |
| Two numbers for one definition confuse the operator. | The view text states which instances each number uses. |
| A slow response overwrites a newer window. | Each request has an id. The UI discards a response from an older request. |
| An aggregate query with more than 2,000 groups fails. | Run the aggregate only for 2,000 instances or fewer. |
| A failed load looks like "no instances". | An error state that is different from the empty state. |

## Six Thinking Hats

- **White (facts):** Three queries. Rows ≤ 42,002. No new object or field.
- **Red (feeling):** Operators want one screen and a red flag. A table with a clear flag is enough.
- **Black (risks):** The duration can be a sample, not exact. Active instances are not in the duration. The docs and the UI state this.
- **Yellow (value):** Operators find a regression in one view. They do not wait for a user complaint.
- **Green (new ideas):** Status deep links for each count, trend lines and alerts are out of scope.
- **Blue (process):** Plan → ADR → Apex tests (RED) → Jest tests (RED) → service, controller and LWC (GREEN) → share the deep link (REFACTOR) → review → fixes.

## Design

- `WorkflowFleetHealthController.getFleetHealth(String windowKey)` calls `WorkflowFleetHealthService.fleetHealth`.
- Windows: `1h`, `24h`, `7d`. A blank or unknown key gives `24h`.
- Result: `windowKey`, `windowHours`, `countCap`, `countsCapped`, `sampleCap`, `isSampled`, `rows`.
- Row: `workflowName`, `started`, `completed`, `failed`, `inFlight`, `successRate`, `avgDurationMs`, `maxDurationMs`, `durationSampleSize`, `durationSampled`.
- LWC: "Fleet Health" button, window selector, threshold input, table, row deep link, error state.

## Test Plan

| AC | Apex test | Jest test |
|----|-----------|-----------|
| 1 One row per definition, window | `testOneRowPerDefinitionInWindow`, `testWindowKeyMapping`, `testNameCaseGivesOneRow`, `testDurationIncludesInstancesStartedBeforeWindow` | `lists one row per definition…`, `requests a new window…` |
| 2 Counts | `testStatusBuckets`, `testRowCountsMatchAggregateCounts` | `lists one row per definition…` |
| 3 Success rate, threshold flag | `testSuccessRateAndSortOrder` | `flags rows below the default 95% threshold`, `flags from the counts…`, `applies an operator threshold…`, `keeps the last threshold…` |
| 4 Avg and max duration | `testDurations`, `testDurationSampleCap`, `testExactCapIsNotSampled`, `testDurationIncludesInstancesStartedBeforeWindow` | `marks sampled durations as approximate`, `shows no sample or count note…` |
| 5 Read-only | `testReadOnly` | — |
| 6 Bounded cost, auth gate | `testQueryCostIsBounded`, `testCountCapUsesNewestInstances`, `testUnauthorizedUserIsDenied`, `testPermissionSetsGrantController`, `RevenantOperatorPermSetTest.testOperatorCanReadFleetHealth` | `shows a note when the counts use the newest instances only`, `shows an error state…` |
| 7 Deep link | — | `deep-links a row to the filtered instance list…` |
