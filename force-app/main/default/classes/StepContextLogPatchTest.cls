/**
 * StepContext unit tests for the structured logging API and the version-patch
 * (schema evolution) resolution paths. Split out of StepContextTest to keep each
 * @IsTest class within the analyzer's size and complexity limits.
 */
@IsTest
public class StepContextLogPatchTest {
  static void testLogApiBuffering() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id dummyInstanceId = TestIdFactory.generate(Organization.SObjectType);
      StepContext ctx = new StepContext(
        dummyInstanceId,
        'TestWorkflow',
        'TestStep',
        null,
        null,
        null,
        null
      );

      ctx.log(StepContext.Level.INFO, 'Info message');
      Map<String, Object> context = new Map<String, Object>{
        'foo' => 'bar',
        'count' => 42
      };
      ctx.log(StepContext.Level.WARN, 'Warning message', context);
      ctx.log(StepContext.Level.ERROR, 'Error message');

      List<StepContext.Breadcrumb> crumbs = ctx.getBreadcrumbs();
      System.assertEquals(
        3,
        crumbs.size(),
        'Should store exactly 3 breadcrumbs'
      );

      System.assertEquals(StepContext.Level.INFO, crumbs[0].level);
      System.assertEquals('Info message', crumbs[0].message);
      System.assertNotEquals(null, crumbs[0].timestamp);

      System.assertEquals(StepContext.Level.WARN, crumbs[1].level);
      // context map serialized to JSON
      System.assert(
        crumbs[1].message.startsWith('Warning message | Context: '),
        'Should append context json'
      );
      System.assert(
        crumbs[1].message.contains('"foo":"bar"'),
        'Serialized JSON should contain foo'
      );
      System.assert(
        crumbs[1].message.contains('"count":42'),
        'Serialized JSON should contain count'
      );
      System.assertNotEquals(null, crumbs[1].timestamp);

