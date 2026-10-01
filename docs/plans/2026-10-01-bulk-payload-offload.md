# Bulk Payload Offload Plan (Issue #244)

**Goal:** Bulk start, bulk child start and bulk resume must not use more DML
or SOQL when more rows have large payloads.

**Architecture:** A new `WorkflowBulkOffload.save` takes a list of items. It
inserts all files in one DML, reads the document ids in one query, and inserts
all links in one DML (with the AllUsers retry). `savePayloadIfNeeded` calls it
with one item. The three loops build items, then call it once.

---

## 1. Brainstorming

- **New helper class.** One place for file, query and link code. Chosen.
- **Add a list overload to `WorkflowPayloadOffload`.** The class is already
  large and is a read seam. Rejected.
- **Reuse `WorkflowSignalPayloads.offloadOversized`.** It is typed to signal
  rows, skips the identity codec, and tracks files for cleanup. Rejected.
  Share only the link insert with it.
- **Cap the offload per call.** Hides the problem. Rejected.

## 2. Reverse brainstorming (how can it fail?)

| Failure | Mitigation |
|---|---|
| Identity codec changes behavior | Same threshold, title, marker and flag as before. Test with the identity codec. |
| Output order differs from input order | The helper returns values index-aligned. Test checks each marker. |
| One row links to the wrong instance | Each item carries its own owner id. Test checks links. |
| Small rows write a file | Only rows over 100 000 characters write a file. Test checks the file count. |
| Link retry runs for all rows | Retry only the failed links. Same logic as the signal helper. |
| A row with null text breaks the batch | Blank text passes through unchanged. Test. |
| Resume row has no step execution | Only rows with a step execution make an item. |

## 3. Six thinking hats

- **White (facts):** Each offloaded row costs 1 SOQL and 2 DML today. Signal
  payloads already use a bulk pattern (#99).
- **Red (feel):** A bulk call that fails at row 80 with a limit error is
  painful and hard to explain.
- **Black (risk):** The single-row path changes too. Its tests must stay green.
- **Yellow (benefit):** Fixed cost: 2 DML and 1 SOQL for any row count.
- **Green (ideas):** The signal helper could use the same class later.
- **Blue (process):** Write the tests first. Then the helper. Then the three
  loops. Then docs and review.

## 4. Decision

Add `WorkflowBulkOffload`. Keep `savePayloadIfNeeded` as a one-item wrapper.

## 5. Tasks

1. RED: helper tests (many large items, order, small items, blank, titles,
   flag, identity, AllUsers link retry).
2. RED: bulk start, child start and bulk resume with many large payloads. DML
   count must not grow with the row count.
3. GREEN: add the helper. Use it in the three loops and in
   `savePayloadIfNeeded`.
4. REFACTOR: the signal helper uses the shared link insert. Update docs.
5. Review from several angles. Fix findings.
