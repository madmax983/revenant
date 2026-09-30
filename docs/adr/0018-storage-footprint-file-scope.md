# ADR 0018: Storage Footprint file scope

- **Status:** Accepted
- **Date:** 2026-09-30
- **Issue:** #228

## Context

The Storage Footprint panel summed `ContentSize` for files with an engine title
prefix (`Input_`, `Output_`, ...). A user file with such a title was counted.
A link filter (`ContentDocumentLink`) needs the full instance id set. That
breaks the 50,000-row limit.

## Decision

1. `ContentVersion.Revenant_Payload_Offload__c` (checkbox) marks an offloaded
   file. `WorkflowPayloadOffload.savePayloadIfNeeded` sets it in system mode.
2. The panel sums `ContentSize` where `IsLatest = TRUE` and the flag is true.
   It stays one aggregate query.
3. No permission set grants the field, so a user cannot set it. This follows
   `Revenant_Archive_Instance_Id__c`.
4. Titles, `CleanupDocumentPurger` and `global` API do not change.

## Consequences

- No false count from a user file.
- Files that the engine offloaded before this change have no flag. The panel
  does not count them until the engine writes them again. The total is
  low, not high, so it cannot cause a false warning.
- A later job can set the flag on old files. It is not in this change.
