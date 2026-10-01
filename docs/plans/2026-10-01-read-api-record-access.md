# Record Access in Decoding Read APIs (Issue #243)

## Goal

`getStatus`, `getCausationLineage` and the status Flow action decode payloads in system mode. A user without record access must not get plaintext.

## Facts

- The read APIs query in system mode. This stays, because the engine needs it.
- A decode happens only for an encoded value (a valid `$codec` envelope). The identity codec never decodes.
- `Workflow_Instance__c` sharing is `ReadWrite`. An admin can set it to private. A user also needs object read.
- `UserRecordAccess.HasReadAccess` covers sharing and object permission. One query holds at most 200 record Ids.
- The author had no org. Apex tests do not run here.

## Brainstorm

| #   | Idea                                                       | Keep?                                              |
| --- | ---------------------------------------------------------- | -------------------------------------------------- |
| B1  | `UserRecordAccess` check before decode.                    | Yes.                                               |
| B2  | Re-query the instance with `WITH USER_MODE`.               | No. It also hides status and field-level data.     |
| B3  | Custom permission that gates decode.                       | No. A second control. It ignores record sharing.   |
| B4  | Redacted placeholder, not an error.                        | Yes. Lineage and bulk calls continue.              |
| B5  | Redact status metadata too.                                | No. Only payloads are codec-protected.             |
| B6  | Check only when the value is encoded.                      | Yes. No new SOQL with the identity codec.          |
| B7  | One shared gate class for all three APIs.                  | Yes.                                               |
| B8  | Check after file rehydration, on the file text.            | Yes. An offloaded value is a marker, not envelope. |

## Reverse Brainstorm

| Way to fail                                         | Prevention                                              |
| --------------------------------------------------- | ------------------------------------------------------- |
| Offloaded envelope is decoded before the check.     | Check the resolved text. Test with an offloaded output. |
| Flow `progressJson` is missed.                      | Same gate for output and progress. Test both.           |
| Lineage ancestor leaks.                             | Gate every ancestor Id. Test lineage.                   |
| A user with access gets redacted.                   | Test with `Revenant_Operator`.                          |
| More than 200 Ids break the query.                  | Chunk by 200.                                           |
| The check adds SOQL when no codec is set.           | Lazy gate. Test: no extra query with identity codec.    |
| Placeholder breaks a JSON parser.                   | Valid JSON, like the operator placeholder.              |
| A cached result leaks to the next user.             | No static cache. The gate lives for one call.           |
| `getStepError` decodes `failureData` without a check. | `resolveForUser` checks the parent instance. Test.     |

## Six Hats

- **White:** Facts above. No `global` change. The manifest stays.
- **Red:** An admin needs a hard control, not advice.
- **Black:** Extra SOQL cost. A user who cannot read status payloads gets a placeholder.
- **Yellow:** One check point. Works with sharing changes. No new setup.
- **Green:** Option B1 + B4 + B6 + B7.
- **Blue:** RED tests, then GREEN, then docs, then review.

## Design

`WorkflowPayloadAccess.Gate(Set<Id>)` loads read access one time, on first use. `gate.decode(text, instanceId)` returns:

- `text` when it is not encoded.
- The decoded value when the user can read the instance.
- `WorkflowPayloadAccess.DENIED_PAYLOAD` when the user cannot.

`WorkflowStatusProjection.buildStatus` and `WorkflowStatusPayloadRehydrator.rehydrate` take the gate.

## Steps

1. RED: `WorkflowPayloadAccessTest`.
2. GREEN: gate class and wiring.
3. REFACTOR: remove duplicate decode paths.
4. Docs: `payload-codec.md`, ADR 0020.
5. Review from several angles. Fix findings.
