# ADR 0021: Global payload codec and archive API

- **Status:** Accepted
- **Date:** 2026-10-01
- **Issue:** #255

## Context

[ADR 0006](0006-frozen-global-api.md) made the step, control and Flow API
`global`. `PayloadCodec`, `WorkflowArchiveSink` and the archive read API were
left `public`. A subscriber in a managed package could not implement a codec
or a sink, and could not read archived history.

## Decision

1. Make these `global`: `PayloadCodec`, `CodecContext` (with `PayloadKind`),
   `WorkflowArchiveSink`, `WorkflowArchiveRecord` (with `Step`) and
   `WorkflowArchive`.
2. `WorkflowArchive` exposes only `getArchivedHistory`, `findArchivedHistory`,
   `hashCorrelationKey`, `MAX_READ_RECORDS` and `ArchiveException`. A sink
   calls `hashCorrelationKey` and reads `MAX_READ_RECORDS`. A reader calls the
   two reads and catches `ArchiveException`. The hash algorithm is part of the
   contract. The config methods and `sink()` stay `public`. The class has a
   private constructor.
3. `CodecContext.kind` is a read-only property. The constructor is `global`,
   so a subscriber can unit-test a codec. The context has no rule to protect.
4. `WorkflowArchiveRecord` and `Step` keep writable fields. A sink must build
   records when it reads. `DROPPED_MARKER` is `global`: a reader needs it to
   find a dropped payload.
5. The shipped sinks and `IdentityPayloadCodec` stay `public`. The engine call
   sites stay `public`. A `public` class can implement a `global` interface.
   A subscriber class stays `public`, as for steps.
6. Extend `GlobalApiSubscriberTest` with a codec, a sink and the archive
   reads. The packaged-view compile in `npm run test:global-api` is the test
   for this change.
7. `WorkflowHistoryRead` stays `public`. No subscriber needs it yet.

## Consequences

- Each new member is permanent after the first release. The manifest in
  `docs/global-api.md` lists them. The test enforces it.
- A new method on `PayloadCodec` or `WorkflowArchiveSink` needs a new opt-in
  interface.
- `PayloadKind` has a fixed list of values. A new value can break a
  subscriber `switch`.
- `WorkflowArchiveRecord` fields stay writable. They cannot become read-only
  later.
- The 2GP install check runs in a scratch org. See
  `docs/packaging-smoke.md`. No CI job runs it yet. The check also shows
  whether the engine can load a subscriber class by name.

## Rejected Options

- Make `WorkflowArchive.sink()` and `isEnabled()` `global`: they expose sweep
  internals.
- Read-only `WorkflowArchiveRecord` fields: a subscriber sink cannot then
  return records.
- Make the shipped sinks `global`: a subscriber has no need to extend them.
