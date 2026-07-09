# Publish Threshold Alerts to Platform Event Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Publish a detailed `Workflow_Alert__e` platform event when an alert is triggered (based on consecutive failures or sliding window thresholds), allowing admins to easily route alert payloads (such as workflow name, instance ID, correlation key, error, reason, and thresholds) to Slack/PagerDuty via a subscribable Salesforce Flow.

**Architecture:** Extend `WorkflowAlertManager` to conditionally publish `Workflow_Alert__e` parallel to (or instead of) sending emails when `Publish_Alert_Event__c` is enabled. We will reuse the existing threshold evaluation logic to determine if an alert is warranted, and then dispatch either email, event, or both. We will also update the permission set and write unit tests asserting that the event is published with the correct fields.

**Tech Stack:** Apex, Salesforce DX Metadata, Platform Events

---

## Brainstorming & Analysis

### 1. Brainstorming Design Details
- **Trigger Condition:** The event should publish *only* when an alert is warranted (i.e. `evaluateThresholds` returns true). We will modify the early exit in `WorkflowAlertManager.sendAlert` so that it doesn't bypass execution if `Email_Recipients__c` is blank but `Publish_Alert_Event__c` is true.
- **Payload Fields for `Workflow_Alert__e`:**
  - `Workflow_Name__c` (Text, 255)
  - `Workflow_Instance_Id__c` (Text, 255)
  - `Correlation_Key__c` (Text, 255)
  - `Error_Message__c` (LongTextArea, 131072)
  - `Alert_Reason__c` (Text, 255) - values: `'consecutive-failure'`, `'sliding-window'`, `'immediate'` (or `'default'`)
  - `Consecutive_Failures_Limit__c` (Number, 18, 0)
  - `Failure_Count_Limit__c` (Number, 18, 0)
  - `Time_Window_Minutes__c` (Number, 18, 0)
- **Metadata Toggle on `Workflow_Alert_Config__mdt`:**
  - `Publish_Alert_Event__c` (Checkbox)
- **Unit Testing Strategy:** We will utilize a static list in `WorkflowAlertManager` (`@TestVisible private static List<Workflow_Alert__e> publishedEvents = new List<Workflow_Alert__e>();`) to capture published events in tests and allow precise assertions on fields.

### 2. Reverse Brainstorming (How could it fail?)
- **Risk 1: Event publication throws an exception, failing the Orchestrator's hot path.**
  - *Mitigation:* Wrap the `EventBus.publish` call in a try-catch block and log/ignore errors, matching the existing email alert exception isolation.
- **Risk 2: Duplicate events are published for the same instance.**
  - *Mitigation:* Re-use the existing `Terminal_At__c` deduplication logic within `sendAlert` unchanged. Since we only call `sendAlert` when transitioning, the deduplication is inherently preserved.
- **Risk 3: Config is disabled but events still publish.**
  - *Mitigation:* Ensure `Publish_Alert_Event__c` is checked only if `Enable_Alerts__c` is true.
- **Risk 4: Empty email recipient disables the event path.**
  - *Mitigation:* Update the guard check in `sendAlert` to: `if (config == null || !config.Enable_Alerts__c || (String.isBlank(config.Email_Recipients__c) && !config.Publish_Alert_Event__c)) { return; }`

### 3. Six Hats Thinking
- **White Hat (Facts):** We need to define 1 platform event object + 8 custom fields + 1 custom metadata field, update 1 Apex class + 1 test class, and update 1 permission set.
- **Red Hat (User Experience):** Flow admins will love having the threshold limit values directly on the event payload. This avoids having to query `Workflow_Alert_Config__mdt` inside the Flow, bringing MTTR under 10 minutes.
- **Black Hat (Risks):** Governor limits for platform event publishing. Since alerts are throttled by definition (consecutive/sliding-window thresholds and single terminal transition per instance), the volume of `Workflow_Alert__e` will be extremely low, meaning minimal impact on limits.
- **Yellow Hat (Optimism):** Simplifies integrations with third-party tools (Slack, PagerDuty) to zero-Apex Flow configurations.
- **Green Hat (Creativity):** Passing the alert reason (e.g. `consecutive-failure` vs `sliding-window` vs `immediate`) as a standard string field enables conditional routing inside Flow (e.g. higher-urgency paging for sliding-window burst failures).
- **Blue Hat (Process):** We will use TDD. We will write the failing tests first, implement the metadata and code, and verify they pass.

---

## Proposed Changes

### Metadata Changes

