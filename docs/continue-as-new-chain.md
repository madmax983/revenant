# Continue-As-New Chain

Issue #116. Each Continue-As-New generation is a new `Workflow_Instance__c`. `WorkflowChainRead.getChain` gives all generations of a chain as one list, newest first. The dashboard shows the same list. Use it to find the generation where a perpetual workflow started to fail or stopped. See [ADR 0006](adr/0006-continue-as-new-chain-read.md).

## Apex

```apex
// First page (50 rows). An Id gives the chain of that instance.
// A key gives the chain of the newest instance with that key.
WorkflowEngine.ChainPage page = WorkflowChainRead.getChain('nightly-sync');
// WorkflowEngine.ChainPage page = WorkflowChainRead.getChain(instanceId);
if (page == null) { return; } // No instance matches.

for (WorkflowEngine.ChainGeneration g : page.entries) {
  // g.generation, g.status, g.outcome, g.startedAt, g.endedAt, g.failureCategory
}

// Older pages.
WorkflowEngine.ChainRequest req = new WorkflowEngine.ChainRequest();
req.correlationKey = 'nightly-sync'; // or req.instanceId; not both (throws)
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
| `isTotalCapped` | `Boolean` | True above the count cap: `WorkflowChainRead.MAX_COUNTED_GENERATIONS` (50,000), or less when the transaction has fewer query rows left. |
| `nextCursor` | `String` | Cursor for the next (older) page. Null on the last page. |
| `hasMore` | `Boolean` | True when `nextCursor` is not null. |
| `pageSize` | `Integer` | Page size that the read used. |

## `ChainGeneration`

| Field | Type | Meaning |
|-------|------|---------|
| `instanceId` | `Id` | Id of the instance. |
| `instanceName` | `String` | Auto-number name. |
| `generation` | `Integer` | 1 is the oldest kept generation. Null when not known (for example when `isTotalCapped`). Not an identifier: a purge changes it. |
| `definitionName` | `String` | Workflow definition name. |
| `correlationKey` | `String` | Key of this generation (for example `key_run3`). |
| `status` | `String` | Raw status. |
| `isTerminal` | `Boolean` | Same set as `getStatus`. `ContinuedAsNew` gives false. |
| `outcome` | `String` | Terminal status or `ContinuedAsNew`. Null while open. |
| `startedAt` | `Datetime` | `CreatedDate`. |
| `endedAt` | `Datetime` | When it closed. For outcome `ContinuedAsNew`, the hand-off time. Null while open. |
| `failureCategory` | `String` | Failure category, or null. |
| `errorMessage` | `String` | Error message (max 255 characters), or null. |
| `previousInstanceId` | `Id` | Predecessor, or null for a first generation. |

## Membership

A chain is the rows with:

1. The same `Workflow_Name__c`.
2. The same root key: `Root_Correlation_Key__c`, or `Correlation_Key__c` for a legacy row with a blank root.
3. A link into the range. The pivot is the predecessor of the anchor, or the anchor when it has no predecessor. The range starts at the nearest first generation (`Previous_Instance__c` is null) at or before the pivot. It stops before the next first generation after the pivot. A row is a member when it is that first generation, or when its predecessor is in the range.

Rule 3 makes a later independent run with the same key a separate chain. The Id of each member of a chain gives the same list. A key gives the chain of the newest row with that key or root key. With a cursor, the read uses the chain of the first page, also when the key is used again between two calls.

A `compensate()` instance links to the instance that it compensates. Thus it is a generation of that chain. It stays in that chain also when a newer run used the key before the compensation.

## Cost

- Max 5 SOQL for each call, for all chain lengths: anchor, range start, range end, count, page. The first generation has no range start query.
- A single generation costs one SOQL.
- The count is `SELECT COUNT() ... LIMIT`. It can use one query row for each counted row, so the cap keeps rows free for the page and 1,000 rows for the caller.
- The page query reads max page size + 1 rows. No long text field. No DML, no enqueue, no event.
- You can call it in all Apex contexts.

## Dashboard

Open an instance that has a previous or a next run. The detail pane shows **Continue-As-New Generations**:

- One row for each generation, newest first, with a status badge and the failure category.
- "Showing X of N generations". `N+` when the total is capped.
- Click the generation name (or press Enter on it) to open the step timeline of that generation. The list stays.
- **Show older generations** gets the next page. **Try again** reads the chain again after an error.
- Each poll refreshes the first page. New generations, and a late `compensate()` instance, show. Older pages that you loaded stay. After an error, only **Try again** reads again.

An instance with no previous and no next run shows no section and makes no extra call.

## Known Limits

- Do not use the root key for an independent run while the chain is not closed. The first generation of the old chain after that run stays in the old chain. Generations after it show in the list of the new run. `getStatus` has a related limit.
- A purge of old generations changes the numbers. `generation` counts from the oldest kept row. A purge in the middle of a chain splits it.
- A first generation with no correlation key is a chain of one row. Its successors use the key of the second generation as root.
- A legacy successor with a blank root uses its own key as root. It does not join its first generation.
- Page 1 always shows the newest generations. An old generation that you open from the main list can be on a later page.
- A cursor keeps the generation number of its row. A purge between two page calls can make later numbers wrong by the number of purged rows.
