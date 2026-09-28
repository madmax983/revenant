# Continue-As-New Chain

Issue #116. Each Continue-As-New generation is a new `Workflow_Instance__c`. `WorkflowChainRead.getChain` gives all generations of a chain as one list, newest first. The dashboard shows the same list. Use it to find the generation where a perpetual workflow started to fail or stall.

## Apex

```apex
// First page (50 rows). Any member works: root key, successor key, or Id.
WorkflowEngine.ChainPage page = WorkflowChainRead.getChain('nightly-sync');
if (page == null) { return; } // No instance matches.

for (WorkflowEngine.ChainGeneration g : page.entries) {
  // g.generation, g.status, g.outcome, g.startedAt, g.endedAt, g.failureCategory
}

// Older pages.
WorkflowEngine.ChainRequest req = new WorkflowEngine.ChainRequest();
req.keyOrId = 'nightly-sync';
req.pageSize = 200;              // null -> 50; above 200 -> 200; 0 or less -> throws
req.cursor = page.nextCursor;    // send back with no change; null on the last page
WorkflowEngine.ChainPage older = WorkflowChainRead.getChain(req);
```

For the step timeline of one generation, call `WorkflowHistoryRead.getHistory(g.instanceId)`.

## `ChainPage`

| Field | Type | Meaning |
|-------|------|---------|
| `entries` | `List<ChainGeneration>` | Generations of this page, newest first. |
| `rootCorrelationKey` | `String` | Root key of the chain. Null for an instance with no key. |
| `totalCount` | `Integer` | Generations in the chain, for all pages. A lower bound when `isTotalCapped`. |
| `isTotalCapped` | `Boolean` | True above `WorkflowChainRead.MAX_COUNTED_GENERATIONS` (50,000). |
| `nextCursor` | `String` | Cursor for the next (older) page. Null on the last page. |
| `hasMore` | `Boolean` | True when `nextCursor` is not null. |
| `pageSize` | `Integer` | Page size that the read used. |

## `ChainGeneration`

| Field | Type | Meaning |
|-------|------|---------|
| `instanceId` | `Id` | Id of the instance. |
| `instanceName` | `String` | Auto-number name. |
| `generation` | `Integer` | 1 is the oldest kept generation. Null when `isTotalCapped`. |
| `definitionName` | `String` | Workflow definition name. |
| `correlationKey` | `String` | Key of this generation (for example `key_run3`). |
| `status` | `String` | Raw status. |
| `isTerminal` | `Boolean` | Same set as `getStatus`. `ContinuedAsNew` gives false. |
| `outcome` | `String` | Terminal status or `ContinuedAsNew`. Null while open. |
| `startedAt` | `Datetime` | `CreatedDate`. |
| `endedAt` | `Datetime` | When it closed. Null while open. |
| `continuedAt` | `Datetime` | When it handed off. Null unless `ContinuedAsNew`. |
| `failureCategory` | `String` | Failure category, or null. |
| `errorMessage` | `String` | Error message (max 255 characters), or null. |
| `previousInstanceId` | `Id` | Predecessor, or null for a first generation. |

## Membership

A chain is the rows with:

1. The same `Workflow_Name__c`.
2. The same root key: `Root_Correlation_Key__c`, or `Correlation_Key__c` for a legacy row with a blank root.
3. A position from the nearest first generation (`Previous_Instance__c` is null) at or before the anchor, to the next first generation after it.

Rule 3 makes a later independent run with the same key a separate chain. Each member of a chain gives the same list. A key gives the chain of the newest row with that key or root key.

A `compensate()` instance links to the instance that it compensates. Thus it is a generation of that chain.

## Cost

- Max 6 SOQL for each call, for all chain lengths. The count is `SELECT COUNT() ... LIMIT`, one query row.
- A single generation costs one SOQL.
- Max 201 rows for each page. No long text field. No DML, no enqueue, no event.
- Safe in each Apex context.

## Dashboard

Open an instance that has a previous or a next run. The detail pane shows **Continue-As-New Generations**:

- One row for each generation, newest first, with a status badge and the failure category.
- "Showing X of N generations". `N+` when the total is capped.
- Click a row to open the step timeline of that generation. The list stays.
- **Load older generations** gets the next page.

An instance with no previous and no next run shows no section and makes no extra call.

## Known Limits

- Do not use the root key again for an independent run while the chain is live. The two chains then mix. `getStatus` has the same limit.
- A purge of old generations changes the numbers. `generation` counts from the oldest kept row. A purge in the middle of a chain splits it.
- A first generation with no correlation key is a chain of one row. Its successors use the key of the second generation as root.
- A cursor keeps the generation number of its row. A purge between two page calls can make later numbers wrong by the number of purged rows.