#### [NEW] [Workflow_Alert__e.object-meta.xml](file:///c:/Users/markm/revenant/force-app/main/default/objects/Workflow_Alert__e/Workflow_Alert__e.object-meta.xml)
Creates the platform event object with HighVolume event type and PublishAfterCommit behavior.

#### [NEW] `Workflow_Alert__e` Fields
- [Workflow_Name__c.field-meta.xml](file:///c:/Users/markm/revenant/force-app/main/default/objects/Workflow_Alert__e/fields/Workflow_Name__c.field-meta.xml) (Text, 255)
- [Workflow_Instance_Id__c.field-meta.xml](file:///c:/Users/markm/revenant/force-app/main/default/objects/Workflow_Alert__e/fields/Workflow_Instance_Id__c.field-meta.xml) (Text, 255)
- [Correlation_Key__c.field-meta.xml](file:///c:/Users/markm/revenant/force-app/main/default/objects/Workflow_Alert__e/fields/Correlation_Key__c.field-meta.xml) (Text, 255)
- [Error_Message__c.field-meta.xml](file:///c:/Users/markm/revenant/force-app/main/default/objects/Workflow_Alert__e/fields/Error_Message__c.field-meta.xml) (LongTextArea, 131072)
- [Alert_Reason__c.field-meta.xml](file:///c:/Users/markm/revenant/force-app/main/default/objects/Workflow_Alert__e/fields/Alert_Reason__c.field-meta.xml) (Text, 255)
- [Consecutive_Failures_Limit__c.field-meta.xml](file:///c:/Users/markm/revenant/force-app/main/default/objects/Workflow_Alert__e/fields/Consecutive_Failures_Limit__c.field-meta.xml) (Number, 18, 0)
- [Failure_Count_Limit__c.field-meta.xml](file:///c:/Users/markm/revenant/force-app/main/default/objects/Workflow_Alert__e/fields/Failure_Count_Limit__c.field-meta.xml) (Number, 18, 0)
- [Time_Window_Minutes__c.field-meta.xml](file:///c:/Users/markm/revenant/force-app/main/default/objects/Workflow_Alert__e/fields/Time_Window_Minutes__c.field-meta.xml) (Number, 18, 0)

#### [NEW] [Publish_Alert_Event__c.field-meta.xml](file:///c:/Users/markm/revenant/force-app/main/default/objects/Workflow_Alert_Config__mdt/fields/Publish_Alert_Event__c.field-meta.xml)
Boolean checkbox on custom metadata type indicating if `Workflow_Alert__e` should be published.

#### [MODIFY] [Revenant_Admin.permissionset-meta.xml](file:///c:/Users/markm/revenant/force-app/main/default/permissionsets/Revenant_Admin.permissionset-meta.xml)
Grants access to the new custom metadata field and the `Workflow_Alert__e` object and its fields.

---

### Code Changes

#### [MODIFY] [WorkflowAlertManager.cls](file:///c:/Users/markm/revenant/force-app/main/default/classes/WorkflowAlertManager.cls)
- Query `Publish_Alert_Event__c` in all `Workflow_Alert_Config__mdt` queries.
- Update `sendAlert` to check `Publish_Alert_Event__c` and support blank `Email_Recipients__c` if the toggle is true.
- Refactor/enhance `evaluateThresholds` or add a helper to return the `alertReason` (e.g. `'consecutive-failure'`, `'sliding-window'`, or `'immediate'`).
- Add private static `dispatchEvent` to construct and publish the event using `EventBus.publish`.
- Capture published events in a `@TestVisible` list for unit testing.

#### [MODIFY] [WorkflowAlertManagerTest.cls](file:///c:/Users/markm/revenant/force-app/main/default/classes/WorkflowAlertManagerTest.cls)
- Update `createMockConfig` helper to accept and populate `Publish_Alert_Event__c`.
- Write new unit tests:
  - Verify that a `Workflow_Alert__e` is published when the toggle is enabled.
  - Verify the alert reason matches the evaluated threshold (`consecutive-failure` vs `sliding-window` vs `immediate`).
  - Verify that blank `Email_Recipients__c` with the event toggle enabled still triggers the alert event.
  - Verify that no event is published if the toggle is disabled.

---

## Verification Plan

### Automated Tests
- Run Apex tests:
  `sf apex run test -n WorkflowAlertManagerTest -w 5`

### Manual Verification
- Deploy metadata and verify it compiles on the scratch org:
  `sf project deploy start`
