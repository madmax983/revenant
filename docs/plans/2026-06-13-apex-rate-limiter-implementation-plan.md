# Apex Token Bucket Rate Limiter Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Implement a native, lazy-loaded Apex token bucket rate limiter to cooperatively throttle outbound integration calls across concurrent durable workflow instances.

**Architecture:** A hybrid metadata and custom object model. Admin-defined settings are stored in Custom Metadata (`Rate_Limit_Config__mdt`), while runtime state is stored in a locked custom object (`Rate_Limit_State__c`) using row-level locking (`FOR UPDATE`) to manage concurrency.

**Tech Stack:** Salesforce DX (SFDX) Metadata, Apex (Version 61.0).

---

### Task 1: Rate Limiter Schema Metadata

Create metadata definition XML files for the Custom Object `Rate_Limit_State__c` and the Custom Metadata Type `Rate_Limit_Config__mdt` along with their custom fields.

**Files:**
* Create: `force-app/main/default/objects/Rate_Limit_State__c/Rate_Limit_State__c.object-meta.xml`
* Create: `force-app/main/default/objects/Rate_Limit_State__c/fields/Integration_Key__c.field-meta.xml`
* Create: `force-app/main/default/objects/Rate_Limit_State__c/fields/Tokens_Remaining__c.field-meta.xml`
* Create: `force-app/main/default/objects/Rate_Limit_State__c/fields/Last_Refill_Time_Ms__c.field-meta.xml`
* Create: `force-app/main/default/objects/Rate_Limit_Config__mdt/Rate_Limit_Config__mdt.object-meta.xml`
* Create: `force-app/main/default/objects/Rate_Limit_Config__mdt/fields/Capacity__c.field-meta.xml`
* Create: `force-app/main/default/objects/Rate_Limit_Config__mdt/fields/Refill_Rate_Per_Second__c.field-meta.xml`

**Step 1: Write Custom Object Metadata Content**

1. `force-app/main/default/objects/Rate_Limit_State__c/Rate_Limit_State__c.object-meta.xml`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<CustomObject xmlns="http://soap.sforce.com/2006/04/metadata">
    <actionOverrides>
        <actionName>Accept</actionName>
        <type>Default</type>
    </actionOverrides>
    <actionOverrides>
        <actionName>CancelEdit</actionName>
        <type>Default</type>
    </actionOverrides>
    <actionOverrides>
        <actionName>Clone</actionName>
        <type>Default</type>
    </actionOverrides>
    <actionOverrides>
        <actionName>Delete</actionName>
        <type>Default</type>
    </actionOverrides>
    <actionOverrides>
        <actionName>Edit</actionName>
        <type>Default</type>
    </actionOverrides>
    <actionOverrides>
        <actionName>List</actionName>
        <type>Default</type>
    </actionOverrides>
    <actionOverrides>
        <actionName>New</actionName>
        <type>Default</type>
    </actionOverrides>
    <actionOverrides>
        <actionName>SaveEdit</actionName>
        <type>Default</type>
    </actionOverrides>
    <actionOverrides>
        <actionName>Tab</actionName>
        <type>Default</type>
    </actionOverrides>
    <actionOverrides>
        <actionName>View</actionName>
        <type>Default</type>
    </actionOverrides>
    <allowInChatterGroups>false</allowInChatterGroups>
    <compactLayoutAssignment>SYSTEM</compactLayoutAssignment>
    <deploymentStatus>Deployed</deploymentStatus>
    <description>Stores dynamic state for distributed rate limiting.</description>
    <enableActivities>false</enableActivities>
    <enableBulkApi>true</enableBulkApi>
    <enableFeeds>false</enableFeeds>
    <enableHistory>false</enableHistory>
    <enableLicensing>false</enableLicensing>
    <enableReports>false</enableReports>
    <enableSearch>true</enableSearch>
    <enableSharing>true</enableSharing>
    <enableStreamingApi>true</enableStreamingApi>
    <externalSharingModel>Private</externalSharingModel>
    <label>Rate Limit State</label>
    <nameField>
        <displayFormat>RLS-{0000}</displayFormat>
        <label>Rate Limit State Name</label>
        <type>AutoNumber</type>
    </nameField>
    <pluralLabel>Rate Limit States</pluralLabel>
    <searchLayouts/>
    <sharingModel>ReadWrite</sharingModel>
    <visibility>Public</visibility>
