# ADR 0010: Global admission brake

- **Status:** Accepted
- **Date:** 2026-09-29
- **Issue:** #136

## Context

The org shares async Apex capacity with other Apex and packages. When it is
full, the next `System.enqueueJob()` throws and the chain stops. #129 shows the
capacity. #91 caps one definition. Nothing parks new starts for all
definitions. The issue permits no new object, no new scheduled job and no
change to the in-flight handoff.

## Decision

1. Three fields on `Revenant_Config__mdt` `Default`: `Emergency_Stop__c`,
   `Auto_Brake_On_Capacity__c` and `Global_Max_Active_Instances__c`. The
   config read costs no SOQL, so with all three off the start path is the same
   as before.
2. The emergency stop is a config field, not a data row. A data row costs one
   SOQL on each start in each org. A deploy from System Doctor needs async
   capacity, which can be full when the operator needs the stop.
3. The global count is a reserved `Concurrency_State__c` row, `$global`. It
   uses the #91 `FOR UPDATE` pattern. The definition reconcile and the
   Concurrency Limits panel skip this row.
4. One text field `Workflow_Instance__c.Global_Admission__c` (external id, so
   indexed) holds `Awaiting`, `Parked` or `Held`. One field cannot hold two
   states that conflict.
5. The start reads the brake with no lock. Braked: the start is `Suspended`
   and `Parked`, and the engine does not enqueue the first hop. Open with a
   ceiling: `Awaiting`. The first hop takes the slot under the instance lock
   and the counter lock.
6. The gate parks a braked start before the definition gate, so it takes no
   definition slot. It takes the global slot after the definition slot. If the
   ceiling is full, it gives back the definition slot. Lock order: instance
   row, definition row, then `$global`.
7. A parked start has a due sleep time and no timer job. The main sleep query
   does not select it. A second, bounded query sends parked starts to the
   gate, oldest first, max the free slots. While braked, it sends none.
8. With a ceiling and a parked backlog, a new start parks behind the backlog
   and wakes the oldest parked starts with one #132 admit-only wake. Thus the
   order is first in, first out, and a free slot does not wait for the sweep.
9. A parked start stays out of the #132 definition queue, so it cannot make a
   definition candidate yield.
10. Release on the first terminal transition. Continue-As-New moves the slot to
    the successor. An operator retry takes a slot and does not park. The
    heartbeat reconciles the count to the non-terminal `Held` rows.
11. In the heartbeat, a terminal transition does not lock `$global`. The
    reconcile runs last and applies it. Thus the heartbeat does not hold
    `$global` while it locks instance rows.
12. A failed counter lock at the gate admits the start as `Held`. The
    reconcile counts it.
13. Children, starts with a parent, Continue-As-New successors, manual
    compensate instances and engine workflows are exempt.
14. The auto-brake uses the #129 read
    (`WorkflowAsyncCapacityService.currentStatus`). It engages on
    **Critical** only. **Unknown** fails open.
15. The heartbeat audits emergency stop changes with an `OperatorIntervention`
    `Workflow_Log__c` row. It keeps the last value it saw on the `$global` row.
16. A parked start calls the watchdog bootstrap, because only the watchdog
    sweep re-drives it.
17. System Doctor gets a child LWC (`globalAdmissionPanel`) and a new
    controller, because `WorkflowDashboardController` is at the PMD limit.

## Consequences

- An org with no control set sees no change at admission: no SOQL, no marker,
  no DML. The heartbeat adds max 2 SOQL (the parked-start read and the
  `$global` lock).
- A governed start costs max +3 SOQL for each transaction. A scalar start
  adds no DML. A bulk start adds 1 DML.
- An `Awaiting` start takes one more hop at admission, as a #91 start does.
- A parked start waits up to one watchdog interval after the brake opens,
  unless a new start wakes it first.
- The ceiling does not count children, engine workflows or instances from
  before the ceiling.
- The audit row has the time that the watchdog saw the change. Setup Audit
  Trail has the user. A change and a release between two sweeps give no row.

## Rejected Options

- Take the slot in the start transaction: a lock on one row in the caller's
  transaction serializes all starts and can throw `UNABLE_TO_LOCK_ROW` into
  the caller.
- `COUNT()` of active instances on each start: the cost grows with the data.
- A timer job for each parked start: it uses scheduled-job slots and async
  capacity while the capacity is full.
- Gate children: a parent holds a slot and waits for its child. With a full
  ceiling this is a deadlock.
- Release and take again on Continue-As-New: the successor can park, so a
  running chain stops.
- A custom setting for the emergency stop: it is a new custom object.
- Brake on **Unknown** capacity: a failed read would stop all new starts.
- Parked starts in the main sleep query: a large backlog fills the 200-row
  batch and delays in-flight sleepers.
- Admit a new start below the ceiling while older starts are parked: the
  parked starts can wait with no limit.
