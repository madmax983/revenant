# Fleet Health Summary (Issue #111)

## Goal

Show one row for each workflow definition with instances in a rolling window. Each row shows counts, success rate and approximate duration. The operator reads fleet health in one view. The view does not write data.

## Facts About The Engine

- `Terminal_At__c` is set by the trigger for `Completed`, `Failed`, `Compensated`, `Cancelled` and `ContinuedAsNew`. `CompensationFailed` and `DefinitionChanged` are active. They have no `Terminal_At__c`.
- SOQL cannot calculate `Terminal_At__c - CreatedDate`. `AVG` and `SUM` accept only number fields. The issue does not allow a new field.
- A `COUNT(Id) ... GROUP BY` query uses one query row for each group. `MIN`, `MAX`, `AVG` and `SUM` use one query row for each record.
- `WorkflowDashboardController` is at the PMD public-member limit. The Rate Limits panel (#61) uses a separate controller for this reason.
- `WorkflowTrendService` (System Doctor, "Definition Health") counts by `Terminal_At__c`. It has no started, in-flight or duration data.

## Brainstorming (options)

| # | Idea | Keep? |
|---|------|-------|
| B1 | Add columns to `getDefinitionTrends`. | No. It changes the window of a shipped panel from terminal time to start time. |
| B2 | New endpoint and a new top-level "Fleet Health" view. | Yes. No change to shipped panels. |
| B3 | Put the endpoint on `WorkflowDashboardController`. | No. PMD public-member limit. |
| B4 | New `WorkflowFleetHealthController`, same view gate. | Yes. Same pattern as #61. |
| B5 | One cohort: instances with `CreatedDate` in the window. All counts and durations use this cohort. | Yes. The numbers agree: started = completed + failed + in-flight. |
| B6 | Counts from one `COUNT(Id) GROUP BY Workflow_Name__c, Status__c` query. | Yes. Exact. Row cost is one row for each group. |
| B7 | Durations from hour buckets (`HOUR_IN_DAY`) and `MIN`/`MAX`. | No. One-hour error. Group count grows with time. |
| B8 | Durations from one sample query: terminal cohort rows, newest `Terminal_At__c` first, `LIMIT` cap. | Yes. Two queries in total. Row cost has a fixed cap. |
| B9 | Scan all terminal rows in a SOQL `for` loop. | No. Cost grows with volume. |
| B10 | Threshold on the client, default 95%. | Yes. No new field. The flag changes at once. |
| B11 | Sort rows by success rate, lowest first. No rate goes last. | Yes. A regression shows at the top. |
| B12 | Row click opens the instance list with the definition filter (`getFilteredInstances`). | Yes. Share one method with the Catalog deep link. |
| B13 | Put `DefinitionChanged` in in-flight. | Yes. It is a parked, active status. The issue list is older than #89. |
| B14 | Put `CompensationFailed` in failed. | Yes. The issue asks for it. It is an unsuccessful outcome. |

## Reverse Brainstorming (how to make it fail)

| Way to fail | Prevention |
|-------------|------------|
| Query cost grows with volume and hits the 50,000-row limit. | `COUNT` only in the count query. A fixed `LIMIT` on the sample. Test: rows used stay under groups + cap. |
| One busy definition fills the sample. Other rows show no duration. | Each row has `durationSampled`. The UI marks the value as approximate. |
| The view writes data or changes `Terminal_At__c`. | No DML, no jobs. Test: DML and job counts do not change. `Terminal_At__c` does not change. |
| A non-admin reads fleet data. | `checkAuthorization()` first. Test with a Standard User. |
| Divide by zero when no instance is terminal. | Success rate is `null`. The UI shows "—". |
| Two numbers for one definition confuse the operator. | The view text states the cohort: instances started in the window. |
| A slow response overwrites a newer window. | A request id. The UI discards a stale response. |
| An aggregate `for` loop with more than 2,000 groups fails. | Assign the query to a list. |

## Six Thinking Hats

- **White (facts):** Two queries. Row cost ≤ groups + 2,000. Groups ≤ definitions × 13 statuses. No new object or field.
- **Red (feeling):** Operators want one screen and a red flag. A table with a clear flag is sufficient.
- **Black (risks):** The duration is a sample, not exact. Long instances that are still active do not show in the duration. The docs and the UI state this.
- **Yellow (value):** Time to find a regression goes from "user complaint" to one view.
- **Green (new ideas):** Later: status deep links for each count, trend lines, alerts. Out of scope.
- **Blue (process):** Plan → ADR → Apex tests (RED) → Jest tests (RED) → service, controller and LWC (GREEN) → share the deep link (REFACTOR) → review.

## Design

- `WorkflowFleetHealthController.getFleetHealth(String windowKey)` calls `WorkflowFleetHealthService.fleetHealth`.
- Windows: `1h`, `24h`, `7d`. A blank or unknown key gives `24h`.
- Result: `windowKey`, `windowHours`, `sampleCap`, `isSampled`, `rows`.
- Row: `workflowName`, `started`, `completed`, `failed`, `inFlight`, `successRate`, `avgDurationMs`, `maxDurationMs`, `durationSampleSize`, `durationSampled`.
- LWC: "Fleet Health" button, window selector, threshold input, table, row deep link.

## Test Plan

| AC | Apex test | Jest test |
|----|-----------|-----------|
| 1 One row per definition, window | `testOneRowPerDefinitionInWindow`, `testWindowKeyMapping` | `lists one row per definition`, `changes the window` |
| 2 Counts | `testStatusBuckets` | `lists one row per definition` |
| 3 Success rate, threshold flag | `testSuccessRate`, `testNoTerminalGivesNullRate` | `flags rows below the threshold`, `threshold change` |
| 4 Avg and max duration | `testDurations`, `testDurationSampleCap` | `shows durations and sample marker` |
| 5 Read-only | `testReadOnly` | — |
| 6 Bounded cost, auth gate | `testQueryCostIsBounded`, `testUnauthorizedUserIsDenied`, `testPermissionSetsGrantController` | — |
| 7 Deep link | — | `deep-links a row` |
