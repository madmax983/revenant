# Navigable Continue-As-New Chain (Issue #116)

## Goal

Show all generations of a Continue-As-New chain as one ordered list. Give the list to Apex callers and to the dashboard. Keep the read bounded and read-only.

## Facts About The Engine

- Each generation is one `Workflow_Instance__c`. The successor has `Previous_Instance__c` = predecessor Id.
- The successor copies `Root_Correlation_Key__c` from the predecessor. A trigger sets the root to `Correlation_Key__c` on insert when it is blank. Thus each independent run with the same key has the same root.
- The external Id flag indexes `Root_Correlation_Key__c` and `Correlation_Key__c`.
- `Previous_Instance__c` uses `SetNull` on delete. A purge of a predecessor makes the successor look like a first generation.
- The trigger sets `Terminal_At__c` when the status becomes `Completed`, `Failed`, `Compensated`, `Cancelled` or `ContinuedAsNew`. It clears the value for other statuses.
- `compensate()` on a completed instance inserts a new instance with `Previous_Instance__c` = target and the same root.
- `COUNT()` uses one query row. `LIMIT` stops the scan.
- SOQL `OFFSET` stops at 2,000 rows. `WorkflowInstanceQuery` uses a `(CreatedDate, Id)` keyset cursor.
- Read contracts live on their own classes (`WorkflowStatusRead`, `WorkflowHistoryRead`, `WorkflowInstanceQuery`). The DTOs live on `WorkflowEngine`.
- The dashboard detail already reads `Previous_Instance__c` and one successor.

## Brainstorming (options)

| # | Idea | Keep? |
|---|------|-------|
| B1 | Walk `Previous_Instance__c` one link for each query. | No. SOQL grows with chain length. |
| B2 | Walk 5 links for each query with relationship paths. | No. Still not constant. |
| B3 | New field `Chain_Root_Id__c`. | No. Schema change is out of scope. Old rows have no value. |
| B4 | Scope = same `Root_Correlation_Key__c` and same `Workflow_Name__c`. | Yes. Indexed. Constant SOQL. |
| B5 | Split the scope at each first generation (`Previous_Instance__c` = null). The chain of a member is the window from the nearest first generation at or before it to the next first generation after it. | Yes. An independent run that uses the key again after the chain gets its own window. Two `LIMIT 1` queries. |
| B6 | Order `CreatedDate DESC, Id DESC`. Keyset cursor. | Yes. Same order as `findInstances`. No `OFFSET` limit. |
| B7 | `OFFSET` paging. | No. It stops at 2,000. |
| B8 | Total with `SELECT COUNT() ... LIMIT :cap`. Flag `isTotalCapped`. | Yes. One query row. |
| B9 | Generation number counts from the oldest kept row (1). Page 1: top row = total. Next page: the cursor keeps the number of its last row. | Yes. A new head generation does not change old numbers. No second count. |
| B10 | Generation number = null when the total is capped. | Yes. The number is not known. Do not show a wrong number. |
| B11 | Anchor query gets `(SELECT Id FROM Next_Runs__r LIMIT 1)`. No predecessor and no successor: return one entry. | Yes. A single generation costs one query. |
| B12 | Legacy row with a blank root: use its `Correlation_Key__c` as the root. Match `Root = key OR (Root = null AND Key = key)`. | Yes. Same fallback as `WorkflowContinueAsNew`. |
| B13 | Put the method on `WorkflowEngine`. | No. Read contracts use their own class (see MIGRATION.md). New class `WorkflowChainRead`. DTOs on `WorkflowEngine`. |
| B14 | Request object `ChainRequest` (key or Id, page size, cursor). | Yes. Same style as `InstanceCriteria`. |
| B15 | Dashboard: load the chain only when the instance has a predecessor or a successor. | Yes. A single generation makes no extra call. |
| B16 | Dashboard: keep the list when the operator selects a generation that is in the list. | Yes. Deep pages stay open. |
| B17 | Dashboard: merge step rows of all generations. | No. Out of scope. Each row links to the existing timeline. |

## Reverse Brainstorming (how can this fail?)

| Way to fail | Prevention |
|-------------|-----------|
| A long chain uses too many SOQL queries. | Constant query count: max 5. A test compares a 3-row and a 30-row chain. |
| A long chain uses too many query rows or too much heap. | Page cap 200. `COUNT()` uses one row. No long text field. |
| Two members give different chains. | Same window rule for each member. A test reads from each member. |
| An independent run with the same key joins the chain. | Window split at each first generation (B5). A test. |
| A different workflow with the same key joins the chain. | Filter on `Workflow_Name__c`. A test. |
| A new generation during paging makes duplicate or missing rows. | Keyset cursor. Numbers count from the oldest row. |
| A bad cursor reads wrong rows. | Decode checks the format. A bad cursor throws `WorkflowException`. |
| A page size of 0 or 10,000. | 0 or less throws. More than 200 is clamped. |
| The read changes data. | No DML, no enqueue, no event. A test checks `Limits`. |
| The count scan is too long. | `LIMIT :MAX_COUNTED_GENERATIONS` (50,000). |
| An operator without access reads the chain. | Controller calls `checkAuthorization()`. A test. |
| Equal `CreatedDate` values. | `Id` breaks the tie in the order, the window and the cursor. |

## Six Thinking Hats

- **White (facts):** See "Facts". No schema change. No change to the Queueable hand-off.
- **Red (feelings):** Operators want to see "where did it go wrong" fast. Status badges and a failure category on each row help.
- **Black (risks):** Key reuse while a chain is live mixes chains. This limit is already in the README for `getStatus`. Keep it and write it down. Purged predecessors split a chain. Numbers then count from the oldest kept row.
- **Yellow (benefits):** One indexed scope. Constant SOQL. Reuses the timeline and the paging style of `findInstances`.
- **Green (ideas):** A later issue can add a chain root Id field for exact membership.
- **Blue (process):** Plan, RED tests, GREEN code, refactor, docs, agent review, AC evidence.

## Design

`WorkflowChainRead.getChain(Id)`, `getChain(String correlationKey)` and `getChain(WorkflowEngine.ChainRequest)` return `WorkflowEngine.ChainPage`, or null when no instance matches.

Steps:

1. Check the page size and decode the cursor.
2. Anchor: the cursor anchor, else the Id, else the newest row with `Correlation_Key__c = key OR Root_Correlation_Key__c = key`.
3. No predecessor and no successor, or no root: return one entry.
4. Start: the anchor when it has no predecessor. Else the newest first generation in scope before the anchor.
5. End: the anchor when it has no successor. Else the oldest first generation in scope after the anchor.
6. Total: `COUNT()` in the window, `LIMIT` 50,000.
7. Page: rows in the window (and after the cursor), `LIMIT pageSize + 1`.

Dashboard: `WorkflowDashboardController.getInstanceChain(instanceId, cursor)` maps the page to a `Map`. The LWC shows a "Continue-As-New Generations" section, "X of N generations", and "Show older generations".

## Changes After Review

Five review agents (correctness, governor and security, tests, LWC, API and docs) gave these changes:

- Typed input: `getChain(Id)` and `getChain(String)`. No shape guess, no fallback query. Max 5 SOQL.
- `continuedAt` removed: same value as `endedAt`.
- The cursor keeps the anchor. A range check on each cursor field. No internal text in the error.
- An anchor with no successor ends the window: one query less for the live generation.
- LWC: no reload on each poll, reload when the selected row is stale, clear the old chain at once, "Try again", reset when a panel hides the pane, buttons for keyboard access, scroll position kept.