</CustomObject>
```

2. `force-app/main/default/objects/Rate_Limit_State__c/fields/Integration_Key__c.field-meta.xml`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
    <fullName>Integration_Key__c</fullName>
    <caseSensitive>false</caseSensitive>
    <description>Unique key representing the external integration endpoint (e.g. SFMC).</description>
    <externalId>true</externalId>
    <label>Integration Key</label>
    <length>100</length>
    <required>true</required>
    <trackTrending>false</trackTrending>
    <type>Text</type>
    <unique>true</unique>
</CustomField>
```

3. `force-app/main/default/objects/Rate_Limit_State__c/fields/Tokens_Remaining__c.field-meta.xml`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
    <fullName>Tokens_Remaining__c</fullName>
    <description>Remaining fractional tokens available in the bucket.</description>
    <externalId>false</externalId>
    <label>Tokens Remaining</label>
    <precision>18</precision>
    <required>true</required>
    <scale>4</scale>
    <trackTrending>false</trackTrending>
    <type>Number</type>
</CustomField>
```

4. `force-app/main/default/objects/Rate_Limit_State__c/fields/Last_Refill_Time_Ms__c.field-meta.xml`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
    <fullName>Last_Refill_Time_Ms__c</fullName>
    <description>Unix epoch timestamp in milliseconds when the bucket was last refilled/accessed.</description>
    <externalId>false</externalId>
    <label>Last Refill Time Ms</label>
    <precision>18</precision>
    <required>true</required>
    <scale>0</scale>
    <trackTrending>false</trackTrending>
    <type>Number</type>
</CustomField>
```

5. `force-app/main/default/objects/Rate_Limit_Config__mdt/Rate_Limit_Config__mdt.object-meta.xml`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<CustomMetadata xmlns="http://soap.sforce.com/2006/04/metadata">
    <description>Static configurations for external integration rate limits.</description>
    <label>Rate Limit Config</label>
    <pluralLabel>Rate Limit Configs</pluralLabel>
    <visibility>Public</visibility>
</CustomMetadata>
```

6. `force-app/main/default/objects/Rate_Limit_Config__mdt/fields/Capacity__c.field-meta.xml`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
    <fullName>Capacity__c</fullName>
    <description>Maximum token capacity (burst size) for this rate limiter.</description>
    <externalId>false</externalId>
    <fieldManageability>DeveloperControlled</fieldManageability>
    <label>Capacity</label>
    <precision>18</precision>
    <required>true</required>
    <scale>0</scale>
    <type>Number</type>
</CustomField>
```

7. `force-app/main/default/objects/Rate_Limit_Config__mdt/fields/Refill_Rate_Per_Second__c.field-meta.xml`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
    <fullName>Refill_Rate_Per_Second__c</fullName>
    <description>Number of tokens refilled back into the bucket per second.</description>
    <externalId>false</externalId>
    <fieldManageability>DeveloperControlled</fieldManageability>
    <label>Refill Rate Per Second</label>
    <precision>18</precision>
    <required>true</required>
    <scale>4</scale>
    <type>Number</type>
