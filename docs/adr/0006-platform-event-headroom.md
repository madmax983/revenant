# ADR 0006: Platform Event headroom in System Doctor

- **Status:** Accepted
- **Date:** 2026-09-28
- **Issue:** #120

## Context

The engine signal plane uses Platform Events. The org allocation is shared.
When it is full, events can drop with no error. System Doctor shows async
Apex use, but not Platform Event use. The issue forbids a new object, field,
scheduled job or hot-path change. It asks for configurable thresholds.

## Decision

1. Add `PlatformEventHeadroom`. It reads four PE keys from the
   `System.OrgLimits` map. It calculates used, remaining, percent and a state
   for each key. It skips a key with no positive limit.
2. Classify on the exact ratio (`used × 100 ≥ threshold × limit`). Round the
   displayed percent down.
3. Add the result to the `getWatchdogStatus()` payload. Keep all old keys.
   Read the map one time for async and PE limits. A PE read error gives the
   `UNAVAILABLE` payload.
4. Server defaults: Warning 80 %, Critical 95 %. Two optional App Builder
   properties on the dashboard LWC override them. The LWC classifies again
   with the same rule when a valid override is set.
5. Keep the consequence text in the LWC. It is UI copy.

## Consequences

- No new schema, job or event. The read costs 0 SOQL and 0 DML.
- Two classifiers (Apex and JS) use the same rule. Tests in Apex and Jest
  cover the same boundaries.
- A `lightning__Tab` placement cannot set the override. It uses the defaults.

## Alternatives

- `Revenant_Config__mdt` threshold fields. Rejected: the issue forbids a new
  field in this slice.
- A new `@AuraEnabled` method with threshold parameters. Rejected: the issue
  asks for an additive `getWatchdogStatus()` payload, and the controller is
  at the PMD public-method limit.
- Classify on the rounded percent. Rejected: 79.996 % shows Warning too
  early.
