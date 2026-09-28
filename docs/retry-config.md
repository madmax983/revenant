# Operator Retry Policy (`Workflow_Retry_Config__mdt`)

An operator changes the retry policy of a workflow or a step in Setup. The
next retry outcome uses the change. No deploy is necessary. Issue #103.

A retry outcome is the point where the engine gets a RETRY result. The engine
then schedules the next attempt or fails the step.

## Fields

| Field                         | Meaning                                                                                                                                               |
| ----------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Workflow_Definition__c`      | Required. Workflow API name, as in `Workflow_Instance__c.Workflow_Name__c`. Include the namespace and the outer class (for example `ns.Outer.Inner`). |
| `Step_Name__c`                | Optional. Step name, as in `Workflow_Step_Execution__c.Step_Name__c` (for example `RetryConfigWorkflowExample.PushOrderStep`). Blank: all steps.      |
| `Initial_Interval_Seconds__c` | Seconds before the first retry.                                                                                                                       |
| `Backoff_Coefficient__c`      | Multiplier for each next interval. 1.0 gives a fixed interval.                                                                                        |
| `Maximum_Attempts__c`         | Attempts before the step fails. The lowest valid value is 1: the first failure fails the step.                                                        |
| `Override_Author_Policy__c`   | For incidents. Checked: the record has priority over an author policy and over a record without override.                                             |

The engine does not use `DeveloperName` to match. For two records with the same
key, the lowest `DeveloperName` wins.

## Resolution Rule

The engine resolves the policy at each retry outcome:

1. **Start.** Use the author policy, else the engine default (5 s, 2.0,
   5 attempts). The values of a `RetryPolicy.fromConfig()` policy are a start
   value, not an author policy.
2. **Record.** If the step has no author policy, put the most specific
   record over the start value.
3. **Override.** Put the most specific override record over the result.

"Most specific" is the step record for `(workflow, step)`, else the
definition record for `(workflow, blank step)`. The step record replaces the
definition record fully. It does not merge with it. The match ignores case
and outer spaces. For two records with the same key, the lowest
`DeveloperName` wins.

"Put a record over a value" means: each valid record field replaces the
value. The engine ignores a blank field, a count below 1 and a backoff below
1.0. Decimal counts round down.

| Author policy | Record without override | Override record | Effective policy                   |
| ------------- | ----------------------- | --------------- | ---------------------------------- |
| none          | none                    | none            | engine default                     |
| none          | match                   | none            | record over engine default         |
| set           | any                     | none            | author policy                      |
| none          | any                     | match           | override record over steps 1 and 2 |
| set           | any                     | match           | override record over author policy |

A definition override record thus caps each step, also a step that has its
own record without override.

"Author policy" is the policy in `StepResult.retry(policy)`,
`RetryConfigurable.getRetryPolicy()` or
`AutoRetryConfigurable.getAutoRetryPolicy()`. A compensation retry uses the
same rule. Its step name is `<StepName>_Compensate`.

## Let the Operator Own the Policy (Author)

```apex
public StepResult execute(StepContext ctx) {
  Integer status = PartnerApi.pushOrder(ctx.idempotencyKey);
  if (status == 503) {
    return StepResult.retry(RetryPolicy.fromConfig());
  }
  return StepResult.complete(null, status);
}
```

With no record, `fromConfig()` gives the engine default. So the behavior
does not change for an org with no records.

## Cap a Flaky Callout During an Incident (Operator)

The partner API of `RetryConfigWorkflowExample.PartnerSyncWorkflow` is down.
Each instance makes up to 6 attempts. Stop the attempts at 3:

1. In Setup, open **Custom Metadata Types** > **Workflow Retry Config** >
   **Manage Records**.
2. Edit the `PartnerSync` record. Set **Maximum Attempts** to `3`.
3. Save. The next retry outcome of each instance uses the new cap. An
   instance with 3 or more attempts fails at its next retry outcome, with
   category `RETRIES_EXHAUSTED`.

If the step code gives its own policy, also check
**Override Author Policy**. Clear it after the incident. To stop all retries,
set **Maximum Attempts** to `1`. The engine ignores `0`.

The same record as metadata
(`examples/main/default/customMetadata/Workflow_Retry_Config.PartnerSync.md-meta.xml`).
A deploy replaces all fields, so keep all values:

```xml
<CustomMetadata xmlns="http://soap.sforce.com/2006/04/metadata"
    xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
    xmlns:xsd="http://www.w3.org/2001/XMLSchema">
    <label>PartnerSync</label>
    <protected>false</protected>
    <values>
        <field>Workflow_Definition__c</field>
        <value xsi:type="xsd:string">RetryConfigWorkflowExample.PartnerSyncWorkflow</value>
    </values>
    <values>
        <field>Initial_Interval_Seconds__c</field>
        <value xsi:type="xsd:double">30.0</value>
    </values>
    <values>
        <field>Backoff_Coefficient__c</field>
        <value xsi:type="xsd:double">2.0</value>
    </values>
    <values>
        <field>Maximum_Attempts__c</field>
        <value xsi:type="xsd:double">3.0</value>
    </values>
</CustomMetadata>
```

See [RetryConfigWorkflowExample](../examples/main/default/classes/RetryConfigWorkflowExample.cls)
and its test `operatorCapsAttemptsInTheMiddleOfAnIncident`.

## Guarantees

- **No SOQL.** The engine reads records with `getAll()`, from the metadata
  cache. A test checks `Limits.getQueries()`.
- **No history change.** The resolver does no DML. The engine does not
  change the old `Workflow_Step_Execution__c` rows. The retry updates only
  its own row, as before.
- **Next retry outcome.** Each retry outcome runs in a new transaction and reads
  the record again. A retry job that is already scheduled keeps its delay.
  The new delay applies from the next retry outcome.
- **Apex tests.** Tests ignore org records, so an incident record cannot
  block a deploy. A test sets `WorkflowRetryConfigResolver.mockRecords`, or
  sets `readOrgRecordsInTest` to read the org records.
- **Delay cap.** The engine caps each delay at 86400 s (1 day), also for a
  very large interval or backoff.
- **`ctx.isFinalAttempt()`.** An override record shows immediately. A
  record without override shows immediately when `getRetryPolicy()` returns
  null or `fromConfig()`, or when `getAutoRetryPolicy()` returns
  `fromConfig()`. For other steps, the context shows the cap of the last
  retry outcome. A timeout fallback run cannot auto-retry, so an override
  record does not raise its cap of 1.

## Out of Scope

- A retry override for one instance. Use operator re-drive (#81).
- Which errors are retryable. See auto-retry (#101).
- A custom editor. Use the Setup UI.
