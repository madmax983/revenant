# Archive Before Purge Implementation Plan (Issue #105)

**Goal:** Copy terminal workflow history to cold storage before the sweep
deletes it from primary storage.

**Architecture:** A public `WorkflowArchiveSink` API with two shipped sinks:
`BigObjectArchiveSink` (default) and `CsvArchiveSink`. A shared sweep
(`WorkflowArchiveSweep`) writes a chunk to the sink, then deletes it.
`ArchiveWorkflow` runs the sweep. `CleanupWorkflow` also archives when
archival is on. `WorkflowArchive` reads archived history back.

**Tech stack:** Apex, Big Objects, `ContentVersion`, custom metadata.

---

## 1. Brainstorming

- **Sink API, not one store.** The issue asks for a Big Object. The owner asks
  for an API. A sink can write to a Big Object, to CSV files or to S3. Select
  it in `Revenant_Config__mdt.Archive_Sink__c`, like the payload codec.
- **One record shape.** `WorkflowArchiveRecord` holds the instance outcome and
  an ordered step list. Each step copies `WorkflowEngine.StepHistoryEntry`, so
  the archive shows the same facts as `getHistory`.
- **Archive before purge.** The sweep reads the chunk (SOQL only), calls
  `sink.write`, then deletes. If `write` throws, the sweep deletes nothing.
- **Callout sinks.** `ArchiveWorkflow`'s step is a `CalloutStep`. The engine
  does no DML before `execute`, and the sweep does no DML before `write`. So an
  S3 sink can call out.
- **Idempotency.** Big Object inserts overwrite on the same index. The CSV
  sink skips instances that already have a file.
- **Correlation key lookup.** A Big Object index can hold 100 text characters.
  A key can have 255. A second Big Object indexes the SHA-256 hash of the key.
- **Payload policy.** Inline payloads are copied in stored form (codec
  ciphertext stays ciphertext). Offloaded payloads are dropped. The archive
  keeps a `$archiveDropped` marker and a count.

## 2. Reverse brainstorming (how can it fail?)

| Failure | Mitigation |
|---|---|
| Purge deletes a row that the archive did not get. | `write` runs first. A throw stops the chunk. Big Object `insertImmediate` commits at once, so a later delete failure is safe. |
| A retry writes duplicate archive rows. | Big Object index overwrites. CSV sink checks titles first. |
| `CleanupWorkflow` purges without an archive when archival is on. | `CleanupWorkflow` uses the same sweep and archives first. |
| Config read fails and the sweep purges unarchived rows. | Fail closed: the sweep throws. |
| Heap or SOQL rows overflow on big instances. | Chunk has at most 20 instances and 1000 step rows. The first instance always goes, so the sweep moves forward. |
| Archive mutates the append-only trail. | Snapshot is SOQL only. A test checks 0 DML. |
| Offloaded file is lost without a record. | `$archiveDropped` marker plus `droppedPayloadCount`. |
| Tests write real Big Object rows. | Salesforce forbids that. The sink has a `@TestVisible` store seam. |
| A callout sink runs in `CleanupWorkflow`. | Platform throws before any DML. Nothing is deleted. Docs say: use `ArchiveWorkflow`. |
| Archival off changes today's cleanup. | Sink is null. The sweep path is the same code as before. Old tests stay green. |

## 3. Six thinking hats

- **White (facts):** Big Objects do not count against data storage. Index text
  is at most 100 characters. Tests cannot write Big Objects. Files count
  against file storage, not data storage.
- **Red (feelings):** Operators fear data loss more than cost. So: opt-in,
  archive first, fail closed.
- **Black (risks):** No scratch org in this session, so tests cannot run here.
  Mitigation: apex-ls type check, small seams, reviews.
- **Yellow (benefits):** Multi-year retention. Pluggable cold storage. No
  change to the orchestrator hot path.
- **Green (ideas):** Later: dashboard browse, re-hydrate, S3 sample sink.
- **Blue (process):** SPEC (interface contract), RED (tests), GREEN (code),
  REFACTOR, then a multi-angle agent review.

## 4. Tasks

1. Tests: facade, snapshot, CSV codec, both sinks, sweep, both workflows.
2. Metadata: two Big Objects, three config fields, permission sets.
3. Code: API, DTO, snapshot, sweep, sinks, `ArchiveWorkflow`.
4. Refactor `CleanupWorkflow` and `CleanupDocumentPurger` onto the sweep.
5. Docs: `docs/archive.md`, ADR 0003, README.