      System.assertEquals(StepContext.Level.ERROR, crumbs[2].level);
      System.assertEquals('Error message', crumbs[2].message);
      System.assertNotEquals(null, crumbs[2].timestamp);
    }
  }

  @IsTest
  static void testLogCharacterTruncation() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id dummyInstanceId = TestIdFactory.generate(Organization.SObjectType);
      StepContext ctx = new StepContext(
        dummyInstanceId,
        'TestWorkflow',
        'TestStep',
        null,
        null,
        null,
        null
      );

      String message4000 = 'a'.repeat(4000);
      ctx.log(StepContext.Level.INFO, message4000);
      List<StepContext.Breadcrumb> crumbs = ctx.getBreadcrumbs();
      System.assertEquals(1, crumbs.size());
      System.assertEquals(
        4000,
        crumbs[0].message.length(),
        'Exact 4000 char message should not be truncated'
      );
      System.assertEquals(message4000, crumbs[0].message);

      ctx = new StepContext(dummyInstanceId, 'W', 'S', null, null, null, null);
      String message4001 = 'b'.repeat(4001);
      ctx.log(StepContext.Level.INFO, message4001);
      crumbs = ctx.getBreadcrumbs();
      System.assertEquals(1, crumbs.size());
      System.assertEquals(
        4000,
        crumbs[0].message.length(),
        'Should be truncated to 4000 characters total'
      );
      System.assertEquals(
        'b'.repeat(3985) + '... [TRUNCATED]',
        crumbs[0].message
      );

      // Test with context
      ctx = new StepContext(dummyInstanceId, 'W', 'S', null, null, null, null);
      Map<String, Object> context = new Map<String, Object>{ 'k' => 'v' };
      // base message + ' | Context: {"k":"v"}' has length: 3980 + 21 = 4001
      String msg3980 = 'c'.repeat(3980);
      ctx.log(StepContext.Level.INFO, msg3980, context);
      crumbs = ctx.getBreadcrumbs();
      System.assertEquals(1, crumbs.size());
      String expectedBase = msg3980 + ' | Context: {"k":"v"}';
      System.assertEquals(
        expectedBase.substring(0, 3985) + '... [TRUNCATED]',
        crumbs[0].message
      );
    }
  }

  @IsTest
  static void testLogEntriesTruncation() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id dummyInstanceId = TestIdFactory.generate(Organization.SObjectType);
      StepContext ctx = new StepContext(
        dummyInstanceId,
        'TestWorkflow',
        'TestStep',
        null,
        null,
        null,
        null
      );

      for (Integer i = 0; i < 100; i++) {
        ctx.log(StepContext.Level.INFO, 'Entry ' + i);
      }
      List<StepContext.Breadcrumb> crumbs = ctx.getBreadcrumbs();
      System.assertEquals(
        100,
        crumbs.size(),
        'Should allow exactly 100 entries'
      );

      // 101st log triggers single warning and discards the log
      ctx.log(StepContext.Level.INFO, 'Entry 100');
      crumbs = ctx.getBreadcrumbs();
      System.assertEquals(
        101,
        crumbs.size(),
        'Should have appended a warning and discarded entry 100'
      );
      System.assertEquals(StepContext.Level.WARN, crumbs[100].level);
      System.assertEquals(
        '[TRUNCATED] Log limit of 100 entries reached. Subsequent step logs are discarded.',
        crumbs[100].message
      );

      // 102nd log is discarded, count remains 101, no second warning
      ctx.log(StepContext.Level.INFO, 'Entry 101');
      crumbs = ctx.getBreadcrumbs();
      System.assertEquals(
        101,
        crumbs.size(),
        'Should not append more logs or warnings'
      );
    }
  }

  @IsTest
  static void testLogNullOrEmptyMessage() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id dummyInstanceId = TestIdFactory.generate(Organization.SObjectType);
      StepContext ctx = new StepContext(
        dummyInstanceId,
        'TestWorkflow',
        'TestStep',
        null,
        null,
        null,
        null
      );

      ctx.log(StepContext.Level.INFO, null);
      ctx.log(StepContext.Level.WARN, '');
      ctx.log(
        StepContext.Level.ERROR,
        null,
        new Map<String, Object>{ 'x' => 1 }
      );

      List<StepContext.Breadcrumb> crumbs = ctx.getBreadcrumbs();
      System.assertEquals(3, crumbs.size());

      System.assertEquals(null, crumbs[0].message);
      System.assertEquals('', crumbs[1].message);
      System.assertEquals('null | Context: {"x":1}', crumbs[2].message);
    }
  }

  @IsTest
  static void testLogContextSerializationSafety() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id dummyInstanceId = TestIdFactory.generate(Organization.SObjectType);
      StepContext ctx = new StepContext(
        dummyInstanceId,
        'W',
        'S',
        null,
        null,
        null,
        null
      );

      // Test circular reference catch
      Map<String, Object> circularMap = new Map<String, Object>();
      circularMap.put('self', circularMap);
      ctx.log(StepContext.Level.INFO, 'circular', circularMap);

      List<StepContext.Breadcrumb> crumbs = ctx.getBreadcrumbs();
      System.assertEquals(1, crumbs.size());
      System.assert(
        crumbs[0].message.contains('[TRUNCATED] JSON serialization failed'),
        'Error mismatch: ' + crumbs[0].message
      );

      // Test oversized value pre-check
      ctx = new StepContext(dummyInstanceId, 'W', 'S', null, null, null, null);
      Map<String, Object> oversizedMap = new Map<String, Object>{
        'payload' => 'x'.repeat(4001)
      };
      ctx.log(StepContext.Level.INFO, 'oversized', oversizedMap);
      crumbs = ctx.getBreadcrumbs();
      System.assertEquals(1, crumbs.size());
      System.assert(
        crumbs[0]
          .message.contains(
            '[TRUNCATED] JSON serialization bypassed due to oversized string value'
          ),
        'Message mismatch: ' + crumbs[0].message
      );
    }
  }

  @IsTest
  static void testNullLogLevelDefaulting() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id dummyInstanceId = TestIdFactory.generate(Organization.SObjectType);
      StepContext ctx = new StepContext(
        dummyInstanceId,
        'W',
        'S',
        null,
        null,
        null,
        null
      );
      ctx.log(null, 'null level message');
      List<StepContext.Breadcrumb> crumbs = ctx.getBreadcrumbs();
      System.assertEquals(1, crumbs.size());
      System.assertEquals(
        StepContext.Level.INFO,
        crumbs[0].level,
        'Should default null level to INFO'
      );
    }
  }

  @IsTest
  static void testPatchedBrandNewInstance() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id dummyInstanceId = TestIdFactory.generate(Organization.SObjectType);
      StepContext ctx = new StepContext(
        dummyInstanceId,
        'TestWorkflow',
        'TestStep',
        null,
        null,
        null,
        null
      );

      // First time decision is reached in a brand new instance
      Boolean isPatched = ctx.patched('change-1');
      System.assertEquals(
        true,
        isPatched,
        'New patch should default to true on first execution'
      );
      System.assertEquals(
        true,
        ctx.hasNewCaptures(),
        'Decision should be newly captured'
      );

      String capturedJson = ctx.getCapturedValuesJson();
      System.assertNotEquals(null, capturedJson);
      System.assert(
        capturedJson.contains('"__patch:change-1":true'),
        'Decision should be recorded in captures'
      );
    }
  }

  @IsTest
  static void testPatchedReplay() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id dummyInstanceId = TestIdFactory.generate(Organization.SObjectType);
      StepContext ctx = StepContext.withCapturedValues(
        dummyInstanceId,
        'TestWorkflow',
        'TestStep',
        null,
        null,
        null,
        null,
        1,
        1,
        null,
        null,
        '{"__patch:change-1":true}'
      );

      // Decision is replayed
      Boolean isPatched = ctx.patched('change-1');
      System.assertEquals(
        true,
        isPatched,
        'Replayed patch should match recorded value'
      );
      System.assertEquals(
        false,
        ctx.hasNewCaptures(),
        'Replayed decision should not be marked as new capture'
      );
    }
  }

  @IsTest
  static void testPatchedReplayOffloaded() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'TestWorkflow',
        Status__c = 'Running',
        Correlation_Key__c = 'PatchKeyOffloaded',
        Current_Step__c = 'TestStep'
      );
      insert inst;

      // Save the patch decision JSON to ContentVersion
      String capturesJson = '{"__patch:change-offloaded":true}';
      String marker = WorkflowEngine.savePayloadIfNeeded(
        inst.Id,
        capturesJson,
        'CapturedValues'
      );

      // Insert a completed step execution with the offloaded marker
      insert new Workflow_Step_Execution__c(
        Workflow_Instance__c = inst.Id,
        Step_Name__c = 'PredecessorStep',
        Status__c = 'Completed',
        Captured_Values__c = marker
      );

      StepContext ctx = new StepContext(
        inst.Id,
        'TestWorkflow',
        'TestStep',
        null,
        null,
        null,
        null
      );

      // The offloaded patch decision should be resolved and read successfully as true
      Boolean isPatched = ctx.patched('change-offloaded');
      System.assertEquals(
        true,
        isPatched,
        'Should resolve and read offloaded patch decision'
      );
    }
  }

  @IsTest
  static void testPatchedReExecutionCompletedInPast() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Insert a workflow instance and step execution that completed in the past
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'TestWorkflow',
        Status__c = 'Running',
        Correlation_Key__c = 'PatchKey1',
        Current_Step__c = 'TestStep'
      );
      insert inst;

      // Insert a completed step execution for TestStep with no patch decision
      insert new Workflow_Step_Execution__c(
        Workflow_Instance__c = inst.Id,
        Step_Name__c = 'TestStep',
        Status__c = 'Completed'
      );

      StepContext ctx = new StepContext(
        inst.Id,
        'TestWorkflow',
        'TestStep',
        null,
        null,
        null,
        null
      );

      // The step has already completed in the past, so the patch decision should be false (not flipped retroactively)
      Boolean isPatched = ctx.patched('change-1');
      System.assertEquals(
        false,
        isPatched,
        'Should return false when step already completed in past without patch'
      );
      System.assertEquals(
        true,
        ctx.hasNewCaptures(),
        'Should capture decision as false'
      );

      String capturedJson = ctx.getCapturedValuesJson();
      System.assert(
        capturedJson.contains('"__patch:change-1":false'),
        'Recorded decision should be false'
      );
    }
  }

  @IsTest
  static void testPatchedDownstreamFirstExecutionLegacy() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      StepContext.mockInstanceCreatedDate = DateTime.newInstance(2026, 1, 1);
      StepContext.mockClassLastModified = DateTime.newInstance(2026, 1, 2);
      try {
        // 1. Insert a workflow instance and a completed predecessor step
        Workflow_Instance__c inst = new Workflow_Instance__c(
          Workflow_Name__c = 'TestWorkflow',
          Status__c = 'Running',
          Correlation_Key__c = 'PatchKey2',
          Current_Step__c = 'DownstreamStep'
        );
        insert inst;

        // Completed predecessor step has no patch decision recorded
        insert new Workflow_Step_Execution__c(
          Workflow_Instance__c = inst.Id,
          Step_Name__c = 'PredecessorStep',
          Status__c = 'Completed',
          Captured_Values__c = '{"someValue":true}'
        );

        StepContext ctx = new StepContext(
          inst.Id,
          'TestWorkflow',
          'DownstreamStep',
          null,
          null,
          null,
          null
        );

        // DownstreamStep is running for the first time. Since instanceCreatedDate < classLastModified,
        // it must default to false (legacy).
        Boolean isPatched = ctx.patched('change-1');
        System.assertEquals(
          false,
          isPatched,
          'Downstream step running for first time on legacy instance must default to false'
        );
      } finally {
        StepContext.mockInstanceCreatedDate = null;
        StepContext.mockClassLastModified = null;
      }
    }
  }

  @IsTest
  static void testPatchedDownstreamFirstExecutionNewInstance() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      StepContext.mockInstanceCreatedDate = DateTime.newInstance(2026, 1, 3);
      StepContext.mockClassLastModified = DateTime.newInstance(2026, 1, 2);
      try {
        Workflow_Instance__c inst = new Workflow_Instance__c(
          Workflow_Name__c = 'TestWorkflow',
          Status__c = 'Running',
          Correlation_Key__c = 'PatchKey3',
          Current_Step__c = 'DownstreamStep'
        );
        insert inst;

        insert new Workflow_Step_Execution__c(
          Workflow_Instance__c = inst.Id,
          Step_Name__c = 'PredecessorStep',
          Status__c = 'Completed',
          Captured_Values__c = '{"someValue":true}'
        );

        StepContext ctx = new StepContext(
          inst.Id,
          'TestWorkflow',
          'DownstreamStep',
          null,
          null,
          null,
          null
        );

        // Since instanceCreatedDate >= classLastModified, it is a brand-new instance, so it must default to true!
        Boolean isPatched = ctx.patched('change-1');
        System.assertEquals(
          true,
          isPatched,
          'Downstream step running for first time on brand-new instance must default to true'
        );
      } finally {
        StepContext.mockInstanceCreatedDate = null;
        StepContext.mockClassLastModified = null;
      }
    }
  }

  @IsTest
  static void testPatchedWithIntroducedAtDate() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Class was last modified on Day 3 (e.g. 2026-01-03) due to unrelated changes
      StepContext.mockClassLastModified = DateTime.newInstance(2026, 1, 3);

      // Patch was introduced on Day 2 (e.g. 2026-01-02)
      DateTime introducedAt = DateTime.newInstance(2026, 1, 2);

      try {
        // Instance A was created on Day 1 (2026-01-01), before patch was introduced
        StepContext.mockInstanceCreatedDate = DateTime.newInstance(2026, 1, 1);
        Workflow_Instance__c instA = new Workflow_Instance__c(
          Workflow_Name__c = 'TestWorkflow',
          Status__c = 'Running',
          Correlation_Key__c = 'DateKey1'
        );
        insert instA;

        StepContext ctxA = new StepContext(
          instA.Id,
          'TestWorkflow',
          'StepA',
          null,
          null,
          null,
          null
        );

        // Since instanceCreatedDate < introducedAt, it must default to false (legacy)!
        System.assertEquals(false, ctxA.patched('change-date', introducedAt));

        // Instance B was created on Day 2.5 (2026-01-02 12:00:00), after patch was introduced but before Day 3 redeploy
        StepContext.mockInstanceCreatedDate = DateTime.newInstance(
          2026,
          1,
          2,
          12,
          0,
          0
        );
        Workflow_Instance__c instB = new Workflow_Instance__c(
          Workflow_Name__c = 'TestWorkflow',
          Status__c = 'Running',
          Correlation_Key__c = 'DateKey2'
        );
        insert instB;

        StepContext ctxB = new StepContext(
          instB.Id,
          'TestWorkflow',
          'StepA',
          null,
          null,
          null,
          null
        );

        // Since instanceCreatedDate >= introducedAt, it must default to true, even though instanceCreatedDate < classLastModified!
        System.assertEquals(true, ctxB.patched('change-date', introducedAt));
      } finally {
        StepContext.mockInstanceCreatedDate = null;
        StepContext.mockClassLastModified = null;
      }
    }
  }

  @IsTest
  static void testDeprecatedPatch() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id dummyInstanceId = TestIdFactory.generate(Organization.SObjectType);

      // Case 1: Patched is true, deprecated should pass silently
      StepContext ctxTrue = StepContext.withCapturedValues(
        dummyInstanceId,
        'TestWorkflow',
        'TestStep',
        null,
        null,
        null,
        null,
        1,
        1,
        null,
        null,
        '{"__patch:change-1":true}'
      );
      try {
        ctxTrue.deprecated('change-1');
        // Pass
      } catch (Exception e) {
        System.assert(false, 'Should not throw exception when patch is active');
      }

      // Case 2: Patched is false, deprecated should throw WorkflowException
      StepContext ctxFalse = StepContext.withCapturedValues(
        dummyInstanceId,
        'TestWorkflow',
        'TestStep',
        null,
        null,
        null,
        null,
        1,
        1,
        null,
        null,
        '{"__patch:change-1":false}'
      );
      try {
        ctxFalse.deprecated('change-1');
        System.assert(
          false,
          'Should throw exception when patch is deprecated and inactive'
        );
      } catch (WorkflowEngine.WorkflowException e) {
        System.assert(
          e.getMessage().contains('retired code path for patch: change-1')
        );
      } catch (Exception e) {
        System.assert(
          false,
          'Should throw WorkflowException, got: ' + e.getTypeName()
        );
      }
    }
  }

  @IsTest
  static void testCallingClassNameResolution() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'TestWorkflow',
        Status__c = 'Running',
        Correlation_Key__c = 'CallingClassKey'
      );
      insert inst;

      StepContext ctx = new StepContext(
        inst.Id,
        'TestWorkflow',
        'TestStep',
        null,
        null,
        null,
        null
      );

      // Call patched. It will call loadExecutions(getCallingClassName())
      // which resolves the calling class to 'StepContextTest'.
      // Since 'StepContextTest' is a real class in the org, it will query its LastModifiedDate.
      ctx.patched('calling-class-change');

      System.assertNotEquals(null, ctx.getCapturedValuesJson());
    }
  }
}
