# Payload Ingress Threat Model

Scope: each path that lets a caller store payload text. Issues: #246, #242.

## Attacker

A user who can call `WorkflowEngine` APIs or publish `Workflow_Event__e`. The attacker can send any signal name and any text. The attacker cannot change engine code. Admin-level create on `Workflow_Instance__c` or `Workflow_Signal__c` is trusted and out of scope.

## Rules

1. Caller text is data. With a codec, the engine encodes it, also when it looks like an envelope.
2. A child signal only wakes a parent. The engine never reads its payload.
3. The engine decodes an outcome only from the child record of the reading instance.

## Ingress paths

| Path                                  | Caller text    | Control                                                           | Residual risk                                            |
| ------------------------------------- | -------------- | ----------------------------------------------------------------- | -------------------------------------------------------- |
| Start (single, bulk, child, schedule) | Input          | Encoded as `WORKFLOW_INPUT`.                                      | Identity codec: see #242.                                |
| Signal, `signalOrStart`, Flow action  | Name, payload  | Encoded as `SIGNAL_PAYLOAD`. Child names give no payload on read. | Identity codec: see #242.                                |
| Child completion                      | Name, payload  | Event has no payload. Outcome comes from the child record.        | A forged signal can wake a parent early. No data leaves. |
| Resume, bulk resume, continue-as-new  | Payload, input | Encoded.                                                          | Identity codec: see #242.                                |
| Debounce                              | Input          | Encoded as `WORKFLOW_INPUT`.                                      | Identity codec: see #242.                                |
| Unrouted signals                      | Payload        | Encoded. No owner record, so no offload.                          | AES text size. See `payload-codec.md`.                   |

## Forged child signals

| Forgery                              | Result                                            |
| ------------------------------------ | ------------------------------------------------- |
| Envelope copied from another record  | Not read. Output comes from the child record.     |
| Offload marker for another file      | Not resolved. The signal read gives no payload.   |
| Plaintext payload                    | Not read.                                         |
| `ChildCompleted` for a failed child  | Failed outcome. Status decides the type.          |
| `ChildFailed` for a completed child  | Completed outcome. Status decides the type.       |
| Signal for a running child           | No outcome.                                       |
| Signal for a child of another parent | No outcome.                                       |
| Old finished child with the same key | The newest child decides. A running one hides it. |

## Known gaps

- Identity codec: payload text that starts with `{"$codec":` or `{"$attachmentId":` reads as a stored form (#242). This includes a child output.
- File purge uses title prefixes to find engine files. A new issue tracks it.
- The envelope names a payload kind, not a record. A user with Admin create on `Workflow_Instance__c` can copy ciphertext between records.
