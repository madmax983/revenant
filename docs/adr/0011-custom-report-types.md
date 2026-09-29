# ADR 0011: Custom Report Types

- **Status:** Accepted
- **Date:** 2026-09-29
- **Issue:** #137

## Context

Admins use Reports and Dashboards for digests and dashboards. Revenant had no Custom Report Type. The issue permits metadata only: no field, object, event, CMDT or Apex. Some fields hold a storage pointer or a codec envelope, not a value.

## Decision

1. Two types, both with base object `Workflow_Instance__c`: `Revenant_Workflow_Instances` (no join) and `Revenant_Workflow_Instances_with_Steps` (outer join on `Workflow_Step_Executions__r`). The outer join shows a new instance with no step row.
2. Category `other`. The Metadata API category is a fixed list, so a "Revenant Workflows" category is not possible. Both labels start with "Revenant Workflow Instances". A search for "Revenant" finds both.
3. The types do not include fields that can hold a stored form: `Input__c`, `Output__c`, `Progress__c`, `Captured_Values__c`, `Error_Details__c`. They also do not include `Compensation_Stack__c` and engine internals. A column that is not in the type cannot show a pointer.
4. No lookup columns. A field path through a lookup cannot be checked without an org.
5. A Node test (`npm run test:report-types`) checks the XML with no org. It finds the stored-form writers in the Apex code. It makes each new field a decision: add it to a type or to an excluded list.

## Consequences

- Admins build reports with no developer. The cost is zero Apex and zero governor limits.
- The standard report types that the platform makes still show all fields. The doc tells admins to use the Revenant types.
- Step duration uses a row-level formula on `CreatedDate` and `LastModifiedDate`. It includes queue and retry waits.
- A new custom field on either object fails the test until someone adds it to a type or excludes it.
