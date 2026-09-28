# Strict Determinism Mode

Issue #102. The engine can find a step that makes a different routing decision when it runs again with the same inputs. It fails the instance before the decision is written. Use this mode in development and staging.

## Why a step runs again

The engine runs `execute()` again on the same step row after these results:

- `SUSPEND`, `WAIT_FOR_APPROVAL`, `START_CHILD` and `START_CHILDREN`. A signal, an approval, a child outcome or a resume wakes the step. A duplicate delivery, an operator resume or a reclaim also wakes it, with no new input.
- `SLEEP`, `YIELD` and `RETRY`. The engine runs the step again later.

Each run must make the same decision from the same inputs. A step can read data that changes, without `once()`. The next run can then route to another step. The history and the compensation stack then do not agree with the work that the step did.

## Replay-safe operations

| Operation in `execute()` | Replay-safe? | What to do |
|--------------------------|--------------|------------|
| Read `ctx.workflowInputJson`, `ctx.inputJson`, `ctx.previousStepOutput` | Yes | - |
| Read `ctx.stepStateJson` (also a resume payload) | Yes | - |
| Read `ctx.attempt`, `ctx.isFinalAttempt()`, `ctx.idempotencyKey` | Yes | - |
| Read signals, approvals, child outcomes (`ctx.signals()`) | Yes | - |
| Read a value from `ctx.captures().once(...)` | Yes | - |
| `ctx.shouldYield()` | No | Return `YIELD` only. Do not use it to select a wait. |
| `Datetime.now()`, `Date.today()`, `System.now()` | No | Wrap in `once()`. |
| `Crypto` random values, generated ids or UUIDs | No | Wrap in `once()`. |
| SOQL on records that other processes change | No | Wrap the value in `once()`. Or make the other process send a signal. |
| SOQL on child `Workflow_Instance__c` status | No | Use `ctx.signals().getChildOutcomes(...)`. |
| A callout response that routes the step | No | Wrap the result in `once()`. |
| A branch on user, org or custom setting data that can change | No | Wrap in `once()`. |

A value in `once()` does not change between runs. Thus, a decision that uses it does not change.

A waiting step must repeat the same wait until a new input arrives.

## Turn on the mode

On the **Default** record of `Revenant_Config__mdt`, select the `Strict_Determinism__c` check box. The default is off.

The Default record is in the source. A deploy of the source sets the mode to off again. Set it again after each deploy.

In an Apex test, set `WorkflowEngine.strictDeterminism = true`.

## Cost

When the mode is off, the engine does no SOQL and no extra DML statement for it. It clears an old record in the step row save that occurs anyway.

When the mode is on, each step run costs:

- Two SOQL queries: the live signals, and the child status counts.
- One query row for each live signal (`Received` or `Processing`) and each child instance, also a closed child.
- One SHA-256 digest of the stored inputs.

## What the engine records

The engine records a wait decision in `Workflow_Step_Execution__c.Decision_Record__c`. The wait handler saves the row, so the record costs no extra DML.

| Key | Value |
|-----|-------|
| `v` | Format version (`1`). |
| `inputs` | SHA-256 digest of the step inputs before the run. |
| `decisionHash` | SHA-256 digest of the full decision text. |
| `decision` | The decision text. Max 255 characters. |

The step inputs are:

- The stored step input, previous output and step state. A resume payload is step state. Stored forms are encoded or offloaded. The digest holds no decoded payload.
- `ctx.attempt` and the timeout-resume flag.
- The live signals of the instance (`Received` or `Processing`): Id and status. Signals carry approvals and child outcomes.
- The status counts of the child instances.

Captures are not inputs. A `once()` value is stable by contract.

A wait can write new step state. The next run then has new inputs, and the engine records again. After such a wait, the engine compares from the second duplicate run.

The decision text holds routing data only. Each value is JSON.

| Action | Decision text |
|--------|---------------|
| `COMPLETE` | Next step hint and the compensation flag. |
| `SPLIT` | Sorted target steps. |
| `SUSPEND` | Timeout step. |
| `WAIT_FOR_APPROVAL` | Key, role and timeout step. |
| `START_CHILD` | Child workflow and key. |
| `START_CHILDREN` | Sorted child workflows and keys. |
| `FAIL`, `CONTINUE_AS_NEW` | The action name. |

The decision text does not include payloads, step state or durations. The engine records only wait decisions. The text of other decisions shows in the error message.

`RETRY`, `SLEEP` and `YIELD` are not decisions. The engine keeps the record and compares the next decision. `RETRY` increases the attempt, so the next run has new inputs. A thrown error is not a decision.

## What the engine checks

```mermaid
flowchart TD
    A[Hydrate StepContext] --> S{Strict mode on?}
    S -- no --> Z[Clear record] --> P[Pass]
    S -- yes --> B[Digest inputs]
    B --> C[execute]
    C --> D{Thrown error or RETRY, SLEEP, YIELD?}
    D -- yes --> P
    D -- no --> E{Record with equal inputs?}
    E -- no --> F{Wait decision?}
    F -- yes --> R[Record decision] --> P
    F -- no --> X[Clear record] --> P
    E -- yes --> G{Same decision?}
    G -- yes --> P
    G -- no --> H[Divergence]
    H --> I[Re-lock, stale guard]
    I --> J[Step row Failed, Error log row]
    J --> K[failWorkflowInstance: STEP_NON_DETERMINISM]
```

## What a divergence does

1. The engine sets the step row to `Failed`. `Error_Details__c` shows the recorded and the new decision.
2. The engine writes an Error `Workflow_Log__c` row with `Log_Type__c` = `StepNonDeterminism`.
3. The engine fails the instance through the normal failure path:
   - No compensation stack: `Failed`, with `Failure_Category__c` = `STEP_NON_DETERMINISM`.
   - A compensation stack: LIFO rollback. The category stays blank.
   - An `ErrorRoutingWorkflow`: the error step. `StepError.errorMessage` starts with `Step non-determinism: `.

The engine does not write a new step row. It does not push the step onto the compensation stack. It does not publish the buffered step events. Claimed signals go back to `Received`. Other observed signals stay `Received`.

To find all divergences, query the log rows. The query also finds divergences that error routing or compensation handled:

```sql
SELECT Workflow_Instance__c, Message__c, CreatedDate
FROM Workflow_Log__c
WHERE Log_Type__c = 'StepNonDeterminism'
```

## When the engine clears a record

- An operator retry, and a re-drive of a parallel branch.
- A release of a `DefinitionChanged` instance.
- A step run while the mode is off.

Correct the step code before you retry. A deploy of changed step code can change the decision of a waiting step. Turn the mode off until the waiting instances move on.

## Limits

- The engine compares only when the inputs are equal. The engine does not compare a run that follows a new input.
- The engine does not check side effects that do not change routing.
- The engine does not check `compensate()`.
- With a payload codec, each wait that writes step state writes new stored state. The engine then compares less often.
- An approval, child or timed wait writes step state. The first duplicate run after it has new inputs. The engine compares from the second duplicate run.
