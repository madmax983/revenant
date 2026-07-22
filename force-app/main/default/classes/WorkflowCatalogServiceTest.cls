/**
 * @description Unit tests for WorkflowCatalogService: the read-only Workflow Catalog that
 * lists every discovered definition with a label, description, version, and an
 * active/failed/suspended health rollup. Exercises the grouped-aggregate health pivot, the
 * optional WorkflowCatalogDescribable label/description path, the humanized class-name
 * fallback for undocumented definitions, VersionedWorkflow version surfacing, the
 * zero-instance definition still appearing with zero counts, and the authorization gate on
 * the public entry points.
 */
@IsTest
public class WorkflowCatalogServiceTest {
  private static final String DESCRIBED = 'WorkflowCatalogServiceTest.DescribedVersionedWf';
  private static final String PLAIN = 'WorkflowCatalogServiceTest.PlainUndocumentedWf';

  /**
   * @description A fully self-describing, versioned definition fixture used to assert the
   * interface-supplied label/description and the surfaced current version. Instantiated by
   * the service via WorkflowTypeResolver, so it is public with a no-arg constructor.
   */
  public class DescribedVersionedWf implements VersionedWorkflow, WorkflowCatalogDescribable {
    /**
     * @description Returns the sole fixture step name.
     * @return A one-element list naming the test step.
     */
    public List<String> getSteps() {
      return new List<String>{ 'StepA' };
    }
    /**
     * @description Returns the step the fixture begins with.
     * @return The test step name.
     */
    public String getInitialStep() {
      return 'StepA';
    }
    /**
     * @description Terminal single-step fixture: there is no successor step.
     * @param currentStepName The name of the step that just completed.
     * @param stepResult The result of the completed step.
     * @return Always null, ending the workflow.
     */
    public String getNextStep(String currentStepName, StepResult stepResult) {
      return null;
    }
    /**
     * @description Version-aware next-step routing for the fixture (unused topology).
     * @param currentStepName The name of the step that just completed.
     * @param result The result of the completed step.
     * @param version The workflow version being evaluated.
     * @return Always null, ending the workflow.
     */
    public String getNextStep(
      String currentStepName,
      StepResult result,
      Integer version
    ) {
      return null;
    }
    /**
     * @description Declares the fixture's current version.
     * @return The latest defined version number.
     */
    public Integer getLatestVersion() {
      return 3;
    }
    /**
     * @description Supplies the catalog label for this fixture.
     * @return The friendly label shown in the catalog.
     */
    public String catalogLabel() {
      return 'Custom Described Flow';
    }
    /**
     * @description Supplies the catalog description for this fixture.
     * @return The description of the workflow's purpose.
     */
    public String catalogDescription() {
      return 'Coordinates the described end-to-end flow.';
    }
  }

  /**
   * @description A plain definition fixture that adopts neither WorkflowCatalogDescribable
   * nor VersionedWorkflow, exercising the humanized-class-name fallback, the "undocumented"
   * marker, and the null version.
   */
  public class PlainUndocumentedWf implements WorkflowDefinition {
    /**
     * @description Returns the sole fixture step name.
     * @return A one-element list naming the test step.
     */
    public List<String> getSteps() {
      return new List<String>{ 'StepA' };
    }
    /**
     * @description Returns the step the fixture begins with.
     * @return The test step name.
     */
    public String getInitialStep() {
      return 'StepA';
    }
    /**
     * @description Terminal single-step fixture: there is no successor step.
     * @param currentStepName The name of the step that just completed.
     * @param stepResult The result of the completed step.
     * @return Always null, ending the workflow.
     */
    public String getNextStep(String currentStepName, StepResult stepResult) {
      return null;
    }
  }

  private static Map<String, Object> rowFor(
    List<Map<String, Object>> rows,
    String className
  ) {
    for (Map<String, Object> row : rows) {
      if (className.equals((String) row.get('className'))) {
        return row;
      }
    }
    return null;
  }