</CustomField>
```

**Step 2: Deploy and verify schema compilation**
Run: `sf project deploy start`
Expected: Successful deployment of metadata schemas to the scratch org.

**Step 3: Commit Metadata**
```bash
git add force-app/main/default/objects/Rate_Limit_State__c force-app/main/default/objects/Rate_Limit_Config__mdt
git commit -m "feat: create RateLimit config metadata and state object schemas"
```

---

### Task 2: Implement RateLimiter Class

Create the Apex class executing token consumption logic, DML updates, and sleep calculation.

**Files:**
* Create: `force-app/main/default/classes/RateLimiter.cls`
* Create: `force-app/main/default/classes/RateLimiter.cls-meta.xml`

**Step 1: Write RateLimiter.cls Content**
```java
public hardships-free with sharing class RateLimiter {
    
    // Allows unit tests to inject custom configs without database DML dependencies
    @TestVisible
    private static Map<String, Rate_Limit_Config__mdt> mockConfigs = new Map<String, Rate_Limit_Config__mdt>();

    public class AcquireResult {
        public Boolean isAllowed { get; private set; }
        public Integer sleepDurationSeconds { get; private set; }
        
        public AcquireResult(Boolean isAllowed, Integer sleepDurationSeconds) {
            this.isAllowed = isAllowed;
            this.sleepDurationSeconds = sleepDurationSeconds;
        }
    }
    
    /**
     * Cooperatively checks and consumes a token for the specified integration key.
     * Locks the state record using SELECT ... FOR UPDATE to avoid concurrency issues.
     */
    public static AcquireResult acquire(String integrationKey) {
        // 1. Resolve Config
        Rate_Limit_Config__mdt config;
        if (mockConfigs.containsKey(integrationKey)) {
            config = mockConfigs.get(integrationKey);
        } else {
            List<Rate_Limit_Config__mdt> configs = [
                SELECT Capacity__c, Refill_Rate_Per_Second__c 
                FROM Rate_Limit_Config__mdt 
                WHERE DeveloperName = :integrationKey
            ];
            if (configs.isEmpty()) {
                throw new WorkflowEngine.WorkflowException('No rate limit configuration found for: ' + integrationKey);
            }
            config = configs[0];
        }
        
        // 2. Query and Lock State Record
        List<Rate_Limit_State__c> states = [
            SELECT Tokens_Remaining__c, Last_Refill_Time_Ms__c 
            FROM Rate_Limit_State__c 
            WHERE Integration_Key__c = :integrationKey
            FOR UPDATE
        ];
        
        Rate_Limit_State__c state;
        Long now = System.currentTimeMillis();
        
        if (states.isEmpty()) {
            // Lazy-provisioning
            state = new Rate_Limit_State__c(
                Integration_Key__c = integrationKey,
                Tokens_Remaining__c = config.Capacity__c,
                Last_Refill_Time_Ms__c = now
            );
            insert state;
        } else {
            state = states[0];
        }
        
        // 3. Compute Refill based on elapsed time
        Decimal elapsed = (Decimal)(now - state.Last_Refill_Time_Ms__c) / 1000.0;
        Decimal calculatedTokens = state.Tokens_Remaining__c + (elapsed * config.Refill_Rate_Per_Second__c);
        Decimal currentTokens = Math.min(config.Capacity__c, calculatedTokens);
        
        // 4. Try Consumption
        if (currentTokens >= 1.0) {
            state.Tokens_Remaining__c = currentTokens - 1.0;
            state.Last_Refill_Time_Ms__c = now;
            update state;
            return new AcquireResult(true, 0);
        } else {
            // Calculate delay until next token is available
            Decimal waitTime = (1.0 - currentTokens) / config.Refill_Rate_Per_Second__c;
            Double jitter = 0.5 + (Math.random() * 1.0); // 0.5 to 1.5 seconds jitter
            Integer sleepSecs = (Integer)Math.ceil(waitTime + jitter);
            return new AcquireResult(false, sleepSecs);
        }
    }
}
```

Write `force-app/main/default/classes/RateLimiter.cls-meta.xml`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<ApexClass xmlns="http://soap.sforce.com/2006/04/metadata">
    <apiVersion>61.0</apiVersion>
    <status>Active</status>
</ApexClass>
```

**Step 2: Deploy files**
Run: `sf project deploy start -m ApexClass:RateLimiter`
Expected: Successful compilation and deployment.

