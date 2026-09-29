# ADR 0011: Custom Report Types

- **Status:** Accepted
- **Date:** 2026-09-29
- **Issue:** #137

## Context

Admins use Reports and Dashboards to make charts and scheduled digests. Revenant had no Custom Report Type. The issue permits metadata only: no field, object, event, CMDT or Apex. Some fields can contain a pointer to a file or an encoded value, not the value.

## Decision

1. Two types, both with base object `Workflow_Instance__c`: `Revenant_Workflow_Instances` (no join) and `Revenant_Workflow_Instances_with_Steps` (outer join on `Workflow_Step_Executions__r`). The outer join shows a new instance with no step row.
2. Category `other`. The Metadata API category is a fixed list, so a "Revenant Workflows" category is not possible. Both labels start with "Revenant Workflow Instances". A search for "Revenant" finds both.
3. The types do not include fields that can contain a pointer or an encoded value: `Input__c`, `Output__c`, `Progress__c`, `Captured_Values__c`, `Error_Details__c`. They also do not include engine internals, for example `Compensation_Stack__c`. A column that is not in the type cannot show a pointer. This is not access control: field-level security controls access.
4. No column comes through a lookup (for example, the parent instance name). The test cannot check that field path without an org.
5. A Node test (`npm run test:report-types`) checks the XML with no org. It scans the Apex code for the fields that get a pointer or an encoded value. The scan follows assignments, `put` calls, local variables, static helper methods and field copies. Its header lists what it does not follow. It makes each new field a decision: add it to a type or to an excluded list.

## Consequences

- Admins make reports with no developer. Reports run no Apex and use no Apex governor limits.
- The standard report types that the platform makes still show all fields. The doc tells admins that field-level security, not the type, controls access.
- Step duration uses a row-level formula on `CreatedDate` and `LastModifiedDate`. It includes queue, retry and suspend waits.
- `Error_Message__c` and the key columns are plaintext. The doc tells admins that a subscription email shows them.
- A new custom field on either object fails the test until someone adds it to a type or excludes it.
