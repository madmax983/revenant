# Validate alert email addresses (#265)

## Problem

`parseRecipients` keeps any non-blank token. `not-an-email` makes `isAlertActionable` true. Readiness shows Pass. The send fails and the alert path hides the error.

## Decision

A mixed list sends to the valid addresses and skips the invalid ones.

Reason: one typo must not stop an alert for the other people. Readiness names the skipped tokens, so the owner can fix them.

## Thinking

**Brainstorm.** (1) One regex in `WorkflowAlertEmailBuilder`. (2) Use `Messaging.SingleEmailMessage` to validate. (3) Validate when the record is saved.

- Option 2 only fails at send time, and it hides the error. Rejected.
- Option 3 cannot cover existing records. Rejected.
- Option 1 is pure, fast, and testable. **Chosen.**

**Reverse brainstorm.** How to make this worse?

- A strict regex rejects a real address, and a real alert is lost.
- Two predicates give different answers on different paths.
- Readiness says Pass for a list with no valid address.

Counter: use a conservative regex. Put the rule in one method. `parseRecipients` returns only valid addresses, so every path uses it.

**Six hats.**

| Hat | Note |
| --- | --- |
| White | Callers: `dispatchEmail`, `buildStallEmail`, `buildWatchdogStallEmail`, `ScheduleHealthAlert`, `isAlertActionable`, Readiness. All use `parseRecipients` or `hasRecipients`. |
| Red | An admin trusts the Pass row. A wrong Pass is the worst result. |
| Black | Regex can reject unusual but valid addresses (quoted local part). Accept this. Document it. |
| Yellow | One change in `parseRecipients` fixes all paths. No global API change. |
| Green | `invalidRecipients` gives the tokens for the Readiness finding. |
| Blue | Order: tests (red), code (green), docs and cleanup (refactor). |

## Design

- `isValidAddress(String)`: conservative regex. One `@`, a dotted domain, no spaces.
- `parseRecipients`: returns valid addresses only.
- `invalidRecipients`: returns the non-blank tokens that fail the check.
- `hasRecipients`: true when one valid address exists.
- Readiness: when alerts are on, the event is off, and no address is valid, Warn. The finding names each invalid token.
- Readiness: when a channel works but some tokens are invalid, Pass. The finding lists the skipped tokens.
- Limit: an address is at most 254 characters. This keeps the regex fast.

## Out of scope

Deliverability. Org email settings.

## Tests

- Malformed-only list: not actionable, Warn, tokens named.
- Mixed list: valid addresses only in `toAddresses`.
- Valid list: no change.
