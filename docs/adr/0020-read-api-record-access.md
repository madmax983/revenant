# ADR 0020: Record access in decoding read APIs

- **Status:** Accepted
- **Date:** 2026-10-01
- **Issue:** #243

## Context

`getStatus`, `getCausationLineage`, `getStepError` and the status Flow action query in system mode. With a payload codec they return decoded payloads. Any user who can call them can read plaintext without record access.

## Options

| Option | Result |
| --- | --- |
| `UserRecordAccess` check before decode | Uses sharing and object permission. **Chosen.** |
| Re-query with `WITH USER_MODE` | Also hides status fields. Fails the whole call. |
| Custom permission gate | Ignores record sharing. A second control to maintain. |
| Throw on denial | Stops bulk and lineage calls. |

## Decision

1. `WorkflowPayloadAccess.Gate` checks read access one time for each call, on the first encoded value.
2. Without access, the API returns `DENIED_PAYLOAD` (valid JSON) for output, progress and `failureData`.
3. The check runs on the text after file rehydration, so offloaded values are covered.
4. Plaintext values and the identity codec skip the check. No new query. The check protects decode only. This is the scope of the issue.
5. No `global` change.

## Consequences

- The check costs one extra query for each 200 instances. It runs only with a codec.
- An admin can limit access with sharing and object permission.
- Status, error text and keys stay visible. They are not codec-protected.
