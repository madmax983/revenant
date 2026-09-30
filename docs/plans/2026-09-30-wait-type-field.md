# Wait Type Field (Issue #229)

## Goal

Let the instance list show the wait type (approval, child, generic) for a signal wait. The list must not read `Output__c`.

## Facts

- The wait type is only in `Output__c`. The list cannot read it (heap limit, issue #84).
- Four handlers in `WorkflowStepSuspension` park a step as Pending for a signal: suspend, approval, start-child, start-children. Sleep also parks a Pending step but has a timer.
- A resumed step reuses its row. A stale value can stay on the row.
- Existing parked rows have no value.
- The author has no org. Node tests run here. Apex tests run in CI.

## Brainstorm

| #   | Idea                                              | Keep?                                                   |
| --- | ------------------------------------------------- | ------------------------------------------------------- |
| B1  | Text field `Wait_Type__c` on the step row.        | Yes. Same row the list already queries. No extra SOQL.  |
| B2  | Field on the instance.                            | No. Parallel branches can park with different types.    |
| B3  | Also store the awaited signal name.               | No. Long keys. The detail view has the name. Follow-up. |
| B4  | Picklist field.                                   | No. The type constants already exist in Apex.           |
| B5  | Backfill job for old rows.                        | No. A null value shows the old generic label.           |
| B6  | Clear the field when the step runs again.         | Yes. Prevents a stale label.                            |
| B7  | Show timed approvals as signal waits on the list. | No. Out of scope. Separate issue.                       |

## Reverse Brainstorm (how can this fail?)

| Way to fail                                        | Prevention                                                   |
| -------------------------------------------------- | ------------------------------------------------------------ |
| Old row has null. List shows no label or an error. | Null gives the generic label. Test.                          |
| Stale type after resume and sleep.                 | Clear in the step lock and in the sleep handler. Test.       |
| Unknown value in the field.                        | Unknown value gives the generic label. Test.                 |
| Users cannot read the field.                       | Add field permission to both permission sets. Node test.     |
| Report type misses the field.                      | Add a report column. Existing node test forces the decision. |
| List reads more data.                              | Keep one query. Existing query-count tests stay green.       |

## Six Hats

- White: one new text field, four writes, two clears, one list label map.
- Red: the operator wants to see "approval" without opening each row.
- Yellow: no extra SOQL. No heap cost. No backfill.
- Black: a write path in the engine. Mitigate with a small change and tests.
- Green: add the awaited name later in a second field.
- Blue: RED tests first, then GREEN, then REFACTOR, then review.

## Design

- Field `Workflow_Step_Execution__c.Wait_Type__c`: Text(20). Values: `approval`, `child-completion`, `generic-signal`.
- Write the value in the four signal handlers. Clear it in the sleep handler and in the step claim.
- The list query selects `Wait_Type__c`. The label depends on the type. Null or unknown gives the generic label.
- Permission sets: Admin read and edit. Operator read.
- Report type: add the column (not checked by default).

## Tests

- Apex: handler writes (4), sleep clears, claim clears, list label (approval, child, generic, null, unknown).
- Node: permission sets and report type cover the field.
