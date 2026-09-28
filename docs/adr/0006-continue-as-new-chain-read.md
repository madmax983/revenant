# ADR 0006: Continue-As-New chain read

- **Status:** Accepted
- **Date:** 2026-09-28
- **Issue:** #116

## Context

Each Continue-As-New generation is a new `Workflow_Instance__c`. The dashboard and `getHistory` show one generation. `getStatus` follows the chain only to the last outcome. An operator cannot see where a perpetual workflow started to fail. A daemon chain can have tens of thousands of generations.

## Decision

1. New read class `WorkflowChainRead` with `getChain(Id)`, `getChain(String)` and `getChain(ChainRequest)`. DTOs `ChainRequest`, `ChainPage` and `ChainGeneration` on `WorkflowEngine`. Same pattern as `WorkflowStatusRead`, `WorkflowHistoryRead` and `WorkflowInstanceQuery`.
2. Scope: same `Workflow_Name__c` and same root key (`Root_Correlation_Key__c`, or `Correlation_Key__c` when the root is blank). Indexed.
3. Window: from the nearest first generation (`Previous_Instance__c` = null) at or before the anchor, to the next first generation after it. Max two `LIMIT 1` queries. An anchor with no successor ends the window.
4. Order `CreatedDate DESC, Id DESC`. Keyset cursor. Page max 200. The cursor keeps the anchor, so later pages stay on the same chain.
5. Total: `SELECT COUNT() ... LIMIT 50,001`. Flag `isTotalCapped`.
6. `generation` counts from the oldest kept row. The cursor keeps the number of its row. Null when the total is capped.
7. The anchor query has a `Next_Runs__r` subquery. No predecessor and no successor: one row, one SOQL.
8. Dashboard: `getInstanceChain(instanceId, cursor)`. The LWC loads it only for an instance with a previous or next run.

## Consequences

- Max 5 SOQL for each call. No DML.
- No schema change. No change to the Queueable hand-off.
- An independent run that uses the key again after the chain is a separate chain.
- A run that uses the root key while the chain is not closed splits the chain.
- A purge changes the numbers. A purge in the middle of a chain splits it.

## Rejected Options

- Walk `Previous_Instance__c` one link at a time: SOQL grows with the chain.
- A new chain root Id field: schema change, out of scope. Old rows have no value.
- `OFFSET`: the max offset is 2,000 rows.
- Scope on the root key only: an independent run with the same key joins the chain.
- Method on `WorkflowEngine`: read contracts use their own class.
- One `keyOrId` string: a key with the shape of an Id is not clear. Typed overloads, as in `getStatus`.
- A `continuedAt` field: the same value as `endedAt` with outcome `ContinuedAsNew`.
