# Custom Report Types (Issue #137)

## Goal

Give admins Custom Report Types for `Workflow_Instance__c` and `Workflow_Step_Execution__c`. Metadata only. No Apex, no new schema.

## Facts

- Both objects have `enableReports` set to true.
- The step object is the detail of a master-detail to the instance. Relationship name: `Workflow_Step_Executions`.
- The report type category is a fixed list in the Metadata API. An org cannot add a category. There is no "Revenant Workflows" category.
- The engine can write a pointer or an encoded value to five fields: `Input__c`, `Output__c`, `Progress__c`, `Captured_Values__c` and `Error_Details__c`. `Compensation_Stack__c` contains engine JSON. `getStatus` reads the value. A report cannot.
- The step object has no start or end time field. `CreatedDate` is the row start. `LastModifiedDate` is the last write.
- No org was available. Node runs the static tests. The quickstart smoke deploys `force-app` to a scratch org in CI when the Dev Hub secret is set.

## Brainstorm (options)

| #   | Idea                                                                    | Keep?                                                                         |
| --- | ----------------------------------------------------------------------- | ----------------------------------------------------------------------------- |
| B1  | One type: instances only.                                               | Yes. Type 1.                                                                  |
| B2  | One type: instances with or without steps (outer join).                 | Yes. Type 2. A new instance with no step row shows.                           |
| B3  | Inner join (instances with steps only).                                 | No. A new instance does not show.                                             |
| B4  | Step as base object.                                                    | No. Type 2 covers it. The acceptance criteria ask for the instance as parent. |
| B5  | Custom category "Revenant Workflows".                                   | No. The platform does not allow it. Use `other`.                              |
| B6  | Label prefix "Revenant" on both types.                                  | Yes. A search for "Revenant" in Report Builder finds both.                    |
| B7  | Include all fields.                                                     | No. Pointer fields show a marker, not a value.                                |
| B8  | Leave pointer fields out of the type.                                   | Yes. Stronger than "not checked by default".                                  |
| B9  | Lookup columns (parent workflow name through `Parent_Instance__c`).     | No. The test cannot check the field path without an org. Follow-up.           |
| B10 | A duration formula field.                                               | No. AC 4 forbids new fields. Doc gives a row-level formula.                   |
| B11 | Canned reports and a dashboard.                                         | No. Out of scope.                                                             |
| B12 | Node test that reads the XML, the object fields and the permission set. | Yes. RED first. No org needed.                                                |
| B13 | Test scans Apex for stored-form writers.                                | Yes. A new offloaded field fails the test until the type excludes it.         |
| B14 | Test makes each field a decision: in a type or in the excluded list.    | Yes. A new field fails the test until someone decides.                        |

## Reverse Brainstorm (how can this fail?)

| Way to fail                                                        | Prevention                                                                  |
| ------------------------------------------------------------------ | --------------------------------------------------------------------------- |
| An admin reports on `{"$attachmentId":...}` as a value.            | Pointer fields are not in the types. Test B13.                              |
| `Error_Details__c` shows a codec envelope.                         | Leave it out. Test B13 finds `WorkflowFailureDetails.build`.                |
| A type names a field that does not exist. The deploy fails.        | Test: each column is a field of its table, or a known standard field.       |
| The join names the wrong relationship. The deploy fails.           | Test: the join is `<relationshipName>__r` of the master-detail field.       |
| An inner join hides new instances.                                 | Test: `outerJoin` is true.                                                  |
| Label or description too long. The deploy fails.                   | Test: label at most 50, description at most 255 characters.                 |
| Malformed XML.                                                     | Test parses each file.                                                      |
| A column shows blank for an operator.                              | Test: `Revenant_Operator` and `Revenant_Admin` can read each custom column. |
| A later field is added and not shown, or a pointer field is shown. | Test B14.                                                                   |
| Admin expects a "Revenant Workflows" category.                     | Doc and ADR tell the category and the label prefix.                         |
| Standard auto report types still show pointer fields.              | Doc tells admins to use the Revenant types.                                 |
| Duration looks wrong for a retried step.                           | Doc: the duration includes retry waits.                                     |

## Six Thinking Hats

- **White (facts):** Two objects, one master-detail, report flags on. The category list is fixed. Five fields hold a stored form. No org here.
- **Red (feelings):** Admins want a known tool and no developer. They do not trust a column that shows JSON noise.
- **Black (risks):** Deploy failure from a bad field path. A pointer read as a value. Wrong duration. No custom category.
- **Yellow (benefits):** Zero Apex, zero governor cost. Scheduled digests, dashboards, filters and groups by `Correlation_Key__c`.
- **Green (ideas):** Row-level formula for duration. Label prefix for grouping. A test that follows the Apex offload writers.
- **Blue (process):** Plan. ADR. RED test. GREEN metadata and doc. REFACTOR. Multi-angle review. Map each AC to evidence.

## Spec

Type `Revenant_Workflow_Instances`: base `Workflow_Instance__c`, category `other`, no join.

Type `Revenant_Workflow_Instances_with_Steps`: base `Workflow_Instance__c`, outer join `Workflow_Step_Executions__r`.

Default columns (checked):

| Section           | Fields                                                                                                                                                                                                                                                   |
| ----------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Instance (type 1) | `Name`, `Workflow_Name__c`, `Status__c`, `Correlation_Key__c`, `Definition_Version__c`, `Current_Step__c`, `Terminal_At__c`, `Error_Message__c`, `Failure_Category__c`, `Parent_Instance__c`, `Concurrency_Parked__c`, `CreatedDate`, `LastModifiedDate` |
| Instance (type 2) | `Name`, `Workflow_Name__c`, `Status__c`, `Correlation_Key__c`                                                                                                                                                                                            |
| Step (type 2)     | `Name`, `Step_Name__c`, `Status__c`, `Retry_Count__c`, `Transient_Retry_Count__c`, `CreatedDate`, `LastModifiedDate`                                                                                                                                     |

Excluded: the five pointer fields and the engine internals, `Compensation_Stack__c` also (see the test).

## Tasks

1. RED: `scripts/report-types/report-types.test.mjs`. Run. It fails (no files).
2. GREEN: two `*.reportType-meta.xml` files, `docs/report-types.md`, README link, ADR 0011, CI job, `npm run test:report-types`.
3. REFACTOR: shared column lists, short comments.
4. Review from several angles. Fix findings.
5. Map each AC to evidence.

## Review Round 1 (fixed)

| Finding                                                                  | Fix                                                               |
| ------------------------------------------------------------------------ | ----------------------------------------------------------------- |
| Default-column checks were one-way.                                      | Exact lists. The doc table is compared to the XML.                |
| The parser accepted a raw `&`, wrong element order and unknown elements. | `xml.mjs` rejects them. `checkOrder` uses the Metadata API order. |
| The scan missed variables, `put`, helpers, literals and copies.          | `stored-form-scan.mjs` follows them. Unit tests for each form.    |
| `Compensation_Stack__c` was in the pointer list.                         | Moved to the engine internals.                                    |
| `Error_Message__c` goes to subscription emails as plaintext.             | Doc section "Plaintext columns".                                  |
| Digest filter missed `CompensationFailed`. `LAST N DAYS:1` sent twice.   | `YESTERDAY` and `Failed`, `CompensationFailed`.                   |
| A dashboard cannot use a private report.                                 | Doc: save in a shared folder.                                     |
| The doc framed excluded fields as safety.                                | Doc: "This is not access control."                                |