**Step 3: Commit**
```bash
git add force-app/main/default/classes/RateLimiter.cls force-app/main/default/classes/RateLimiter.cls-meta.xml
git commit -m "feat: implement RateLimiter logic and auto-provisioning"
```

---

### Task 3: Implement Unit Tests

Create test cases to verify the rate limiter behavior.

**Files:**
* Create: `force-app/main/default/classes/RateLimiterTest.cls`
* Create: `force-app/main/default/classes/RateLimiterTest.cls-meta.xml`

**Step 1: Write RateLimiterTest.cls Content**
```java
@isTest
public class RateLimiterTest {

    @isTest
    static void testRateLimiterAcquisitionAndRefill() {
        // Setup config mock via JSON deserialization
        String mockConfigJson = '{"DeveloperName":"TestService","Capacity__c":5,"Refill_Rate_Per_Second__c":2.0}';
        Rate_Limit_Config__mdt mockConfig = (Rate_Limit_Config__mdt)JSON.deserialize(mockConfigJson, Rate_Limit_Config__mdt.class);
        RateLimiter.mockConfigs.put('TestService', mockConfig);

        Test.startTest();
        
        // 1. Initial acquisition should auto-provision and succeed
        RateLimiter.AcquireResult res1 = RateLimiter.acquire('TestService');
        System.assert(res1.isAllowed);
        System.assertEquals(0, res1.sleepDurationSeconds);

        // Verify state record is created
        Rate_Limit_State__c state = [SELECT Tokens_Remaining__c, Last_Refill_Time_Ms__c FROM Rate_Limit_State__c WHERE Integration_Key__c = 'TestService'];
        System.assertEquals(4.0, state.Tokens_Remaining__c); // 5.0 - 1.0

        // Consume remaining tokens
        RateLimiter.acquire('TestService'); // Remaining: 3
        RateLimiter.acquire('TestService'); // Remaining: 2
        RateLimiter.acquire('TestService'); // Remaining: 1
        RateLimiter.acquire('TestService'); // Remaining: 0
        
        // 2. Next acquisition should fail and return sleep duration
        RateLimiter.AcquireResult resDenied = RateLimiter.acquire('TestService');
        System.assert(!resDenied.isAllowed);
        System.assert(resDenied.sleepDurationSeconds >= 1, 'Should require at least 1 second cooldown');

        // 3. Mock time elapsed by updating state record's last modified timestamp backward
        state = [SELECT Tokens_Remaining__c, Last_Refill_Time_Ms__c FROM Rate_Limit_State__c WHERE Integration_Key__c = 'TestService'];
        state.Last_Refill_Time_Ms__c = state.Last_Refill_Time_Ms__c - 2000; // 2 seconds ago
        update state;

        // 4. Acquisition should now succeed because 2 seconds * 2.0/sec = 4.0 tokens refilled
        RateLimiter.AcquireResult resRefilled = RateLimiter.acquire('TestService');
        System.assert(resRefilled.isAllowed);
        System.assertEquals(0, resRefilled.sleepDurationSeconds);

        Test.stopTest();
    }
}
```

Write `force-app/main/default/classes/RateLimiterTest.cls-meta.xml`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<ApexClass xmlns="http://soap.sforce.com/2006/04/metadata">
    <apiVersion>61.0</apiVersion>
    <status>Active</status>
</ApexClass>
```

**Step 2: Deploy tests**
Run: `sf project deploy start -m ApexClass:RateLimiterTest`
Expected: Successful deployment.

**Step 3: Run Tests**
Run: `sf apex run test -n RateLimiterTest -w 10`
Expected: 100% pass rate.

**Step 4: Commit**
```bash
git add force-app/main/default/classes/RateLimiterTest.cls force-app/main/default/classes/RateLimiterTest.cls-meta.xml
git commit -m "test: add unit tests for RateLimiter token bucket logic"
```
