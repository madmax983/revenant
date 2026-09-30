# Storage Footprint File Scope Plan (Issue #228)

**Goal:** Count only engine-offloaded files in the Storage Footprint file
total. A user file with a title like `Input_notes` must not count.

**Architecture:** `savePayloadIfNeeded` and `WorkflowSignalPayloads` set a new
`ContentVersion` checkbox, `Revenant_Payload_Offload__c`. The footprint query
sums `ContentSize` where the checkbox is true. It stays one aggregate query.

---

## 1. Brainstorming

- **Link scope.** Filter by `ContentDocumentLink`. It needs the ids
  of all instances. Rejected (50,000-row limit).
- **Title with a GUID.** Write `Revenant-<guid>_` in the title. It touches
  the purger prefixes, `PathOnClient` and every title. A user can still copy
  the title. Rejected.
- **Marker field.** Same pattern as `Revenant_Archive_Instance_Id__c`. The
  engine sets it in system mode. No permission set grants access. One
  write-path line. The read stays one aggregate.
- **Rollup.** A job sums the files and stores the result. More code, old
  data, one more job. Rejected.
- **Accept the error.** Document it. Rejected: the issue asks for a fix.

## 2. Reverse brainstorming (how can it fail?)

| Failure | Mitigation |
|---|---|
| A user file sets the marker | The field has no permission set. Only system mode writes it. |
| A new offload path skips the marker | Two paths write offload files: `savePayloadIfNeeded` and `WorkflowSignalPayloads`. A test checks the flag for each. |
| Files from before this change lack the marker | They are not counted. Documented. New offloads are counted. |
| Purge deletes a file, total stays high | The query is live. No cache. |
| Query gets slower | Same shape as the title query. One aggregate, no row limit. |
| Old versions are counted twice | Keep `IsLatest = TRUE`. |
| Package install fails on the new field | The archive fields use the same object and field type. |

## 3. Six thinking hats

- **White (facts):** The offloader and the signal payload helper write offload files. The
  title query over-counts a user file. `ContentDocumentLink` needs an id set.
- **Red (feel):** Operators trust a warning only if the number is right. A
  false alarm costs trust.
- **Black (risk):** Old files are not counted. The panel shows an
  estimate only, so the low total is safe.
- **Yellow (benefit):** The number is exact for new files. No collision is
  possible. No new job and no new row scan.
- **Green (ideas):** A later backfill job could set the flag on old files by
  title and link. Not in this issue.
- **Blue (process):** Write the tests first (scope, write path, old versions).
  Then add the field and the code edits. Then write the docs and review.

## 4. Decision

Use the marker field. Do not change titles or the purger.

## 5. Tasks

1. RED: footprint test, unflagged file with an engine title is not counted.
2. RED: footprint test, flagged file is counted and a superseded version is not.
3. RED: `savePayloadIfNeeded` and the signal helper set the flag. Small
   payloads write no file.
4. GREEN: add the field. Set it in both writers. Filter on it.
5. REFACTOR: trim the old comment. Update README and add ADR 0018.
6. Review from several angles. Fix findings.
