# Operator Signal Injection Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Implement the "Send Signal" dashboard operator action to manually inject named signals into stuck Suspended workflow instances.

**Architecture:** Expose a permission-gated `@AuraEnabled` method `injectSignal` on `WorkflowDashboardController.cls` that validates input and routes to `WorkflowEngine.signal`, and provide a modal/action in the `workflowDashboard` LWC component for operator interaction.

**Tech Stack:** Apex, Lightning Web Components (LWC), Salesforce Custom Permissions.

---

### Task 1: Custom Permission Metadata

**Files:**
- Create: `force-app/main/default/customPermissions/Workflow_Signal_Injection.customPermission-meta.xml`
- Modify: `force-app/main/default/permissionsets/Revenant_Admin.permissionset-meta.xml`

**Step 1: Write Custom Permission file**
Create the metadata file defining the custom permission `Workflow_Signal_Injection`.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<CustomPermission xmlns="http://soap.sforce.com/2006/04/metadata">
    <description>Grants permission to manually inject signals into stuck Suspended workflow instances from the dashboard.</description>
    <label>Workflow Signal Injection</label>
</CustomPermission>
```

**Step 2: Modify Permission Set**
Add `<customPermissions>` node to `Revenant_Admin.permissionset-meta.xml` so the permission is enabled for Revenant Admin:
```xml
    <customPermissions>
        <enabled>true</enabled>
        <name>Workflow_Signal_Injection</name>
    </customPermissions>
