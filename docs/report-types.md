# Custom Report Types

Issue #137. Two Custom Report Types let an admin report on workflow runs in Reports and Dashboards. You do not write code. The types are metadata only. They add no field, object or Apex.

## Report types

| Label                                              | API name                                 | Rows                                                                                |
| -------------------------------------------------- | ---------------------------------------- | ----------------------------------------------------------------------------------- |
| `Revenant Workflow Instances`                      | `Revenant_Workflow_Instances`            | One row for each `Workflow_Instance__c`.                                            |
| `Revenant Workflow Instances with Step Executions` | `Revenant_Workflow_Instances_with_Steps` | One row for each `Workflow_Step_Execution__c`. An instance with no step shows once. |

The second type joins through the master-detail relationship `Workflow_Step_Executions`. The join is "with or without", so a new instance with no step row also shows.

**Category.** The report type category is a fixed list. An org cannot add a category. Both types are in **Other Reports**. In Report Builder, search for `Revenant` to find both.

## Default columns

| Section                | Checked by default                                                                                                                                                                                                                                       |
| ---------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Instance (first type)  | `Name`, `Workflow_Name__c`, `Status__c`, `Correlation_Key__c`, `Definition_Version__c`, `Current_Step__c`, `Terminal_At__c`, `Error_Message__c`, `Failure_Category__c`, `Parent_Instance__c`, `Concurrency_Parked__c`, `CreatedDate`, `LastModifiedDate` |
| Instance (second type) | `Name`, `Workflow_Name__c`, `Status__c`, `Correlation_Key__c`                                                                                                                                                                                            |
| Step (second type)     | `Name`, `Step_Name__c`, `Status__c`, `Retry_Count__c`, `Transient_Retry_Count__c`, `CreatedDate`, `LastModifiedDate`                                                                                                                                     |

You can also add these columns. Instance: all first-type defaults, `Root_Correlation_Key__c`, `Causation_Id__c`, `Previous_Instance__c`, `Previous_Run_At__c`, `Compensated_By__c`, `Deadline_At__c`, `Sleep_Until__c`, `Held__c`, `Held_At__c`, `Hold_Reason__c`, `Admission_Queue__c`, `Admission_Priority__c`, `Concurrency_Slot_Held__c`, `Global_Admission__c`. Step: `Timeout_At__c`, `CPU_Time_Ms__c`, `Heap_Size_Bytes__c`, `SOQL_Query_Count__c`.

## Fields not in the types

These fields can hold a stored form, not the value. A large payload (more than 100k characters) goes to a `ContentVersion` file. The field then holds a pointer such as `{"$attachmentId":"068..."}`. With a payload codec, the field holds an encoded envelope. `WorkflowEngine.getStatus` rehydrates and decodes. A report does not. Thus the types do not include these fields:

| Object                       | Fields                                                            |
| ---------------------------- | ----------------------------------------------------------------- |
| `Workflow_Instance__c`       | `Input__c`, `Output__c`, `Progress__c`, `Compensation_Stack__c`   |
| `Workflow_Step_Execution__c` | `Input__c`, `Output__c`, `Captured_Values__c`, `Error_Details__c` |

The types also do not include engine internals: `Active_Correlation_Key__c`, `Admission_Key__c`, `Async_Job_Id__c`, `Definition_Fingerprint__c`, `Definition_Shape__c` and `Decision_Record__c`.

**Standard report types.** The platform also makes standard report types for these objects (`Workflow Instances`, `Workflow Instances with Workflow Step Executions`). They show all fields, the pointer fields also. Use the Revenant types. To read a payload value, use `WorkflowEngine.getStatus` or the `workflowDashboard`.

## Access

Field visibility follows field-level security. A user sees a column only if the user can read the field. `Revenant_Operator` and `Revenant_Admin` give read access to each column. To make a report, a user also needs the **Create and Customize Reports** permission. A dashboard shows the data that its running user can see.

## Make a daily digest of failed instances

This takes less than 5 minutes. You do not write code.

1. Open **Reports**. Click **New Report**. Search for `Revenant`. Select **Revenant Workflow Instances**. Click **Start Report**.
2. In **Filters**, set **Show Me** to all workflow instances and **Created Date** to **All Time**.
3. Add a filter: **Terminal At** equals `LAST N DAYS:1` (yesterday and today).
4. In **Group Rows**, add **Workflow Name**, then **Status**.
5. Click **Save**. Give the name `Workflow outcomes, last day`. Select a folder.
6. Open **Dashboards**. Click **New Dashboard**. Click **+ Component**. Select the report. Select a stacked bar chart. Click **Add**, then **Save**.
7. Open the report. Click **Save As**. Give the name `Failed instances, last day`. Add a filter: **Status** equals `Failed`. Save.
8. Click **Subscribe**. Set the frequency to **Daily** and a time. Click **Save**.

## Step duration

The step object has no start or end time field. Use the row timestamps:

1. Make a report with **Revenant Workflow Instances with Step Executions**.
2. Add a filter: step **Status** equals `Completed`.
3. Click **Add Row-Level Formula**. Set the output type to **Number**. Insert the step **Last Modified Date**, a minus sign and the step **Created Date**. Then multiply by `1440` to get minutes.
4. Group by **Workflow Name** and **Step Name**. Show the average of the formula.

The time starts when the engine inserts the step row. It includes the queue wait and each retry wait.

## Limits

- `Correlation_Key__c` is text, not a lookup. A report type cannot join it to other objects. Use it as a filter or a group.
- No column comes through a lookup (for example, the name of the parent instance).
- Archived rows (#105) are not in the report types.
- The types contain no sample reports or dashboards.

## Tests

`npm run test:report-types` reads the XML with no org. It checks:

- the label, the category, the outer join and the default columns;
- each column is a field of its object;
- each custom field is in a type or in an excluded list;
- no type includes a field that the Apex code writes a stored form to;
- `Revenant_Operator` and `Revenant_Admin` can read each column.

The quickstart smoke (`.github/workflows/quickstart.yml`) deploys `force-app` to a scratch org. That deploy includes the report types.
