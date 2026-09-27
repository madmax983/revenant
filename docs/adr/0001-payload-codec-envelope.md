# ADR 0001: Payload codec at the offload seam, with an engine envelope

- Status: Accepted
- Date: 2026-09-27
- Issue: #99

## Context

Revenant stores author payloads as plaintext JSON. Regulated data is then
readable by any user with object access. Shield Platform Encryption is a paid
add-on. An ISV cannot assume that a subscriber org has it.

## Decision

1. Add a public `PayloadCodec` interface: `encode(plaintext, ctx)` and
   `decode(stored, ctx)`. `CodecContext` carries the payload kind.
2. Select the codec with `Revenant_Config__mdt.Payload_Codec__c`. Blank is the
   identity codec.
3. Callers encode author data before they call
   `WorkflowPayloadOffload.savePayloadIfNeeded`. The offload check then uses
   the encoded length. Decode in `resolvePayload` / `resolvePayloads` and the
   status rehydrators. Most engine paths already use these seams.
4. Wrap codec output in an engine envelope:
   `{"$codec":"<KIND>","data":"..."}`. The identity codec adds no envelope.
5. Always encode external input, also input that looks like an envelope. Only
   engine copy paths (child-completion signals) keep a stored form.
6. Do not encode control data: offload markers, engine wait markers, status,
   compensation stack, keys and timestamps.
7. Fail closed. Misconfiguration, a config read failure or a missing codec
   throws. The engine never gives ciphertext to a step as plaintext.
8. The dashboard does not decode. It shows a redacted placeholder.

## Why an envelope

- The engine can tell encoded values from legacy plaintext rows.
- Engine copies of stored values (for example, a child output that becomes a
  signal payload) do not get a second encode.
- `decode` gets the same kind as `encode`, from the envelope.
- The envelope is valid JSON, so JSON readers do not fail on it.

## Alternatives

| Option | Why not |
|---|---|
| Encode in a `before insert/update` trigger | Trigger changes do not reach the caller's in-memory records. The trigger also cannot offload before the field limit. |
| Codec output without an envelope | The engine cannot find legacy plaintext or skip a second encode. |
| Encode engine wait markers too | The dashboard and the watchdog read them raw. The issue puts control data out of scope. |
| Decode on the dashboard | The issue puts operator decryption out of scope. |

## Consequences

- `PayloadCodec` and `CodecContext` are public API. Change them only in an
  additive way.
- Encoded payloads are larger. Unrouted signals and debounce input have no
  owner record for an offload file, so they stay inline.
- If an admin removes the codec, encoded rows cannot be read until the codec
  is set again.
- A forged `$attachmentId` marker can point at a file of another instance.
  This risk existed before the codec. A follow-up issue adds an owner check.