```

**Step 3: Deploy metadata**
Deploy custom permission and permission set:
`sf project deploy start`

**Step 4: Commit**
`git add force-app/main/default/customPermissions/Workflow_Signal_Injection.customPermission-meta.xml force-app/main/default/permissionsets/Revenant_Admin.permissionset-meta.xml`
`git commit -m "feat: add Workflow_Signal_Injection custom permission metadata"`

---

### Task 2: Apex Method and Tests (Red Phase)

**Files:**
- Modify: `force-app/main/default/classes/WorkflowDashboardControllerTest.cls`

**Step 1: Write failing test in WorkflowDashboardControllerTest**
Add tests to verify:
- `testInjectSignalSuccess`: checks happy-path signaling on Suspended instance.
- `testInjectSignalNonSuspendedRejection`: checks that attempts on non-Suspended instances fail.
- `testInjectSignalInvalidJsonRejection`: checks that invalid payload JSON is rejected.
- `testInjectSignalAuthorization`: checks that the custom permission (or Modify All Data) is enforced.
- `testInjectSignalAttribution`: checks that operator details are added to the payload.

```apex
  @isTest
  static void testInjectSignalSuccess() {
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
      Status__c = 'Suspended',
      Correlation_Key__c = 'SignalKey1',
      Input__c = '"InputData"'
    );
    insert inst;

    Test.startTest();
    WorkflowDashboardController.injectSignal(inst.Id, 'PaymentReceived', '{"amount": 100}');
    Test.stopTest();

    Test.getEventBus().deliver();

    List<Workflow_Signal__c> signals = [
      SELECT Id, Signal_Name__c, Payload__c
      FROM Workflow_Signal__c
      WHERE Workflow_Instance__c = :inst.Id
    ];
    System.assertEquals(1, signals.size());
    System.assertEquals('PaymentReceived', signals[0].Signal_Name__c);
    System.assert(signals[0].Payload__c.contains('"amount":100') || signals[0].Payload__c.contains('"amount": 100'), 'Payload should match');
  }

  @isTest
  static void testInjectSignalNonSuspendedRejection() {
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
      Status__c = 'Running',
      Correlation_Key__c = 'SignalKey2',
      Input__c = '"InputData"'
    );
    insert inst;

    try {
      WorkflowDashboardController.injectSignal(inst.Id, 'PaymentReceived', '{}');
      System.assert(false, 'Should throw exception on non-Suspended instance');
    } catch (AuraHandledException e) {
      System.assert(e.getMessage().contains('Suspended'), e.getMessage());
    }
  }

  @isTest
  static void testInjectSignalInvalidJsonRejection() {
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
      Status__c = 'Suspended',
      Correlation_Key__c = 'SignalKey3',
      Input__c = '"InputData"'
    );
    insert inst;

    try {
      WorkflowDashboardController.injectSignal(inst.Id, 'PaymentReceived', '{invalid}');
      System.assert(false, 'Should throw exception on invalid JSON');
    } catch (AuraHandledException e) {
      System.assert(e.getMessage().contains('Invalid payload JSON'), e.getMessage());
    }
  }

  @isTest
  static void testInjectSignalAuthorization() {
    Profile stdProfile = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
    User stdUser = new User(
      Alias = 'sigusr',
      Email = 'siguser@testorg.com',
      EmailEncodingKey = 'UTF-8',
      LastName = 'Signaler',
      LanguageLocaleKey = 'en_US',
      LocaleSidKey = 'en_US',
      ProfileId = stdProfile.Id,
      TimeZoneSidKey = 'America/Los_Angeles',
      UserName = 'stduser_sig_test_' + DateTime.now().getTime() + '@testorg.com'
    );

    System.runAs(new User(Id = UserInfo.getUserId())) {
      insert stdUser;
      CustomPermission cp = [SELECT Id FROM CustomPermission WHERE DeveloperName = 'Workflow_Admin' LIMIT 1];
      PermissionSet ps = new PermissionSet(Label = 'Workflow Admin Sig PS', Name = 'Workflow_Admin_Sig_PS');
      insert ps;
      insert new SetupEntityAccess(ParentId = ps.Id, SetupEntityId = cp.Id);
      insert new PermissionSetAssignment(AssigneeId = stdUser.Id, PermissionSetId = ps.Id);
    }

    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
      Status__c = 'Suspended',
      Correlation_Key__c = 'SignalKey4',
      Input__c = '"InputData"'
    );
    insert inst;

    System.runAs(stdUser) {
      try {
        WorkflowDashboardController.injectSignal(inst.Id, 'PaymentReceived', '{}');
        System.assert(false, 'Should be blocked without Workflow_Signal_Injection permission');
      } catch (AuraHandledException e) {
        System.assert(e.getMessage().contains('Workflow_Signal_Injection'), e.getMessage());
      }
    }
  }

  @isTest
  static void testInjectSignalAttribution() {
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
      Status__c = 'Suspended',
      Correlation_Key__c = 'SignalKey5',
      Input__c = '"InputData"'
    );
    insert inst;

    Test.startTest();
    WorkflowDashboardController.injectSignal(inst.Id, 'PaymentReceived', '{}');
    Test.stopTest();

    Test.getEventBus().deliver();

    List<Workflow_Signal__c> signals = [
      SELECT Id, Payload__c
      FROM Workflow_Signal__c
      WHERE Workflow_Instance__c = :inst.Id
    ];
    System.assertEquals(1, signals.size());
    System.assert(signals[0].Payload__c.contains('"operatorId"'), 'Should contain operatorId');
    System.assert(signals[0].Payload__c.contains(UserInfo.getUserId()), 'Should contain running user id');
  }
