# ADR 0018: Storage Footprint file scope

- **Status:** Accepted
- **Date:** 2026-09-30
- **Issue:** #228

## Context

The Storage Footprint panel added up `ContentSize` of files with an engine title
prefix (`Input_`, `Output_`, ...). A user file with such a title was counted.
A `ContentDocumentLink` filter needs all instance ids. That query exceeds the
50,000-row limit.

## Decision

1. `ContentVersion.Revenant_Payload_Offload__c` (checkbox) marks an offloaded
   file. `WorkflowBulkOffload` (used by `savePayloadIfNeeded`) and
   `WorkflowSignalPayloads` set it in system mode. `CsvArchiveSink` does not:
   archive files were never in this total.
2. The panel sums `ContentSize` where `IsLatest = TRUE` and the flag is true.
   It stays one aggregate query.
3. No Revenant permission set grants the field. Do not grant edit access to
   it. This follows `Revenant_Archive_Instance_Id__c`.
4. Titles, `CleanupDocumentPurger` and `global` API do not change.

## Consequences

- No false count from a user file.
- The engine wrote old files without the flag. The panel does not count them.
  New offloads are counted. The total is too low, never too high, so it cannot
  cause a false warning.
- The purger still finds files by title prefix. It can delete an old file that
  the panel never counted.
- A later job can set the flag on old files. It is not in this change.
