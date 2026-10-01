# Payload Ingress Threat Model

Scope: every path that lets a caller put payload text into Revenant storage. Issue #246. Includes #242.

## Assets

- Stored data: instance input and output, step output and state, file offloads, ciphertext.
- Rule: no caller gets stored data (plaintext or ciphertext) that it does not own.

## Attacker

A user who can call `WorkflowEngine` APIs, publish `Workflow_Event__e`, or insert `Workflow_Signal__c`. The attacker can send any name and any text. The attacker cannot change engine code or a child record that the engine owns.

## Rules

1. Caller text is data. The engine encodes it, also when it looks like an envelope.
2. The engine does not decode a value because of its shape or its name.
3. The engine decodes and resolves only values that it read from a record that it trusts.
4. A signal can wake an instance. A signal cannot set an outcome.

## Ingress paths

| Path                               | Caller text                | Control                                                                                  | Residual risk                                                        |
| ---------------------------------- | -------------------------- | ---------------------------------------------------------------------------------------- | -------------------------------------------------------------------- |
| Start (`start`, bulk, scalar)      | Input                      | Encoded as `WORKFLOW_INPUT`.                                                             | None known.                                                          |
| Signal (`signal`, event, Flow)     | Name, payload              | Payload encoded as `SIGNAL_PAYLOAD`. Name is a routing key only.                         | A forged signal can wake a parent early. Outcome reads re-check.     |
| Child completion (`ChildCompleted`, `ChildFailed`) | Name, payload | Reader ignores the payload. Outcome comes from the child record of the reading instance. | Raw `getSignal(...).payload` is untrusted. Do not use it.            |
| Resume (`resume`, bulk resume)     | Payload                    | Encoded as `SIGNAL_PAYLOAD`.                                                             | None known.                                                          |
| Debounce                           | Input                      | Encoded as `WORKFLOW_INPUT`.                                                             | None known.                                                          |
| Invocable actions                  | Same fields as the APIs    | They call the same services.                                                             | None known.                                                          |
| Unrouted signals                   | Payload                    | Encoded. No owner record, so no offload.                                                 | Size limit for AES text. See `payload-codec.md`.                     |
| Identity codec (#242)              | Payload that starts with a marker | Not encoded, so a marker-like text can read as a stored form.                    | Do not start a payload with `{"$codec":` or `{"$attachmentId":`.     |

## Forged child signals

| Forgery                                | Result                                           |
| -------------------------------------- | ------------------------------------------------ |
| Envelope copied from another record    | Ignored. Output is read from the child record.   |
| Offload marker for another file        | Ignored. No file is resolved.                    |
| Plaintext payload                      | Ignored.                                         |
| `ChildCompleted` for a failed child    | Failed outcome. Status decides the type.         |
| `ChildFailed` for a completed child    | Completed outcome. Status decides the type.      |
| Signal for a running child             | No outcome.                                      |
| Signal for a child of another parent   | No outcome. Query keeps `Parent_Instance__c`.    |

## Known gaps

- File purge uses title prefixes to find engine files. A user file with such a title can match. Tracked in a new issue.