```

**Step 2: Run tests to verify they fail**
Run tests:
`sf apex run test -t WorkflowDashboardControllerTest`
Expected: Compilation error (method `injectSignal` does not exist in `WorkflowDashboardController`).

---

### Task 3: Apex Method (Green Phase)

**Files:**
- Modify: `force-app/main/default/classes/WorkflowDashboardController.cls`

**Step 1: Write minimal implementation**
Implement the `injectSignal` method in `WorkflowDashboardController.cls`.

```apex
  @AuraEnabled
  public static void injectSignal(Id instanceId, String signalName, String payloadJson) {
    checkAuthorization();
    
    if (
      !FeatureManagement.checkPermission('Workflow_Signal_Injection') &&
      !currentUserHasModifyAllData()
    ) {
      AuraHandledException ex = new AuraHandledException(
        'Unauthorized: this action requires the "Workflow_Signal_Injection" permission.'
      );
      ex.setMessage(
        'Unauthorized: this action requires the "Workflow_Signal_Injection" permission.'
      );
      throw ex;
    }

    if (String.isBlank(signalName)) {
      throw new AuraHandledException('Signal name is required.');
    }

    List<Workflow_Instance__c> instances = [
      SELECT Status__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
      WITH SYSTEM_MODE
      LIMIT 1
    ];
    if (instances.isEmpty()) {
      throw new AuraHandledException('Workflow instance not found.');
    }
    
    Workflow_Instance__c inst = instances[0];
    if (inst.Status__c != 'Suspended') {
      throw new AuraHandledException('Signal injection is only allowed on Suspended instances.');
    }

    Map<String, Object> payloadMap = new Map<String, Object>();
    if (String.isNotBlank(payloadJson)) {
      try {
        Object parsed = JSON.deserializeUntyped(payloadJson);
        if (parsed instanceof Map<String, Object>) {
          payloadMap = (Map<String, Object>) parsed;
        } else {
          throw new AuraHandledException('Payload JSON must be a JSON object (e.g., {"key": "value"}).');
        }
      } catch (AuraHandledException ex) {
        throw ex;
      } catch (Exception ex) {
        throw new AuraHandledException('Invalid payload JSON: ' + ex.getMessage());
      }
    }

    payloadMap.put('operatorId', UserInfo.getUserId());
    payloadMap.put('operatorUsername', UserInfo.getUserName());
    payloadMap.put('operator', UserInfo.getName());

    try {
      WorkflowEngine.signal(
        String.valueOf(instanceId),
        signalName,
        JSON.serialize(payloadMap)
      );
    } catch (Exception ex) {
      System.debug(
        LoggingLevel.ERROR,
        'Aura injectSignal failed: ' +
          ex.getMessage() +
          '\n' +
          ex.getStackTraceString()
      );
      throw new AuraHandledException(ex.getMessage());
    }
  }
```

**Step 2: Deploy implementation**
`sf project deploy start`

**Step 3: Run tests to verify they pass**
`sf apex run test -t WorkflowDashboardControllerTest -w 5`
Expected: All tests pass.

**Step 4: Commit**
`git add force-app/main/default/classes/WorkflowDashboardController.cls force-app/main/default/classes/WorkflowDashboardControllerTest.cls`
`git commit -m "feat: implement injectSignal apex method and tests"`

---

### Task 4: LWC Linter and Modal Implementation (Red Phase - JS / Jest)

**Files:**
- Modify: `force-app/main/default/lwc/workflowDashboard/workflowDashboard.html`
- Modify: `force-app/main/default/lwc/workflowDashboard/workflowDashboard.js`
- Modify: `force-app/main/default/lwc/workflowDashboard/__tests__/workflowDashboard.test.js`

**Step 1: Write failing Jest tests in workflowDashboard.test.js**
Add tests to verify:
- Clicking the "Send Signal" button opens the Signal Modal.
- The Send Signal button in the modal is disabled when the Signal Name is empty.
- Input changes correctly update JS variables.
- Clicking confirm calls the `injectSignal` apex action with the correct arguments.
- Shows success toast and closes the modal on success, and re-queries details.
- Shows error toast when signal injection fails.

**Step 2: Run Jest tests to verify they fail**
`npm run test:unit`
Expected: Failures because LWC component lacks Send Signal implementation.

---

### Task 5: LWC Implementation (Green Phase)

**Files:**
- Modify: `force-app/main/default/lwc/workflowDashboard/workflowDashboard.html`
- Modify: `force-app/main/default/lwc/workflowDashboard/workflowDashboard.js`

**Step 1: Write implementation**
- Import `injectSignal` apex method.
- Add properties, getters, modal markup, input change handlers, and save/cancel handlers.
- Handle showing success/error toast notifications.

**Step 2: Run Jest tests to verify they pass**
`npm run test:unit`
Expected: Pass.

**Step 3: Deploy LWC changes**
`sf project deploy start`

**Step 4: Commit**
`git add force-app/main/default/lwc/workflowDashboard/`
`git commit -m "feat: add Send Signal button and modal to LWC"`
