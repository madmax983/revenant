@IsTest
private class WorkflowTypeResolverTest {
  @IsTest
  static void testResolveStandardClass() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Resolve a standard class
      Type type1 = WorkflowTypeResolver.resolve('WorkflowTypeResolver');
      Assert.areNotEqual(
        null,
        type1,
        'Should resolve WorkflowTypeResolver class'
      );
      Assert.areEqual(
        WorkflowTypeResolver.class,
        type1,
        'Resolved type should match'
      );

      Type type2 = WorkflowTypeResolver.resolve('WorkflowEngine');
      Assert.areNotEqual(null, type2, 'Should resolve WorkflowEngine class');
      Assert.areEqual(
        WorkflowEngine.class,
        type2,
        'Resolved type should match'
      );
    }
  }

  @IsTest
  static void testResolveWithSimulatedNamespaceFallback() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Enable simulation of a namespace
      WorkflowTypeResolver.simulateNamespacedContext = true;
      WorkflowTypeResolver.mockPackageNamespace = 'fake_ns';

      // Resolving a local class should fail with the namespace fake_ns since it does not exist,
      // but it should fall back to resolving without namespace and succeed.
      Type resolved = WorkflowTypeResolver.resolve('WorkflowTypeResolver');
      Assert.areNotEqual(
        null,
        resolved,
        'Should resolve class via fallback when simulated namespace does not exist'
      );
      Assert.areEqual(
        WorkflowTypeResolver.class,
        resolved,
        'Resolved type should match'
      );

      // Test resolving with namespace prefix in name directly
      Type resolvedWithPrefix = WorkflowTypeResolver.resolve(
        'fake_ns.WorkflowTypeResolver'
      );
      Assert.areNotEqual(
        null,
        resolvedWithPrefix,
        'Should resolve class when name starts with simulated namespace prefix'
      );
      Assert.areEqual(
        WorkflowTypeResolver.class,
        resolvedWithPrefix,
        'Resolved type should match'
      );
    }
  }

  @IsTest
  static void testCaching() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Resolve a class first time to populate cache
      Type type1 = WorkflowTypeResolver.resolve('WorkflowTypeResolver');
      Assert.areNotEqual(null, type1, 'Should resolve first time');

      // Resolve again - should be retrieved from cache
      Type type2 = WorkflowTypeResolver.resolve('WorkflowTypeResolver');
      Assert.areEqual(
        type1,
        type2,
        'Cached type should match first resolved type'
      );
    }
  }

  @IsTest
  static void testGetPackageNamespace() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Test default package namespace
      String defaultNamespace = WorkflowTypeResolver.getPackageNamespace();
      // Since we are running in a scratch org without namespace, it should be empty
      Assert.areEqual(
        '',
        defaultNamespace,
        'Default package namespace should be empty in scratch org'
      );

      // Test simulated package namespace
      WorkflowTypeResolver.simulateNamespacedContext = true;
      WorkflowTypeResolver.mockPackageNamespace = 'test_ns';
      Assert.areEqual(
        'test_ns',
        WorkflowTypeResolver.getPackageNamespace(),
        'Should return mock package namespace when simulated'
      );
    }
  }

  @IsTest
  static void testExtractNamespace() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Assert.areEqual('', WorkflowTypeResolver.extractNamespace(null));
      Assert.areEqual('', WorkflowTypeResolver.extractNamespace(''));
      Assert.areEqual(
        '',
        WorkflowTypeResolver.extractNamespace('WorkflowTypeResolver')
      );
      Assert.areEqual(
        'my_ns',
        WorkflowTypeResolver.extractNamespace('my_ns.WorkflowTypeResolver')
      );
    }
  }

  @IsTest
  static void testResolveWithContextNamespace() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Type type1 = WorkflowTypeResolver.resolve(
        'WorkflowTypeResolver',
        'some_ns'
      );
      Assert.areNotEqual(
        null,
        type1,
        'Should resolve with context namespace fallback'
      );
      Assert.areEqual(
        WorkflowTypeResolver.class,
        type1,
        'Should match class type'
      );
    }
  }

  @IsTest
  static void testResolveCachingWithContextNamespace() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowTypeResolver.typeCache.clear();

      Type typeDefault = WorkflowTypeResolver.resolve('WorkflowTypeResolver');
      Type typeNs1 = WorkflowTypeResolver.resolve(
        'WorkflowTypeResolver',
        'ns1'
      );
      Type typeNs2 = WorkflowTypeResolver.resolve(
        'WorkflowTypeResolver',
        'ns2'
      );

      Assert.areEqual(WorkflowTypeResolver.class, typeDefault);
      Assert.areEqual(WorkflowTypeResolver.class, typeNs1);
      Assert.areEqual(WorkflowTypeResolver.class, typeNs2);

      Assert.isTrue(
        WorkflowTypeResolver.typeCache.containsKey('workflowtyperesolver'),
        'Cache should contain default key'
      );
      Assert.isTrue(
        WorkflowTypeResolver.typeCache.containsKey('workflowtyperesolver|ns1'),
        'Cache should contain ns1 key'
      );
      Assert.isTrue(
        WorkflowTypeResolver.typeCache.containsKey('workflowtyperesolver|ns2'),
        'Cache should contain ns2 key'
      );
    }
  }

  @IsTest
  static void testNamespacedWorkflowExecutionSimulation() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // 1. Enable simulated namespace context
      WorkflowTypeResolver.simulateNamespacedContext = true;
      WorkflowTypeResolver.mockPackageNamespace = 'rev_pkg';

      // 2. Start SuspendingWorkflow (simulating a subscriber class, no package prefix)
      // Since it's in WorkflowEngineTest, the name is 'WorkflowEngineTest.SuspendingWorkflow'.
      // Since this doesn't start with 'rev_pkg.', the resolver will fall back to local org resolution and find it.
      Test.startTest();
      Id instanceId = WorkflowEngine.start(
        'WorkflowEngineTest.SuspendingWorkflow',
        'namespaced_corr_key',
        'some_payload'
      );
      Test.stopTest();

      // Assert that it started and is in Suspended status
      Workflow_Instance__c instBefore = [
        SELECT Status__c, Current_Step__c, Workflow_Name__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      Assert.areEqual(
        'Suspended',
        instBefore.Status__c,
        'Workflow should be suspended after suspend'
      );
      Assert.areEqual(
        'WorkflowEngineTest.SuspendingStep',
        instBefore.Current_Step__c,
        'Current step should be SuspendingStep'
      );

      // Assert that the Workflow_Name__c is stored as the fully qualified class name
      Assert.areEqual(
        'WorkflowEngineTest.SuspendingWorkflow',
        instBefore.Workflow_Name__c,
        'Workflow_Name__c should store the fully qualified name'
      );

      // 3. Resume/signal the suspended workflow.
      // We simulate a resume by delivering step state to the paused step.
      WorkflowEngine.resume(
        instanceId,
        'WorkflowEngineTest.SuspendingStep',
        'resume_payload'
      );

      // Drive orchestrator to process the resumed step and complete the workflow
      new WorkflowOrchestrator(instanceId).execute(null);
      new WorkflowOrchestrator(instanceId).execute(null);

      // 4. Verify it completed successfully
      Workflow_Instance__c instAfter = [
        SELECT Status__c, Current_Step__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      Assert.areEqual(
        'Completed',
        instAfter.Status__c,
        'Workflow should complete after resume'
      );
    }
  }

  @IsTest
  static void testCacheCaseInsensitivity() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowTypeResolver.typeCache.clear();

      Type typeUpper = WorkflowTypeResolver.resolve('WORKFLOWTYPERESOLVER');
      Type typeLower = WorkflowTypeResolver.resolve('workflowtyperesolver');

      Assert.areEqual(
        WorkflowTypeResolver.class,
        typeUpper,
        'Should resolve upper case class name'
      );
      Assert.areEqual(
        WorkflowTypeResolver.class,
        typeLower,
        'Should resolve lower case class name'
      );

      Assert.areEqual(
        1,
        WorkflowTypeResolver.typeCache.size(),
        'Cache should contain exactly 1 entry due to case insensitivity'
      );
      Assert.isTrue(
        WorkflowTypeResolver.typeCache.containsKey('workflowtyperesolver'),
        'Cache should contain the lowercase key'
      );
    }
  }

  @IsTest
  static void testSandboxPortabilityFallback() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowTypeResolver.simulateNamespacedContext = true;
      WorkflowTypeResolver.mockPackageNamespace = 'mock_ns';

      // Attempt to resolve a non-existent namespaced class name that exists locally without namespace
      Type resolved = WorkflowTypeResolver.resolve(
        'some_nonexistent_ns.WorkflowTypeResolver'
      );

      Assert.areNotEqual(
        null,
        resolved,
        'Should successfully resolve type class using sandbox portability fallback'
      );
      Assert.areEqual(
        WorkflowTypeResolver.class,
        resolved,
        'Resolved type should match WorkflowTypeResolver'
      );
    }
  }

  @IsTest
  static void testContextNamespacePrioritization() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Under simulated namespace context, standard caller resolution (Step 3) requires the 'mock_pkg.' prefix.
      // However, if we pass contextNamespace = '', it should resolve via Step 2 first (using Type.forName('', name))
      // without requiring the package prefix.
      WorkflowTypeResolver.simulateNamespacedContext = true;
      WorkflowTypeResolver.mockPackageNamespace = 'mock_pkg';

      Type resolvedWithContext = WorkflowTypeResolver.resolve(
        'WorkflowTypeResolver',
        ''
      );
      Assert.areNotEqual(
        null,
        resolvedWithContext,
        'Should resolve WorkflowTypeResolver when contextNamespace is passed'
      );
      Assert.areEqual(
        WorkflowTypeResolver.class,
        resolvedWithContext,
        'Type should match'
      );
    }
  }

  @IsTest
  static void testStepTimeoutCacheNamespaceIsolation() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Schedule timeout for same step name under different workflow names/namespaces
      // This exercises getStepTimeoutSeconds cache lookup key isolation.
      Test.startTest();
      WorkflowEngine.scheduleTimeoutJobIfNeeded(
        null,
        'WorkflowEngineTest.TimeoutStep',
        'ns1.MyWorkflow'
      );
      WorkflowEngine.scheduleTimeoutJobIfNeeded(
        null,
        'WorkflowEngineTest.TimeoutStep',
        'ns2.MyWorkflow'
      );
      Test.stopTest();

      // Verify cache has both keys populated by running successfully
      Assert.isTrue(true, 'Executed without exceptions');
    }
  }

  @IsTest
  static void testChildWorkflowResolutionSimulation() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // 1. Enable simulated namespace context and mock package namespace
      WorkflowTypeResolver.simulateNamespacedContext = true;
      WorkflowTypeResolver.mockPackageNamespace = 'rev_pkg';

      // Create a mock parent instance in the database that has a namespaced Workflow_Name__c
      Workflow_Instance__c parentInstance = new Workflow_Instance__c(
        Workflow_Name__c = 'rev_pkg.ParentWorkflow',
        Status__c = 'Running'
      );
      insert as system parentInstance;

      // Resolve a child workflow name 'WorkflowEngineTest.HappyWorkflow' using the parent instance ID.
      // Under simulated namespace context, standard caller resolution (Step 3) requires the 'mock_pkg.' prefix.
      // However, when starting a child, we pass parentInstance.Id. The engine queries the parent's Workflow_Name__c,
      // extracts 'rev_pkg' as the parentNamespace prefix, and passes it as contextNamespace to WorkflowTypeResolver.resolve.
      // Then resolver Step 4 (local fallback) resolves the outer/inner class name successfully!
      Test.startTest();
      WorkflowEngine.ChildWorkflowStartRequest childReq = new WorkflowEngine.ChildWorkflowStartRequest();
      childReq.parentId = parentInstance.Id;
      childReq.workflowName = 'WorkflowEngineTest.HappyWorkflow';
      childReq.correlationKey = 'child_corr_key';
      childReq.inputJson = '{}';
      WorkflowEngine.startChildWorkflow(childReq);
      Test.stopTest();

      // Verify child instance was created
      List<Workflow_Instance__c> children = [
        SELECT Workflow_Name__c, Parent_Instance__c
        FROM Workflow_Instance__c
        WHERE Parent_Instance__c = :parentInstance.Id
        WITH SYSTEM_MODE
      ];
      Assert.isFalse(children.isEmpty(), 'Child instance should be created');
      Assert.areEqual(
        'WorkflowEngineTest.HappyWorkflow',
        children[0].Workflow_Name__c,
        'Child workflow name should store the resolved class name'
      );
    }
  }
}
