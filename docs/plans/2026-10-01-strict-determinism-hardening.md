# Harden Strict Determinism Mode (Issue #256)

## Goal

Remove the false positive from an edited live signal. Remove two "unknown inputs" gaps. Keep each other item with a reason in ADR 0003.

## Constraint

This session has no org and no `sf` CLI. The Apex tests are written but not run here. The validation items of #256 stay open.

## Brainstorming

| # | Idea | Keep? |
|---|------|-------|
| B1 | Trigger: live signals are immutable. | No. It blocks a legal admin edit and adds a trigger to the package. |
| B2 | Digest the stored name and payload of each live signal. | Yes. A legal edit changes the inputs. No false positive. |
| B3 | Child statuses with one aggregate query (`GROUP BY Status__c`). | Yes. No row cap. No unknown inputs. |
| B4 | Over the signal cap: digest the oldest rows plus the total count. | Yes. A new arrival changes the inputs. |
| B5 | Over the signal cap: use `SystemModstamp`. | No. A claim changes it (see commit 1cbdf99). |
| B6 | Re-check only the signals that the step read. | No. See ADR 0003. |
| B7 | Leave wait bookkeeping out of the inputs. | No. See ADR 0003. |

## Reverse Brainstorming (how to make it worse)

- Digest the decoded payload: a plaintext digest defeats the payload codec. **Avoid:** digest the stored form.
- Read all payloads without a limit: heap overflow. **Avoid:** a payload budget. Over it, the inputs are unknown.
- Add `SystemModstamp`: hides every parallel divergence. **Avoid.**
- Change the digest format without care: an old record has other inputs. **Check:** the engine reads it as new inputs. It records again. No false positive.
- Change the SOQL count of the off path. **Avoid:** the off path stays free.

## Six Hats

- **White (facts):** `Payload__c` is long text (131,072). `Revenant_Admin` can edit it. No trigger blocks it. Before this change, the digest held only Id and status.
- **Red (feeling):** A false positive fails a live instance. Trust is lost. A false negative is quiet. Fix the false positive first.
- **Black (risk):** Heap from payloads. An old record after a deploy. A changed query count. No org to run tests.
- **Yellow (benefit):** A legal route change is not reported. Children have no cap. Big backlogs still compare.
- **Green (new idea):** An aggregate for children. A count for the signal overflow.
- **Blue (process):** Red tests first. Then the code. Then docs. Then a review from four angles.

## Decisions

| Item of #256 | Result |
|--------------|--------|
| Edited live signal | **Fixed.** Digest name and payload. |
| More than 200 live signals | **Fixed.** First rows plus total count. |
| More than 2000 children | **Fixed.** Aggregate by status. |
| Payload heap | **Reduced.** Cap of 200 rows. Budget of payload characters. |
| Wait bookkeeping, codec, offload | Kept. See ADR 0003. |
| Compensated divergence category | Kept. See ADR 0003. |
| `$timeoutResume` marker | Kept. See ADR 0003. |
| Fanout examples | Kept. See ADR 0003. |
| Full re-check scope | Kept. See ADR 0003. |
| Org validation (3 items) | Open. Needs an org. |

## Tests (red first)

1. A name edit of a live signal changes the inputs.
2. A payload edit of a live signal changes the inputs.
3. Over the signal cap: the inputs are known, and a new arrival changes them.
4. Over the payload budget: the inputs are unknown.
5. A claim, a null payload and a foreign claim change the digest correctly.
6. Engine: a payload edit of a live signal is not a divergence.
7. Many children: the inputs are known, and a status change changes them.
8. Cost: two SOQL queries in the normal path (existing test).
