# ADR 0006: Platform Event allocation in System Doctor

- **Status:** Accepted
- **Date:** 2026-09-28
- **Issue:** #120

## Context

The engine signal plane uses Platform Events. All apps in the org share the
allocation. When it is full, a publish can fail. The engine does not see a
failure that occurs after commit. System Doctor shows async Apex use, but
not Platform Event use. The issue forbids a new object, field, scheduled job
or change to the code that runs each step. It asks for configurable
thresholds.

## Decision

1. Add `PlatformEventHeadroom`. It reads five PE keys from the
   `System.OrgLimits` map. For each key, it calculates used, remaining,
   percent, state and impact (`PUBLISH`, `DELIVERY` or `STANDARD_VOLUME`).
   It skips a key that has no positive limit.
2. Classify on the exact ratio (`used × 100 ≥ threshold × limit`). Round the
   displayed percents down.
3. Add the result to the `getWatchdogStatus()` payload. Keep all old keys.
   Read the map one time for async and PE limits. If the PE read fails, the
   service returns the `UNAVAILABLE` payload.
4. Server defaults: Warning 80%, Critical 95%. Two optional App Builder
   properties on the dashboard LWC replace them. When an operator sets a
   valid value, the LWC classifies each row again with the same rule.
5. Keep the consequence text in the LWC. It is UI copy. Show only the text
   for the impacts at risk. Delivery to Apex triggers does not use a
   delivery allocation, so a delivery key does not stop wake-ups.

## Consequences

- No new schema, job or event. The read uses 0 SOQL and 0 DML.
- Apex and JS have the same classifier rule. Tests in Apex and Jest cover
  the same boundaries.
- On a Lightning tab, you cannot set the properties. The tab uses the
  defaults.

## Alternatives

- `Revenant_Config__mdt` threshold fields. Rejected: the issue forbids a new
  field in this slice.
- A new `@AuraEnabled` method with threshold parameters. Rejected: the issue
  asks for an additive `getWatchdogStatus()` payload, and the controller is
  at the PMD public-method limit.
- Classify on the rounded percent. Rejected: 79.996% shows Warning too
  early.
- One consequence text for all keys. Rejected: it tells the operator that
  wake-ups can stop when only external delivery is at risk.
