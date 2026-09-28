# ADR 0003: Pluggable archive sink before purge

- Status: Accepted
- Date: 2026-09-28
- Issue: #105

## Context

`CleanupWorkflow` deletes terminal instances and their step history. Audits
need that history for years. Primary data storage is expensive. The issue
asks for a Big Object tier. Some orgs want other cold stores, for example S3.

## Decision

1. Add a public `WorkflowArchiveSink` interface: `write`,
   `readByInstanceIds` and `readByCorrelationKey`.
2. Ship two sinks: `BigObjectArchiveSink` (default) and `CsvArchiveSink`
   (one CSV `ContentVersion` for each instance).
3. Add `Revenant_Config__mdt` fields: `Archive_Enabled__c` (off by default),
   `Archive_Sink__c` (class name, blank is the Big Object sink) and
   `Archive_After_Days__c` (default age for `ArchiveWorkflow`).
4. `WorkflowArchiveSweep` holds the sweep. For each chunk it reads (SOQL
   only), calls `sink.write`, then deletes files, signals and instances.
5. `ArchiveWorkflow` runs the sweep. Its step is a `CalloutStep`, so a sink
   can call out. `CleanupWorkflow` also archives first when archival is on.
6. Fail closed. A sink error or a config read error stops the chunk before
   any delete.
7. Offloaded payloads are dropped. The archive keeps a `$archiveDropped`
   marker and a count.

## Alternatives

| Option | Why not |
|---|---|
| Big Object only | The owner wants other stores. A sink API costs little. |
| Archive in a new custom object | It uses primary data storage. |
| Copy offloaded files into the archive | Heap risk. Files already use file storage. |
| Archive on the orchestrator hot path | The issue forbids it. |
| Only `ArchiveWorkflow`; leave `CleanupWorkflow` as is | A scheduled cleanup then purges unarchived history. |

## Consequences

- `WorkflowArchiveSink` and `WorkflowArchiveRecord` are public API. Change
  them only in an additive way.
- Tests cannot write Big Objects. The Big Object sink has a test seam, so the
  real `insertImmediate` and Big Object SOQL run only in an org.
- A callout sink works only in `ArchiveWorkflow`.
- CSV files belong to the sweep user. Readers need access to those files.
