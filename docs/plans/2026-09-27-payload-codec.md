# Pluggable Payload Codec Implementation Plan (Issue #99)

**Goal:** Keep author payloads as ciphertext at rest. The engine calls an
author-supplied `PayloadCodec` on every payload write and read.

**Architecture:** Encode at the offload seam (`savePayloadIfNeeded`). Decode
at the resolve seam (`resolvePayload`, `resolvePayloads`, status rehydrators).
Wrap codec output in an engine envelope. Select the codec with
`Revenant_Config__mdt.Payload_Codec__c`. Identity is the default.

**Tech stack:** Apex, custom metadata, `Crypto` (tests only).

---

## 1. Brainstorming

- **Seam.** Two audits found about 250 payload field sites in 65 classes. Most
  writes already call `savePayloadIfNeeded`. Most reads already call
  `resolvePayload`. Put the codec there and fix the few direct sites.
- **Kind.** Give the codec a `CodecContext` with the payload kind. Keep it
  small. A class (not a parameter list) lets us add fields later.
- **Envelope.** `{"$codec":"<KIND>","data":"..."}`. It finds legacy
  plaintext, stops a second encode, and carries the kind to `decode`.
- **Offload.** Encode first. Then offload when the *encoded* text is longer
  than 100 000 characters. The file holds ciphertext. The marker stays plain.
- **Signals.** Four direct inserts. Route them through `encodeForField`. It
  keeps identity bytes and offloads large ciphertext when an owner is known.
- **Config.** One text field. Read it in the `WorkflowEngine` static block,
  like the other `Revenant_Config__mdt` fields.
- **Dashboard.** Show a redacted JSON placeholder. Do not decode.

## 2. Reverse brainstorming (how can it fail?)

| Failure | Mitigation |
|---|---|
| A stored value is encoded twice (child output copied into a signal, SPLIT fallback, debounce into start). | `encode` skips values with the envelope or an offload marker. The debounce sweeper decodes before start. The ChildFailed wrapper decodes the child output before it wraps it. |
| Ciphertext reaches a step as plaintext. | `decode` throws when no codec is set or the envelope is bad. It runs outside the offload `try/catch`. |
| A raw reader breaks (`contains('$timeoutStep')`, harness wait check, dashboard LWC `JSON.parse`). | Engine wait markers stay plaintext. Only author data is encoded. |
| `getNextStep` after a parallel join sees the envelope. | `WorkflowParallelJoin` and `WorkflowOperatorSkipParallel` decode the spawning output. |
| The field overflows because ciphertext is larger. | Offload uses the encoded length. Signals with an owner offload too. |
| Identity orgs see a change. | Identity adds no envelope and no offload. A test checks the stored bytes. |
| Dedup or idempotency changes. | Keys use plaintext inputs (instance Id, caller key). A test checks `Signal_Key__c`. |
| An operator writes a fake envelope. | Operator skip rejects `"$codec"`, like `"$attachmentId"`. |
| The audit log leaks the operator payload. | With a codec, the log shows a redaction note. |
| Bad class name writes plaintext by mistake. | Fail closed: the engine throws. It does not fall back to identity. |

## 3. Six thinking hats

- **White (facts):** 3 objects and `ContentVersion` hold payloads. Long text
  fields are 131 072 characters. Offload starts at 100 000. Long text fields
  cannot be in a SOQL `WHERE`, so no query filters on payloads.
- **Red (feelings):** Admins want one switch. Authors do not want to change
  step code. Both hold: one metadata field, no step change.
- **Black (risks):** Forever API. Hot path. A missed read site corrupts data.
  Mitigation: two audits, fail-closed decode, E2E plaintext scan, round-trip
  test over the shipped examples.
- **Yellow (benefits):** Removes an AppExchange security-review blocker. Works
  without Shield. No new SOQL on the hot path.
- **Green (ideas):** Later: a codec server for authorized decrypt, key ids in
  the envelope for rotation.
- **Blue (process):** SPEC, RED, GREEN, REFACTOR. Type-check with apex-ls. Then
  a multi-angle agent review.

## 4. TDD steps

1. **SPEC.** `PayloadCodec` contract: round-trip, pure, fail closed.
2. **RED.** `WorkflowPayloadCodecsTest` for the facade and offload seam.
   apex-ls reports the missing types.
3. **GREEN.** `PayloadCodec`, `CodecContext`, `IdentityPayloadCodec`,
   `WorkflowPayloadCodecs`, the offload hooks and the config field.
4. **RED.** `WorkflowPayloadCodecE2ETest` (plaintext scan, identity bytes,
   round-trip, append-only, dashboard, dedup, debounce, config) and
   `PayloadCodecRoundTripTest` (shipped examples).
5. **GREEN.** Wire every write and read site from the audits.
6. **REFACTOR.** Agent review from several angles. Fix the findings.

## 5. Files

- New: `PayloadCodec`, `CodecContext`, `IdentityPayloadCodec`,
  `WorkflowPayloadCodecs`, `Revenant_Config__mdt.Payload_Codec__c`.
- Seams: `WorkflowPayloadOffload`, `WorkflowStatusProjection`,
  `WorkflowStatusPayloadRehydrator`, `WorkflowPayloadService`.
- Write sites: every `savePayloadIfNeeded` caller with author data, the four
  signal inserts, `WorkflowDebouncer`, `WorkflowStepContext`.
- Read sites: `WorkflowParallelJoin`, `WorkflowOperatorSkipParallel`,
  `WorkflowDebounceSweeper`, `WorkflowParentNotifier`,
  `WorkflowWaitDescriptorService`.
- Docs: `docs/payload-codec.md`, ADR 0001, README.
