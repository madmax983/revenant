# Operator Retry Policy (`Workflow_Retry_Config__mdt`)

An operator changes the retry policy of a workflow or a step in Setup. The
next retry attempt uses the change. No deploy is necessary. Issue #103.

## Fields

| Field                         | Meaning                                                                     |
| ----------------------------- | --------------------------------------------------------------------------- |
| `Workflow_Definition__c`      | Required. Workflow API name, as in `Workflow_Instance__c.Workflow_Name__c`. |
| `Step_Name__c`                | Optional. Step name. Blank: the record applies to all steps.                |
| `Initial_Interval_Seconds__c` | Seconds before the first retry.                                             |
| `Backoff_Coefficient__c`      | Multiplier for each next interval. 1.0 gives a fixed interval.              |
| `Maximum_Attempts__c`         | Attempts before the step fails.                                             |
| `Override_Author_Policy__c`   | For incidents. Checked: the record wins over an author policy.              |

The `DeveloperName` is free. The engine does not use it to match.

## Resolution Rule

1. **Match.** The engine looks for a record at each retry outcome:
   - a step record for `(workflow, step)`, else
   - a definition record for `(workflow, blank step)`, else
   - no record.

   The match ignores case and outer spaces. For two records with the same
   key, the lowest `DeveloperName` wins. The step record replaces the
   definition record fully. It does not merge with it.

2. **Apply.** "No author policy" means `RetryPolicy.fromConfig()` or a null
   policy.

   | Author policy | Record | Override | Effective policy                     |
   | ------------- | ------ | -------- | ------------------------------------ |
   | none          | none   | -        | engine default: 5 s, 2.0, 5 attempts |
   | none          | match  | any      | record fields over engine default    |
   | set           | none   | -        | author policy                        |
   | set           | match  | clear    | author policy                        |
   | set           | match  | checked  | record fields over author policy     |

3. **Blank or bad field.** A blank field, a count below 1, or a backoff
   below 1.0 keeps the value of the lower layer. Decimal counts round down.

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
Each instance retries 6 times. Stop the retries at 3 attempts:

1. In Setup, open **Custom Metadata Types** > **Workflow Retry Config** >
   **Manage Records**.
2. Edit the `PartnerSync` record. Set **Maximum Attempts** to `3`.
3. Save. The next retry outcome of each instance uses the new cap. An
   instance with 3 or more attempts fails at its next retry outcome, with
   category `RETRIES_EXHAUSTED`.

If the step code gives its own policy, also check
**Override Author Policy**. Clear it after the incident.

The same record as metadata:

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
- **Next attempt.** Each retry outcome runs in a new transaction and reads
  the record again. A retry job that is already scheduled keeps its delay.
  The new delay applies from the next retry outcome.
- **`ctx.isFinalAttempt()`.** An override record shows at once. The context
  also shows a record for `fromConfig()`, `RetryConfigurable` and
  auto-retry policies. For a step that returns `retry(...)` with no such
  interface, a record change shows after the next retry outcome.

## Out of Scope

- A retry override for one instance. Use operator re-drive (#81).
- Which errors are retryable. See auto-retry (#101).
- A custom editor. Use the Setup UI.
