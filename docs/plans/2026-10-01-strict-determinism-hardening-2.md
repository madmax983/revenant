# Harden Strict Determinism Mode, Part 2 (Issue #256)

## Goal

Fix the false negatives that remain in #256 and have a safe fix. Keep each other item with a reason in ADR 0003. Part 1 is `2026-10-01-strict-determinism-hardening.md`.

## Constraint

This session has no org and no `sf` CLI. The Apex tests are written but not run. `apex-ls` compiles the code. The validation items of #256 stay open.

## Brainstorming

| # | Idea | Keep? |
|---|------|-------|
| B1 | Re-check only the signals that the step read. | Yes. Fixes two false negatives. |
| B2 | Re-check the names that the step probed (also absent names). | Yes. A probed name can get a new signal. |
| B3 | Digest the `Checksum` of an offloaded file. | Yes. Equal content gives an equal digest. No heap cost. |
| B4 | Digest the decoded text of an offloaded file. | No. Heap cost. Plaintext digest. |
| B5 | Leave the marker Id out of the digest. | No. Different content then gives equal inputs: a false positive. |
| B6 | Keep `$timeoutResume` in the stored input. | No. Seven copy sites carry it into compensation rows. |
| B7 | Wait bookkeeping out of the inputs. | No. See ADR 0003. |
| B8 | Show the log count on the dashboard. | No. The divergent step row is `Failed`. The breakdown already counts it. Add a test. |
| B9 | Move the fanout examples to `getChildOutcomes`. | No. They spawn by hand and yield. A new design. |

## Reverse Brainstorming (how to make it worse)

- Re-check by name only: a signal edit that the step read goes unseen. **Avoid:** match by Id and by name.
- Ignore every change when the step read all signals: a read-all step hides nothing. **Avoid:** any arrival counts after `getSignals()`.
- Trust a marker from a step: it can name a file of another instance. **Avoid:** read a checksum only for a file linked to the instance.
- Use a null checksum as a value: two files with no checksum look equal. **Avoid:** a null checksum keeps the marker text.
- Query the checksum for each run: the off path pays. **Avoid:** no query when the mode is off or no marker exists.
- Narrow the first digest too: the step has not run, so the read set is unknown. **Avoid:** narrow the re-check only.

## Six Hats

- **White (facts):** The re-check compares the digest of the full live-signal set. `StepSignals` tracks matched Ids. It does not track probed names. `ContentVersion.Checksum` holds the MD5 of the file. A failed step row shows in the failure breakdown.
- **Red (feeling):** A false positive fails a live instance. A false negative is quiet. Keep the change small. Err toward "no report".
- **Black (risk):** No org to run the tests. `Checksum` can be null in a test. A name rule that differs from the loader causes a false positive. A claim changes a signal status.
- **Yellow (benefit):** A step that inserts an unread signal no longer hides its own route change. Offloaded state compares again.
- **Green (new idea):** Compare snapshots by Id. Count a change only when the step read that Id or probed its name.
- **Blue (process):** Red tests. Green code. Refactor. Docs and ADR. Review from several angles.

## Decisions

| Item of #256 | Result |
|--------------|--------|
| Full re-check of live signals | **Fixed.** Read set plus probed names. |
| Offloaded step state | **Fixed.** Digest the file checksum. |
| Compensated divergence category | Kept. The breakdown shows the failed step row. Test added. |
| Wait bookkeeping | Kept. See ADR 0003. |
| Payload codec | Kept. See ADR 0003. |
| `$timeoutResume` marker | Kept. New reason: compensation copies. |
| Fanout examples | Kept. New reason: manual spawn. |
| Org validation (3 items) | Open. Needs an org. |

## Tests (red first)

1. A change to an unread signal does not count in the re-check.
2. A change to a signal that the step read counts.
3. A new signal with a probed name counts, also when the step saw none.
4. After `getSignals()`, any arrival counts.
5. A claim of this run does not count.
6. A child or base change counts.
7. Two files with equal content give an equal digest. Different content gives a different digest. A file of another instance keeps the marker.
8. Engine: a step that inserts an unread signal and changes its route is a divergence.
9. Engine: a step that reads the new signal is not a divergence.
10. Engine: offloaded step state still compares.
11. Engine: a compensated divergence shows in the failure breakdown.
