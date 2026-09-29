# Custom Report Types

Issue #137. Two Custom Report Types let an admin make reports, dashboards and scheduled digests about workflow instances, with no code. The types are metadata only. They add no field, object or Apex class.

## Report types

| Label                                              | API name                                 | Rows                                                                                |
| -------------------------------------------------- | ---------------------------------------- | ----------------------------------------------------------------------------------- |
| `Revenant Workflow Instances`                      | `Revenant_Workflow_Instances`            | One row for each `Workflow_Instance__c`.                                            |
| `Revenant Workflow Instances with Step Executions` | `Revenant_Workflow_Instances_with_Steps` | One row for each `Workflow_Step_Execution__c`. An instance with no step shows once. |

The second type uses an outer join on the master-detail relationship `Workflow_Step_Executions__r`. Thus a report shows an instance that has no step row.

**Category.** The platform has a fixed list of report type categories. An org cannot add a category. Both types are in **Other Reports**. To find them in Report Builder, search for `Revenant`.

## Default columns

| Section                | Checked by default                                                                                                                                                                                                                                       |
| ---------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Instance (first type)  | `Name`, `Workflow_Name__c`, `Status__c`, `Correlation_Key__c`, `Definition_Version__c`, `Current_Step__c`, `Terminal_At__c`, `Error_Message__c`, `Failure_Category__c`, `Parent_Instance__c`, `Concurrency_Parked__c`, `CreatedDate`, `LastModifiedDate` |
| Instance (second type) | `Name`, `Workflow_Name__c`, `Status__c`, `Correlation_Key__c`                                                                                                                                                                                            |
| Step (second type)     | `Name`, `Step_Name__c`, `Status__c`, `Retry_Count__c`, `Transient_Retry_Count__c`, `CreatedDate`, `LastModifiedDate`                                                                                                                                     |

You can add these columns to a report:

- Instance: the defaults of the first type, `Root_Correlation_Key__c`, `Causation_Id__c`, `Previous_Instance__c`, `Previous_Run_At__c`, `Compensated_By__c`, `Deadline_At__c`, `Sleep_Until__c`, `Held__c`, `Held_At__c`, `Hold_Reason__c`, `Admission_Queue__c`, `Admission_Priority__c`, `Concurrency_Slot_Held__c`, `Global_Admission__c`.
- Step: `Timeout_At__c`, `CPU_Time_Ms__c`, `Heap_Size_Bytes__c`, `SOQL_Query_Count__c`.

## Fields not in the types

These fields can contain a pointer or an encoded value:

| Object                       | Fields                                                            |
| ---------------------------- | ----------------------------------------------------------------- |
| `Workflow_Instance__c`       | `Input__c`, `Output__c`, `Progress__c`                            |
| `Workflow_Step_Execution__c` | `Input__c`, `Output__c`, `Captured_Values__c`, `Error_Details__c` |

- **Pointer.** When the stored text has more than 100,000 characters, the engine puts it in a file. The field then contains a pointer such as `{"$attachmentId":"069..."}`.
- **Encoded value.** When you set a payload codec, the field contains an encoded value.
- `Error_Details__c` contains the reason. When you set a codec, the pointer or the encoded value comes after the reason. With no codec, this field contains plaintext only.

`WorkflowStatusRead.getStatus` reads the file and decodes the value. A report cannot do this. Thus the types do not include these fields.

The types also do not include engine internals: `Active_Correlation_Key__c`, `Admission_Key__c`, `Async_Job_Id__c`, `Compensation_Stack__c`, `Definition_Fingerprint__c`, `Definition_Shape__c` and `Decision_Record__c`. The step field `Workflow_Instance__c` is not a column, because the instance section shows the parent.

**This is not access control.** With no codec, these fields contain the plaintext value or a pointer. The platform also makes standard report types for these objects (`Workflow Instances`, `Workflow Instances with Workflow Step Executions`). They show all fields. This includes these fields. A user who can read a field and has **Create and Customize Reports** can report on it. To stop this, remove the field read access, or limit the report permission and the report folders.

## Plaintext columns

The payload codec does not encode these columns. For the codec scope, see [What stays plaintext](payload-codec.md#what-stays-plaintext).

- `Error_Message__c` (checked by default in the first type): engine text, exception messages and fail reasons.
- `Hold_Reason__c`: operator text.
- `Correlation_Key__c`, `Root_Correlation_Key__c`, `Causation_Id__c`: caller keys.

Do not put payload data in exception messages, fail reasons or keys. A subscription email and a dashboard show the rows that the running user can see. The recipient can see these rows also.

## Access

Field visibility follows field-level security. A user sees a column only if the user can read the field. `Revenant_Operator` and `Revenant_Admin` give read access to each column. To make a report, a user also needs the **Create and Customize Reports** permission.

## Make a daily digest of failed instances

You do not write code.

1. Open **Reports** and click **New Report**.
2. Search for `Revenant`. Select **Revenant Workflow Instances** and click **Start Report**.
3. In **Filters**, set **Show Me** to all workflow instances.
4. Set **Created Date** to **All Time**.
5. Add the filter **Terminal At** equals `YESTERDAY`.
6. In **Group Rows**, add **Workflow Name**, then **Status**.
7. Click **Save**. Type the name `Workflow outcomes, yesterday` and select a shared folder. A dashboard cannot use a report in **Private Reports**.
8. Open **Dashboards** and click **New Dashboard**. Type a name, select a folder and click **Create**.
9. Click **+ Component** and select the report. Select a stacked bar chart and click **Add**. Click **Save**.
10. Open the report and click **Save As**. Type the name `Failed instances, yesterday`.
11. Add the filter **Status** equals `Failed`, `CompensationFailed`. To include instances that the engine rolled back, also add `Compensated`. Click **Save**.
12. Click **Subscribe**. Set the frequency to **Daily**, set a time and click **Save**.

## Step duration

The step object has no start or end time field. Use the row timestamps:

1. Make a report with **Revenant Workflow Instances with Step Executions**.
2. Add the filter step **Status** equals `Completed`.
3. Click **Add Row-Level Formula**. Set the output type to **Number** with 2 decimal places.
4. Type the formula `(LastModifiedDate - CreatedDate) * 1440`. Use the step fields from the field list. The result is in minutes.
5. Group by **Workflow Name** and **Step Name**. Show the average of the formula.

The time starts when the engine inserts the step row. It includes the queue wait, each retry wait, and each suspend or approval wait.

## Limits

- `Correlation_Key__c` is text, not a lookup. A report type cannot join it to other objects. Use it to filter or group rows.
- No column comes through a lookup (for example, the name of the parent instance).
- Reports do not show archived rows (#105).
- Revenant does not include sample reports or dashboards.

## Tests

`npm run test:report-types` reads the files with no org. It checks:

- the element order, the label, the category, the outer join and the exact default columns;
- the default-column table in this doc against the XML;
- each column is a field of its object;
- each custom field is in a type or in an excluded list;
- no column has the name of a field that the engine Apex writes a pointer or an encoded value to. The scan follows assignments, `put` calls, local variables, helper methods and field copies. It knows the field name only. The header of `scripts/report-types/stored-form-scan.mjs` lists what it does not follow;
- `Revenant_Operator` and `Revenant_Admin` can read each column.

The quickstart smoke (`.github/workflows/quickstart.yml`) deploys `force-app` to a scratch org. That deploy includes the report types. The smoke runs only when the `DEVHUB_SFDX_AUTH_URL` secret is set.
