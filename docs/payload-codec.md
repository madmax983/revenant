# Payload Codec (Encryption at Rest)

Revenant stores author payloads in custom objects and in `ContentVersion` files.
A payload codec encodes each payload before the engine writes it. The codec
decodes each payload after the engine reads it. Use a codec to keep sensitive
data (SSN, card numbers, PHI) as ciphertext at rest.

The codec does not need Shield Platform Encryption.

## What the engine encodes

| Payload class (`CodecContext.PayloadKind`) | Stored in |
|---|---|
| `WORKFLOW_INPUT` | `Workflow_Instance__c.Input__c`, `Debounce_State__c.Input_Json__c` |
| `STEP_OUTPUT` | `Workflow_Step_Execution__c.Output__c` and `Input__c`, `Workflow_Instance__c.Output__c` |
| `STEP_STATE` | step state in `Workflow_Step_Execution__c.Output__c`, `Captured_Values__c`, `Workflow_Instance__c.Progress__c` |
| `SIGNAL_PAYLOAD` | `Workflow_Signal__c.Payload__c` (inbound and outbound), resume payloads |

Large payloads go to a `ContentVersion` file. The file holds the encoded text.

The engine does **not** encode control data:

- Offload markers (`{"$attachmentId":...}`).
- Engine wait markers (child wait, approval wait, `$timeoutStep`, `$timeoutResume`).
- `Status__c`, `Compensation_Stack__c`, `Terminal_At__c`, correlation keys.
- `idempotencyKey`, signal dedup keys (`Signal_Key__c`, `Idempotency_Key__c`).

The engine calculates idempotency and dedup keys from plaintext. Dedup, saga
rollback and signal delivery work the same with a codec.

## Write a codec

Implement `PayloadCodec`. Use a top-level class with a public no-argument
constructor.

```apex
public with sharing class AesPayloadCodec implements PayloadCodec {
  public String encode(String plaintext, CodecContext ctx) {
    return EncodingUtil.base64Encode(
      Crypto.encryptWithManagedIV('AES256', key(), Blob.valueOf(plaintext))
    );
  }

  public String decode(String stored, CodecContext ctx) {
    return Crypto.decryptWithManagedIV(
        'AES256',
        key(),
        EncodingUtil.base64Decode(stored)
      )
      .toString();
  }

  private Blob key() {
    // You own the key. For example, read it from a protected custom setting.
    return MyKeyStore.currentKey();
  }
}
```

Rules:

1. `decode(encode(p, ctx), ctx)` must return `p`.
2. Do not do DML in `encode` or `decode`.
3. Throw an exception when you cannot decode. Do not return ciphertext.
4. `ctx.kind` tells you the payload class. `decode` gets the same kind as `encode`.

## Turn it on

1. Deploy your codec class.
2. Open **Custom Metadata Types > Revenant Config > Default**.
3. Set **Payload Codec** (`Payload_Codec__c`) to the class name, for example
   `AesPayloadCodec`. Use `ns.AesPayloadCodec` if the class has a namespace.

Blank selects the identity codec. The identity codec stores payloads unchanged,
byte for byte. Existing orgs do not need a migration.

## Stored form

The engine wraps codec output in an envelope:

```json
{"$codec":"STEP_OUTPUT","data":"<codec output>"}
```

- A value without the envelope is plaintext. The engine reads it unchanged, so
  rows written before you set the codec stay readable.
- The engine does not encode a value that already has the envelope.
- Keys that start with `$` are reserved. Do not start a payload with
  `{"$codec":`.

## Behavior to know

- **Fail closed.** If the class name is not valid, payload reads and writes
  throw `WorkflowPayloadCodecs.PayloadCodecException`. If you remove the codec,
  encoded rows cannot be read. The engine never gives ciphertext to a step as
  plaintext.
- **Size.** Encryption makes a payload larger. The engine calculates the offload
  limit (100 000 characters) from the encoded text. Signal payloads with a
  target instance also offload. Unrouted signals and debounce input have no
  owner record, so they stay inline. Keep them below about 95 000 characters
  with an AES + base64 codec.
- **Dashboard.** The operator dashboard does not decode. It shows a redacted
  placeholder for encoded payloads. The operator-skip audit log also shows a
  redaction note.
- **Read APIs.** `getStatus`, the status Flow action, `WorkflowTestHarness` and
  `StepContext` return decoded payloads.
- **Append-only.** The engine encodes a payload once, at its checkpoint.
  `decode` does not change a record.

## Out of scope

- Key management and key rotation.
- Re-encryption of rows that exist before you set the codec.
- Decryption in the dashboard.
- Field-level masking inside a payload. The codec gets the full payload.

See [ADR 0001](adr/0001-payload-codec-envelope.md) for the design decision.
