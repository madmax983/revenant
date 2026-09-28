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
| Heap or SOQL rows overflow on big instances. | Batch has at most 20 instances, 500 step rows and a quarter of the heap. A larger instance stays in primary storage and the output names it. |
| Archive mutates the append-only trail. | Snapshot is SOQL only. A test checks 0 DML. |
| Offloaded file is lost without a record. | `$archiveDropped` marker plus `droppedPayloadCount`. |
| Tests write real Big Object rows. | Salesforce forbids that. The sink has a `@TestVisible` store seam. |
| `insertImmediate` or a callout runs after engine DML. | Both sweep steps are `CalloutStep`s. A test sink makes a callout through the engine. |
| Archival off changes cleanup. | Sink is null, so the purge path is the same. New: one config read, and a config read failure stops the step. |

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

## 5. Review results

Four review agents (correctness, platform limits, security, tests and docs)
found issues. We fixed them:

- `CleanupWorkflow`'s step is now a `CalloutStep`. Before, the default Big
  Object sink failed there, because `insertImmediate` follows callout rules.
- Heap bound for each batch, a step bound for each instance, and a cursor.
  Before, one large instance could stop the sweep.
- Step counts use `COUNT() ... LIMIT` for each instance, so they use few
  query rows.
- The CSV sink finds files by marked fields, not by title. It uses an
  optional `Revenant_Archive` library for reader access.
- Reads load one instance or one file at a time.
- Codex review: correlation key lookup is not case-sensitive, as in
  `Correlation_Key__c`. The key hash uses the lower-case key.
- Codex review (P1): the step bound did not bound payload size. Error
  details now load 10 rows at a time with a heap check. An instance whose
  copy alone passes a quarter of the heap is skipped. The CSV sink inserts
  one file at a time.
- Codex review: a capped skip list could stop a run behind more than 2000
  skipped instances. A cursor (`CreatedDate`, `Id`) now moves past each
  purged or skipped instance. The skip list is only a report.
- The dropped marker cannot make `Error_Details__c` too long.
- Error messages do not echo payload text.
- The Admin permission set has read access only on the Big Objects.
- A config seam lets tests read config values without the org record.
