# ADR 0004: Fleet health counts and duration sample

- **Status:** Accepted
- **Date:** 2026-09-28
- **Issue:** #111

## Context

The Fleet Health view shows counts and the average and maximum duration for each definition. The query cost must not grow with the fleet size or the instance volume.

SOQL cannot calculate `Terminal_At__c - CreatedDate`. `AVG`, `SUM`, `MIN` and `MAX` cannot use this value. The issue does not allow a new field. `WorkflowDashboardController` is at the PMD public-member limit.

## Decision

1. Use one cohort: instances with `CreatedDate` in the window.
2. Get the counts from one `COUNT(Id) GROUP BY Workflow_Name__c, Status__c` query. This query uses one query row for each group.
3. Get the durations from one sample query. It reads terminal cohort rows, newest `Terminal_At__c` first, with a fixed `LIMIT` (2,000). Apex calculates the average and the maximum.
4. Each row has `durationSampled`. It is true when the sample has fewer rows than the terminal count of the definition.
5. Put the endpoint on a new `WorkflowFleetHealthController`. Both dashboard permission sets grant it.

## Consequences

- Two queries for each call. Query rows ≤ groups + 2,000.
- Counts are exact. Durations are approximate when a row is sampled.
- A busy definition can fill the sample. Other definitions then have fewer or no duration values.
- Instances that are still active are not in the duration. Long runs can make the average too low.

## Rejected Options

- A formula field for the duration: the issue does not allow a new field.
- Hour buckets (`HOUR_IN_DAY`) with `MIN`/`MAX`: one-hour error, and the group count grows.
- A full scan in a SOQL `for` loop: cost grows with volume.
- A new method on `WorkflowDashboardController`: PMD public-member limit.