  @IsTest
  static void testHealthCountsPivotPerDefinition() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Active bucket: Pending, Running, Compensating, Cancelling, Paused (5).
      insertInstance(DESCRIBED, 'Pending', 'c-pending');
      insertInstance(DESCRIBED, 'Running', 'c-running');
      insertInstance(DESCRIBED, 'Compensating', 'c-comp');
      insertInstance(DESCRIBED, 'Cancelling', 'c-cancelling');
      insertInstance(DESCRIBED, 'Paused', 'c-paused');
      // Failed bucket: Failed, CompensationFailed (2).
      insertInstance(DESCRIBED, 'Failed', 'c-failed');
      insertInstance(DESCRIBED, 'CompensationFailed', 'c-compfail');
      // Suspended bucket: Suspended (1).
      insertInstance(DESCRIBED, 'Suspended', 'c-suspended');
      // Terminal statuses must be ignored by every bucket.
      insertInstance(DESCRIBED, 'Completed', 'c-done');
      insertInstance(DESCRIBED, 'Cancelled', 'c-cancelled');

      Test.startTest();
      List<Map<String, Object>> rows = WorkflowCatalogService.buildCatalogFor(
        new List<String>{ DESCRIBED, PLAIN }
      );
      Test.stopTest();

      Map<String, Object> described = rowFor(rows, DESCRIBED);
      System.assertNotEquals(
        null,
        described,
        'The described definition should have a catalog row'
      );
      System.assertEquals(
        5,
        (Integer) described.get('active'),
        'Active count should roll up the five in-flight statuses'
      );
      System.assertEquals(
        2,
        (Integer) described.get('failed'),
        'Failed count should roll up Failed + CompensationFailed'
      );
      System.assertEquals(
        1,
        (Integer) described.get('suspended'),
        'Suspended count should be exactly the Suspended instance'
      );
      System.assertEquals(
        8,
        (Integer) described.get('total'),
        'Total should exclude clean-terminal instances'
      );
    }
  }

  @IsTest
  static void testInterfaceSuppliedLabelDescriptionAndVersion() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      List<Map<String, Object>> rows = WorkflowCatalogService.buildCatalogFor(
        new List<String>{ DESCRIBED }
      );
      Test.stopTest();

      Map<String, Object> described = rowFor(rows, DESCRIBED);
      System.assertNotEquals(null, described, 'Expected a described row');
      System.assertEquals(
        'Custom Described Flow',
        (String) described.get('label'),
        'Label should come from WorkflowCatalogDescribable.catalogLabel()'
      );
      System.assertEquals(
        'Coordinates the described end-to-end flow.',
        (String) described.get('description'),
        'Description should come from catalogDescription()'
      );
      System.assertEquals(
        true,
        (Boolean) described.get('documented'),
        'A definition supplying label + description is documented'
      );
      System.assertEquals(
        true,
        (Boolean) described.get('versioned'),
        'A VersionedWorkflow implementation should be flagged versioned'
      );
      System.assertEquals(
        3,
        (Integer) described.get('version'),
        'Version should be the definition-declared getLatestVersion()'
      );
    }
  }

  @IsTest
  static void testUndocumentedFallbackAndZeroCounts() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // No instances seeded for PLAIN: it must still appear with zero counts.
      Test.startTest();
      List<Map<String, Object>> rows = WorkflowCatalogService.buildCatalogFor(
        new List<String>{ PLAIN }
      );
      Test.stopTest();

      Map<String, Object> plain = rowFor(rows, PLAIN);
      System.assertNotEquals(
        null,
        plain,
        'A definition with no instances must still be listed'
      );
      System.assertEquals(
        false,
        (Boolean) plain.get('documented'),
        'A definition supplying neither label nor description is undocumented'
      );
      System.assertEquals(
        null,
        plain.get('description'),
        'Undocumented definition should have no description'
      );
      System.assertEquals(
        false,
        (Boolean) plain.get('versioned'),
        'A non-VersionedWorkflow definition is not versioned'
      );
      System.assertEquals(
        null,
        plain.get('version'),
        'A non-VersionedWorkflow definition has no version'
      );
      System.assertEquals(
        0,
        (Integer) plain.get('active'),
        'Zero active for a definition with no instances'
      );
      System.assertEquals(
        0,
        (Integer) plain.get('total'),
        'Zero total for a definition with no instances'
      );
      // The humanized fallback label is derived from the class name and is non-blank.
      System.assert(
        String.isNotBlank((String) plain.get('label')),
        'Undocumented definitions still get a humanized fallback label'
      );
    }
  }

  @IsTest
  static void testHumanizeClassNameFallback() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Directly exercise the fallback humanizer for the canonical examples.
      System.assertEquals(
        'Purchase Approval Workflow',
        WorkflowCatalogService.humanize('PurchaseApprovalWorkflow'),
        'Camel-case class name should humanize with spaces'
      );
      System.assertEquals(
        'Order HTTP Retry Workflow',
        WorkflowCatalogService.humanize('Order.HTTPRetryWorkflow'),
        'Inner-class separator becomes a space and acronyms split correctly'
      );
    }
  }

  @IsTest
  static void testBuildCatalogListsAllDiscoveredDefinitions() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      List<String> discovered = WorkflowDefinitionDiscoveryService.discover();

      Test.startTest();
      List<Map<String, Object>> rows = WorkflowCatalogService.buildCatalog();
      Test.stopTest();

      System.assertEquals(
        discovered.size(),
        rows.size(),
        'The catalog must list exactly the discovered definitions (none dropped)'
      );
      Set<String> discoveredSet = new Set<String>(discovered);
      for (Map<String, Object> row : rows) {
        System.assert(
          discoveredSet.contains((String) row.get('className')),
          'Every catalog row must correspond to a discovered definition'
        );
      }
    }
  }

  @IsTest
  static void testControllerEndpointDelegates() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      List<Map<String, Object>> rows = WorkflowDashboardController.getWorkflowCatalog();
      Test.stopTest();

      System.assertNotEquals(
        null,
        rows,
        'The controller endpoint should return the catalog rows'
      );
    }
  }

  @IsTest
  static void testAuthorizationGateEnforced() {
    // A user with neither Workflow_Admin nor Modify All Data must be rejected.
    User restricted = buildMinimalAccessUser();
    if (restricted == null) {
      return; // No minimal-access profile available in this org; skip.
    }
    insert restricted;

    System.runAs(restricted) {
      Boolean threw = false;
      try {
        WorkflowCatalogService.buildCatalog();
      } catch (AuraHandledException ex) {
        threw = true;
      }
      System.assert(
        threw,
        'buildCatalog must enforce the dashboard authorization gate'
      );
    }
  }

  private static void insertInstance(
    String workflowName,
    String status,
    String correlationKey
  ) {
    insert new Workflow_Instance__c(
      Workflow_Name__c = workflowName,
      Status__c = status,
      Correlation_Key__c = correlationKey
    );
  }

  private static User buildMinimalAccessUser() {
    List<Profile> minimal = [
      SELECT Id
      FROM Profile
      WHERE Name = 'Minimum Access - Salesforce'
      LIMIT 1
    ];
    if (minimal.isEmpty()) {
      return null;
    }
    String unique = 'wfcat' + String.valueOf(Datetime.now().getTime());
    return new User(
      ProfileId = minimal[0].Id,
      LastName = 'Catalog',
      Email = unique + '@example.com',
      Username = unique + '@example.com.revenant',
      Alias = 'wfcat',
      TimeZoneSidKey = 'America/Los_Angeles',
      LocaleSidKey = 'en_US',
      EmailEncodingKey = 'UTF-8',
      LanguageLocaleKey = 'en_US'
    );
  }
}
