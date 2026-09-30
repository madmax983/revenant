# Status Bucket Alignment (Issue #225)

## Goal

Make the legacy dashboard stat tiles and the Workflow Catalog use the same active/failed/suspended mapping. The work is read-only. No schema change.

## Facts

| Status | Catalog (#54) | Legacy tiles (before) |
|--------|---------------|-----------------------|
| Pending, Running, Compensating, Cancelling, Paused, DefinitionChanged, Held | active | active |
| Suspended | suspended | active |
| Failed, CompensationFailed | failed | failed |
| Compensated, Cancelled | not counted | failed |
| Completed, ContinuedAsNew | not counted | completed |

- The Catalog keeps its sets in `WorkflowCatalogService`. The legacy tiles keep a second copy in `WorkflowStallDetectionService`. Two copies caused the drift.
- The LWC uses `stats.active` for the bulk Cancel gate. `BulkCancelWorkflow` also cancels `Suspended`. A plain change would disable Cancel when only Suspended instances match.
- `stats.failed` drives the Re-drive label. `Compensated` and `Cancelled` are not re-drivable, so the old count was too high.

## Brainstorming

| # | Idea | Keep? |
|---|------|-------|
| B1 | Only document the difference. | No. Two health views that disagree confuse operators. |
| B2 | Copy the Catalog sets into the legacy code again. | No. The copies drift again. |
| B3 | One shared classifier, used by both surfaces. | Yes. |
| B4 | Add a `suspended` key to the stats map. | Yes. Keeps the Catalog meaning. |
| B5 | Keep the `completed` tile and its statuses. | Yes. The issue does not change it. |
| B6 | Count Compensated and Cancelled in `total` only. | Yes. They are terminal and not failures. |
| B7 | Cancel gate uses active + suspended. | Yes. Matches `BulkCancelWorkflow`. |
| B8 | Add a Suspended tile, rename "Running / Suspended" to "Active". | Yes. The label must match the new meaning. |

## Reverse Brainstorming

| Way to fail | Prevention |
|-------------|------------|
| A status is added to one surface only. | One classifier. Test: both surfaces give the same bucket for each status. |
| Cancel is disabled for Suspended-only filters. | LWC test for this case. |
| `total` no longer equals the sum of the tiles. | Document it. `total` counts all statuses. |
| Catalog query changes by mistake. | Existing Catalog tests stay green. The query set comes from the classifier. |
| A Global API change. | New class is `public`. No `global` change. |

## Six Thinking Hats

- **White:** Two copies of the status sets. Five statuses change bucket.
- **Red:** Operators trust a number only if both views agree.
- **Black:** Re-drive and Cancel counts change. Tests cover both.
- **Yellow:** One rule. Future statuses need one edit.
- **Green:** A per-bucket drill-down link is out of scope.
- **Blue:** Plan → RED tests → classifier and LWC (GREEN) → Catalog uses classifier (REFACTOR) → review → fixes.

## Design

- New `WorkflowHealthBuckets` (public, pure). `bucketOf(status)` returns `active`, `failed`, `suspended` or `null`. `HEALTH_STATUSES` lists the statuses it maps.
- `WorkflowCatalogService` uses it for counting and for the query filter.
- `WorkflowStallDetectionService.bucketWorkflowStat` uses it, and keeps `completed` for `Completed` and `ContinuedAsNew`.
- `rollupStats` returns `suspended` too.
- LWC: default `stats.suspended`, Cancel gate and label use active + suspended, tile label "Active", new "Suspended" tile.

## Tests

- RED (Apex): `WorkflowHealthBucketsTest` for every status. `testGetWorkflowStatsBuckets` for the legacy tiles. Parity test: Catalog counts equal tile counts.
- RED (Jest): tile labels, Cancel enabled with Suspended only.
