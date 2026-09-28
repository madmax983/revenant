# ADR 0004: Fleet health counts and duration sample

- **Status:** Accepted
- **Date:** 2026-09-28
- **Issue:** #111

## Context

The Fleet Health view shows counts and the average and maximum duration for each definition. The query cost must not grow with the fleet size or the instance volume.

SOQL cannot calculate `Terminal_At__c - CreatedDate`. `AVG`, `SUM`, `MIN` and `MAX` cannot use this value. The issue does not allow a new field.

The Salesforce guide says that a `COUNT` query with `GROUP BY` uses one query row for each group. Other reports, and `WorkflowTrendService`, say that each aggregated record uses one query row. We cannot test this without an org. Thus the design must stay below the 50,000-row limit in both cases.

`WorkflowDashboardController` is at the PMD public-member limit.

## Decision

1. The counts use the instances that started in the window (`CreatedDate`).
2. A probe query counts these instances: `SELECT COUNT() ... LIMIT 20,001`.
3. When the count is 2,000 or less, one `COUNT(Id) GROUP BY Workflow_Name__c, Status__c` query gets the exact counts. An Apex aggregate query cannot return more than 2,000 rows. The group count is never more than the instance count.
4. When the count is more than 2,000, one row query reads the newest 20,000 instances in a SOQL `for` loop. The counts are exact up to 20,000. Above 20,000, the result has `countsCapped = true` and the view shows a note.
5. The durations use the instances that got a `Terminal_At__c` in the window. One query reads the newest 2,001 of these rows. Apex uses the first 2,000. When the query returns 2,001 rows, the result has `isSampled = true` and each duration shows "≈".
6. A definition that has only a finished instance in the window gets a row with `started = 0`.
7. The map key is the lower-case name, because SOQL `GROUP BY` ignores case.
8. The endpoint is on a new `WorkflowFleetHealthController`. Both dashboard permission sets grant it.

## Consequences

- Each call uses three queries.
- Query rows are at most 20,001 + 20,000 + 2,001 = 42,002. This is true in both cases of aggregate row accounting.
- Counts are exact up to 20,000 started instances in the window.
- A definition with many terminal instances can fill the duration sample. Other definitions then have fewer or no duration values.
- The duration does not include active instances.
- `Terminal_At__c` has no index. The duration query can be slow on a very large object.

## Rejected Options

- A formula field for the duration: the issue does not allow a new field.
- Hour buckets (`HOUR_IN_DAY`) with `MIN` and `MAX`: one-hour error, and the group count grows.
- A full scan in a SOQL `for` loop: cost grows with volume.
- Durations from the start cohort only: the maximum can never be more than the window.
- A new method on `WorkflowDashboardController`: PMD public-member limit.
