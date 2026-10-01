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
| `STEP_OUTPUT` | `Workflow_Step_Execution__c.Output__c`, `Workflow_Instance__c.Output__c`, the `failureData` part of `Error_Details__c` |
| `STEP_STATE` | step state in `Workflow_Step_Execution__c.Output__c`, `Captured_Values__c`, `Workflow_Instance__c.Progress__c` |
| `SIGNAL_PAYLOAD` | `Workflow_Signal__c.Payload__c`, resume payloads |

- A large payload goes to a `ContentVersion` file. The file holds the encoded
  text.
- A copied value keeps the kind of its first encode. For example, a step input
  is a copy of the previous output. A child-completion signal keeps the child
  output (`STEP_OUTPUT`).

## What stays plaintext

The engine does **not** encode control data:

- Offload markers (`{"$attachmentId":...}`).
- Engine wait markers (child wait, approval wait, `$timeoutStep`,
  `$timeoutResume`).
- `Status__c`, `Compensation_Stack__c`, `Terminal_At__c`, correlation keys,
  approval keys and roles, child keys.
- `idempotencyKey` and signal dedup keys (`Signal_Key__c`, `Idempotency_Key__c`).
- The definition-change marker row (`Workflow_Definition_Changed`) and the
  `Definition_Fingerprint__c` and `Definition_Shape__c` fields (issue #89). They
  hold step names and fingerprints only.

The engine makes idempotency and dedup keys from instance Ids, step names and
caller keys. It does not use payload text. Dedup, saga rollback and signal
delivery work the same with a codec.

The codec also does not cover these fields. Do not put sensitive data in them:

- Error text: `Error_Message__c`, the reason part of `Error_Details__c`,
  exception messages, and the `Workflow_Lifecycle__e` and `Workflow_Alert__e`
  events.
- `StepContext` logger breadcrumbs (`Workflow_Log__c.Message__c`).
- Search attributes (`Workflow_Search_Attribute__c`,
  `Debounce_State__c.Attributes_Json__c`).
- Schedule input (`Workflow_Schedule__c.Input_Json__c`).
- Platform events: `Workflow_Event__e` payloads that you publish, and events
  from `ctx.events()`.
- Approver notifications (issue #123): the title, body and recipient Ids in
  the `Notification` log rows (`Workflow_Log__c.Message__c`).
- Strict determinism mode: `Workflow_Step_Execution__c.Decision_Record__c`
  and the `StepNonDeterminism` log rows. They hold step names, approval keys
  and roles, and child keys. The inputs digest uses the stored (encoded)
  forms, not plaintext.

## Write a codec

Implement `PayloadCodec`. Use a public class with a public no-argument
constructor.

```apex
public with sharing class AesPayloadCodec implements PayloadCodec {
  private Blob key;

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
    // You own the key. Load it one time, for example from a protected
    // custom setting, and keep it in this field.
    if (key == null) {
      key = MyKeyStore.currentKey();
    }
    return key;
  }
}
```

Rules:

1. `decode(encode(p, ctx), ctx)` must return `p`.
2. Do not do DML.
3. Do not make callouts. The engine calls `encode` after DML in the same
   transaction.
4. Load key material one time. The engine calls `decode` once for each row it
   reads.
5. Throw an exception when you cannot decode. Do not return ciphertext.
6. `ctx.kind` tells you the payload class. `decode` gets the same kind as
   `encode`.

## Turn it on

1. Deploy your codec class.
2. Open **Custom Metadata Types > Revenant Config > Default**.
3. Set **Payload Codec** (`Payload_Codec__c`) to the class name, for example
   `AesPayloadCodec`. Use `ns.AesPayloadCodec` if the class has a namespace.

Blank selects the identity codec. The identity codec stores payloads unchanged,
byte for byte. Existing orgs do not need a migration.

## Read stored fields in your own code

If your code reads `Input__c`, `Output__c`, `Progress__c`,
`Captured_Values__c` or `Payload__c` with SOQL, give the value to
`WorkflowPayloadOffload.resolvePayload(text, ownerId)` (one value) or
`resolvePayloads(texts, ownerId)` (a list). The owner is the instance that
holds the value. These methods load offloaded files and decode the value. Tests
that check stored text must also resolve it first.

A marker resolves only when its file is linked to the owner. A file of another
instance, or an unlinked file, stays as marker text. For child outputs, use
`resolveChildPayloads(texts, parentId)`: it also accepts files linked to a child
of the parent.

`StepContext`, `ctx.signals()`, `getStatus`, the status Flow action and
`WorkflowTestHarness` already give decoded payloads.
`WorkflowHistoryRead.getStepError` gives the `failureData` part decoded.

With a codec, the engine changes `\nfailureData: ` in a failure reason to
`\n failureData: `. Then only the engine can write a stored form after the
separator, and `getStepError` does not decode copied ciphertext.

Read child results with `ctx.signals().getChildOutcome(key)`. A direct
`getSignal('ChildCompleted:<key>')` read gives the marker text for an offloaded
child output, because the child owns the file. With a codec, a
raw `getSignal('ChildCompleted:<key>').payload` gives the child's stored
(encoded) output. `getChildOutcome` decodes it only after it checks that the
value is the output of a child of this instance.

## Stored form

The engine wraps codec output in an envelope:

```json
{"$codec":"STEP_OUTPUT","data":"<codec output>"}
```

- Only a value with this exact shape and a known kind is an envelope.
- A value without the envelope is plaintext. The engine reads it unchanged, so
  rows written before you set the codec stay readable.
- The engine encodes all external input, also input that looks like an
  envelope. If a user copies ciphertext into a signal or a start input, the
  step gets the copied text, not the plaintext.
- A signal name gives no trust. A forged `ChildCompleted:<key>` signal with
  copied ciphertext or a copied file marker is not decoded, because the value
  is not the output of a child of the reading instance.
- With a codec, the engine encodes input that starts with `{"$codec":` or
  `{"$attachmentId":` like any other input, so input cannot point the engine
  at a stored value or a file.
- The public start, signal, signal-or-start, resume, invocable and dashboard
  entry points reject input that starts with `{"$attachmentId":`. The
  `Workflow_Event__e` handler drops a marker payload, except on the engine
  `SIGNAL:ChildCompleted:` and `SIGNAL:ChildFailed:` events. The link check on
  read also protects that path.
- With the identity codec, do not start a payload with `{"$codec":`. The engine
  reads it as a stored form.

## Behavior to know

- **Fail closed.** If the class name is not valid, or the config cannot be
  read, every payload write throws `WorkflowPayloadCodecs.PayloadCodecException`.
  A read of an encoded value also throws. A read of a plaintext value continues.
  If you remove the codec, encoded rows cannot be read. The engine never gives
  ciphertext to a step as plaintext.
- **Error messages.** The engine replaces codec exception messages with the
  exception type and the payload kind. Payload text does not go into error
  fields.
- **Size.** Encryption makes a payload larger. The engine compares the length
  of the encoded text with the offload limit (100 000 characters). Signal
  payloads with a target instance also offload. Bulk start, bulk child start
  and bulk resume use one file insert, one query and one link insert for all
  rows. DML does not grow with the row count. Unrouted signals and debounce
  input have no owner record, so they stay inline. With an AES + base64 codec,
  keep them below about 95 000 bytes of UTF-8 text.
- **Heap.** A large payload needs more heap while the codec runs. Keep very
  large outputs out of synchronous transactions.
- **Dashboard.** The operator dashboard does not decode. It shows a redacted
  placeholder for encoded payloads. The operator-skip audit log also shows a
  redaction note.
- **Read APIs.** `getStatus`, `getCausationLineage`, `getStepError`, the status
  Flow action and `StepContext` return decoded payloads. The read APIs query in
  system mode. Before they decode an encoded payload, they check read access to
  the instance. The check uses `UserRecordAccess`: sharing and object
  permission. A user without access gets `WorkflowPayloadAccess.DENIED_PAYLOAD`
  in `output`, `progressJson` and the `failureData` part. Status, error text and
  keys stay visible. The check costs one query for each 200 instances. It runs
  only for an encoded payload, so the identity codec has no extra query. A
  plaintext row, written before you set the codec, is not checked. See
  [ADR 0020](adr/0020-read-api-record-access.md).
- **Append-only.** The engine encodes a payload once, at its checkpoint.
  `decode` does not change a record.
- **Confidentiality only.** The codec does not detect changes. A user who can
  edit a payload field can replace the envelope with plaintext.

## Out of scope

- Key management and key rotation.
- Re-encryption of rows that exist before you set the codec.
- Decryption in the dashboard.
- Field-level masking inside a payload. The codec gets the full payload.

See [ADR 0002](adr/0002-payload-codec-envelope.md) for the design decision.
