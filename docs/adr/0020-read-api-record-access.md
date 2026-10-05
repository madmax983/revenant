# ADR 0020: Record access in decoding read APIs

- **Status:** Accepted
- **Date:** 2026-10-01
- **Issue:** #243

## Context

`getStatus`, `getCausationLineage`, `getStepError` and the status Flow action query in system mode. With a payload codec they return decoded payloads. Any user who can call them can read plaintext without record access.

## Options

| Option | Result |
| --- | --- |
| `UserRecordAccess` check before decode | Uses sharing and object permission. Gave different answers for one user in a scratch org. Replaced (see Update). |
| Re-query status data with `WITH USER_MODE` | Also hides status fields. Fails the whole call. |
| User-mode query of the Id only, as a check | Uses object permission, field permission and sharing. Same cost. **Chosen.** |
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

## Update (2026-10-05)

In a scratch org test, `UserRecordAccess` said a user could read an instance when the user could not query the object. The same call gave different answers in one test. The gate now runs a user-mode query that selects only the Id. A denied query returns nothing, so the user gets `DENIED_PAYLOAD`. Status data is still read in system mode. The cost is the same: one query for each 200 instances.
