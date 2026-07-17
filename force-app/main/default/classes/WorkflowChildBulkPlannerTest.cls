/**
 * @description Unit tests for {@link WorkflowChildBulkPlanner}, driving its public
 * surface (validateChildRequests / findExistingChildren / buildChildInstance /
 * insertChildInstances) directly to cover the request-validation throws, the
 * existing-child indexing, the version-selection arms and the DUPLICATE_VALUE
 * reconciliation backstop. Fixtures are built with plain DML mirroring the engine
 * test suite; the reconciliation branches are reached by pre-seeding the unique
 * Active_Correlation_Key__c index and letting a bulk insert collide.
 */
@IsTest
public class WorkflowChildBulkPlannerTest {
  private static final String PLANNER_WF = 'WorkflowChildBulkPlannerTest.PlannerWorkflow';
  private static final String VERSIONED_WF = 'WorkflowChildBulkPlannerTest.PlannerVersionedWorkflow';

  /**
   * @description Fixture workflow definition used to resolve a valid child type.
   */
  public class PlannerWorkflow implements WorkflowDefinition {
    /**
     * @description Declares the single fixture step.
     * @return The one-element list of step names.
     */
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowChildBulkPlannerTest.PlannerStep' };
    }
    /**
     * @description Names the entry step.
     * @return The initial step name.
     */
    public String getInitialStep() {
      return 'WorkflowChildBulkPlannerTest.PlannerStep';
    }
    /**
     * @description Terminates after the single step.
     * @param currentStepName The step that just completed.
     * @param stepResult The result of the completed step.
     * @return Always null, marking the workflow complete.
     */
    public String getNextStep(String currentStepName, StepResult stepResult) {
      return null;
    }
  }

  /**
   * @description Fixture versioned workflow used to exercise the latest-version arm
   * of buildChildInstance.
   */
  public class PlannerVersionedWorkflow implements VersionedWorkflow {
    /**
     * @description Declares the single fixture step.
     * @return The one-element list of step names.
     */
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowChildBulkPlannerTest.PlannerStep' };
    }
    /**
     * @description Names the entry step.
     * @return The initial step name.
     */
    public String getInitialStep() {
      return 'WorkflowChildBulkPlannerTest.PlannerStep';
    }
    /**
     * @description Reports the latest defined version.
     * @return The latest version number.
     */
    public Integer getLatestVersion() {
      return 3;
    }
    /**
     * @description Version-unaware routing that delegates to version 1.
     * @param currentStepName The step that just completed.
     * @param stepResult The result of the completed step.
     * @return The next step name, or null when complete.
     */
    public String getNextStep(String currentStepName, StepResult stepResult) {
      return getNextStep(currentStepName, stepResult, 1);
    }
    /**
     * @description Version-aware routing to the next step.
     * @param currentStepName The step that just completed.
     * @param stepResult The result of the completed step.
     * @param version The workflow version to evaluate.
     * @return The next step name, or null when complete.
     */
    public String getNextStep(
      String currentStepName,
      StepResult stepResult,
      Integer version
    ) {
      return null;
    }
  }

  /**
   * @description A resolvable Apex type that does NOT implement WorkflowDefinition,
   * used to drive the "must implement WorkflowDefinition" validation throw.
   */
  public class NotAWorkflowDefinition {
    /** @description Marker so the fixture carries an instance member. */
    public Boolean marker = true;
  }

  // Inserts a Workflow_Instance__c with the given key/status/parent, letting the
  // instance trigger derive Active_Correlation_Key__c for active statuses.
  private static Workflow_Instance__c newInstance(
    String key,
    String status,
    Id parentId
  ) {
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = PLANNER_WF,
      Correlation_Key__c = key,
      Status__c = status,
      Parent_Instance__c = parentId
    );
    insert inst;
    return inst;
  }

  private static StepResult.ChildRequest childReq(String name, String key) {
    return new StepResult.ChildRequest(name, key, null);
  }

  @IsTest
  static void testValidateChildRequestsHappyReturnsKeys() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Set<String> keys = WorkflowChildBulkPlanner.validateChildRequests(
        new List<StepResult.ChildRequest>{
          childReq(PLANNER_WF, 'okkey-1'),
          childReq(VERSIONED_WF, 'okkey-2')
        },
        ''
      );
      System.assertEquals(2, keys.size(), 'Both correlation keys collected');
      System.assert(keys.contains('okkey-1'), 'First key collected');
      System.assert(keys.contains('okkey-2'), 'Second key collected');
    }
  }

  @IsTest
  static void testValidateChildRequestsBlankWorkflowNameThrows() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // ChildRequest's constructor rejects a blank name, so null it after build.
      StepResult.ChildRequest req = childReq(PLANNER_WF, 'blank-name-key');
      req.workflowName = '';

      Boolean threw = false;
      try {
        WorkflowChildBulkPlanner.validateChildRequests(
          new List<StepResult.ChildRequest>{ req },
          ''
        );
      } catch (WorkflowEngine.WorkflowException ex) {
        threw = true;
        System.assert(
          ex.getMessage().contains('Workflow name is required'),
          'Blank workflow name must be rejected: ' + ex.getMessage()
        );
      }
      System.assert(threw, 'A blank workflow name must throw');
    }
  }

  @IsTest
  static void testValidateChildRequestsUnresolvableThrows() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Boolean threw = false;
      try {
        WorkflowChildBulkPlanner.validateChildRequests(
          new List<StepResult.ChildRequest>{
            childReq('WorkflowChildBulkPlannerTest.NoSuchWorkflow', 'nrk')
          },
          ''
        );
      } catch (WorkflowEngine.WorkflowException ex) {
        threw = true;
        System.assert(
          ex.getMessage().contains('Workflow definition not found'),
          'An unresolvable name must throw: ' + ex.getMessage()
        );
      }
      System.assert(threw, 'An unresolvable workflow name must throw');
    }
  }

  @IsTest
  static void testValidateChildRequestsNotWorkflowDefinitionThrows() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Boolean threw = false;
      try {
        WorkflowChildBulkPlanner.validateChildRequests(
          new List<StepResult.ChildRequest>{
            childReq(
              'WorkflowChildBulkPlannerTest.NotAWorkflowDefinition',
              'ndk'
            )
          },
          ''
        );
      } catch (WorkflowEngine.WorkflowException ex) {
        threw = true;
        System.assert(
          ex.getMessage().contains('must implement WorkflowDefinition'),
          'A non-WorkflowDefinition class must throw: ' + ex.getMessage()
        );
      }
      System.assert(threw, 'A non-WorkflowDefinition class must throw');
    }
  }

  @IsTest
  static void testFindExistingChildrenEmptyKeysReturnsEmpty() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c parent = newInstance(
        'planner-parent-e',
        'Running',
        null
      );

      Map<String, Workflow_Instance__c> found = WorkflowChildBulkPlanner.findExistingChildren(
        parent.Id,
        new Set<String>()
      );
      System.assert(
        found.isEmpty(),
        'Empty key set short-circuits to empty map'
      );
    }
  }

  @IsTest
  static void testFindExistingChildrenIndexesActiveAndTerminalSiblings() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c parent = newInstance(
        'planner-parent-a',
        'Running',
        null
      );
      // Active child: reserves Active_Correlation_Key__c under this parent.
      newInstance('activek', 'Running', parent.Id);
      // Terminal sibling: Active_Correlation_Key__c is cleared, but it is still a
      // sibling under this parent and must be indexed by Correlation_Key__c.
      newInstance('termk', 'Completed', parent.Id);

      Map<String, Workflow_Instance__c> found = WorkflowChildBulkPlanner.findExistingChildren(
        parent.Id,
        new Set<String>{ 'activek', 'termk' }
      );

      System.assertEquals(
        2,
        found.size(),
        'Active and terminal sibling indexed'
      );
      System.assert(found.containsKey('activek'), 'Active key indexed');
      System.assert(found.containsKey('termk'), 'Terminal sibling indexed');
    }
  }

  @IsTest
  static void testFindExistingChildrenForeignActiveKeyThrows() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c parent = newInstance(
        'planner-parent-f',
        'Running',
        null
      );
      Workflow_Instance__c otherParent = newInstance(
        'planner-parent-o',
        'Running',
        null
      );
      // An active instance owning the key belongs to a DIFFERENT parent.
      newInstance('foreignk', 'Running', otherParent.Id);

      Boolean threw = false;
      try {
        WorkflowChildBulkPlanner.findExistingChildren(
          parent.Id,
          new Set<String>{ 'foreignk' }
        );
      } catch (WorkflowEngine.WorkflowException ex) {
        threw = true;
        System.assert(
          ex.getMessage().contains('An active workflow already exists'),
          'A foreign active key must throw: ' + ex.getMessage()
        );
      }
      System.assert(threw, 'A foreign-parent active key must throw');
    }
  }

  @IsTest
  static void testBuildChildInstanceDefaultVersionOne() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c parent = newInstance(
        'planner-parent-v1',
        'Running',
        null
      );

      Workflow_Instance__c child = WorkflowChildBulkPlanner.buildChildInstance(
        childReq(PLANNER_WF, 'child-v1'),
        parent.Id,
        ''
      );

      System.assertEquals(
        1,
        child.Definition_Version__c,
        'Non-versioned defaults to 1'
      );
      System.assertEquals('Pending', child.Status__c, 'Child starts Pending');
      System.assertEquals('child-v1', child.Correlation_Key__c, 'Key copied');
      System.assertEquals(parent.Id, child.Parent_Instance__c, 'Parent linked');
      System.assertEquals(
        parent.Id,
        child.Causation_Id__c,
        'Causation set to parent'
      );
      System.assertEquals(
        'WorkflowChildBulkPlannerTest.PlannerStep',
        child.Current_Step__c,
        'Initial step populated'
      );
    }
  }

  @IsTest
  static void testBuildChildInstanceLatestVersion() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c parent = newInstance(
        'planner-parent-v3',
        'Running',
        null
      );

      Workflow_Instance__c child = WorkflowChildBulkPlanner.buildChildInstance(
        childReq(VERSIONED_WF, 'child-v3'),
        parent.Id,
        ''
      );

      System.assertEquals(
        3,
        child.Definition_Version__c,
        'Versioned workflow adopts its latest version'
      );
    }
  }

  @IsTest
  static void testInsertChildInstancesHappyReturnsTrue() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c parent = newInstance(
        'planner-parent-h',
        'Running',
        null
      );
      Workflow_Instance__c child = WorkflowChildBulkPlanner.buildChildInstance(
        childReq(PLANNER_WF, 'insert-ok'),
        parent.Id,
        ''
      );

      Boolean cont = WorkflowChildBulkPlanner.insertChildInstances(
        new List<Workflow_Instance__c>{ child },
        parent.Id
      );

      System.assertEquals(true, cont, 'A clean insert continues processing');
      System.assertNotEquals(null, child.Id, 'The child was persisted');
    }
  }

  @IsTest
  static void testInsertChildInstancesDuplicateReconciledReturnsFalse() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c parent = newInstance(
        'planner-parent-d',
        'Running',
        null
      );
      // Pre-seed the unique Active_Correlation_Key__c index for THIS parent.
      newInstance('dupkeya', 'Running', parent.Id);

      Workflow_Instance__c collider = WorkflowChildBulkPlanner.buildChildInstance(
        childReq(PLANNER_WF, 'dupkeya'),
        parent.Id,
        ''
      );

      Boolean cont = WorkflowChildBulkPlanner.insertChildInstances(
        new List<Workflow_Instance__c>{ collider },
        parent.Id
      );

      System.assertEquals(
        false,
        cont,
        'A DUPLICATE_VALUE race reconciled against a sibling stops processing'
      );
    }
  }

  @IsTest
  static void testInsertChildInstancesForeignDuplicateThrows() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c parent = newInstance(
        'planner-parent-fd',
        'Running',
        null
      );
      Workflow_Instance__c otherParent = newInstance(
        'planner-parent-fd2',
        'Running',
        null
      );
      // The colliding active key belongs to a different parent.
      newInstance('dupkeyb', 'Running', otherParent.Id);

      Workflow_Instance__c collider = WorkflowChildBulkPlanner.buildChildInstance(
        childReq(PLANNER_WF, 'dupkeyb'),
        parent.Id,
        ''
      );

      Boolean threw = false;
      try {
        WorkflowChildBulkPlanner.insertChildInstances(
          new List<Workflow_Instance__c>{ collider },
          parent.Id
        );
      } catch (WorkflowEngine.WorkflowException ex) {
        threw = true;
        System.assert(
          ex.getMessage().contains('An active workflow already exists'),
          'A foreign duplicate must throw: ' + ex.getMessage()
        );
      }
      System.assert(threw, 'A foreign correlation-key collision must throw');
    }
  }

  @IsTest
  static void testInsertChildInstancesNonDuplicateRethrows() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c parent = newInstance(
        'planner-parent-nd',
        'Running',
        null
      );
      // Workflow_Name__c is required, so this insert fails with a non-duplicate
      // DML status code and must be rethrown unchanged.
      Workflow_Instance__c invalid = new Workflow_Instance__c(
        Status__c = 'Pending',
        Correlation_Key__c = 'reqmiss',
        Parent_Instance__c = parent.Id
      );

      Boolean threw = false;
      try {
        WorkflowChildBulkPlanner.insertChildInstances(
          new List<Workflow_Instance__c>{ invalid },
          parent.Id
        );
      } catch (DmlException ex) {
        threw = true;
        System.assertNotEquals(
          'DUPLICATE_VALUE',
          ex.getDmlStatusCode(0),
          'A non-duplicate DML failure must propagate as-is'
        );
      }
      System.assert(threw, 'A non-duplicate DML error must be rethrown');
    }
  }
}
