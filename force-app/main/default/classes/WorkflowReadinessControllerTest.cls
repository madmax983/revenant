/**
 * @description Tests for the install readiness checks (#114). A fake probe makes a
 * broken install, because tests cannot change custom metadata or trigger status.
 */
@IsTest
private class WorkflowReadinessControllerTest {
  private static final String PASS = 'Pass';
  private static final String WARN = 'Warn';
  private static final String FAIL = 'Fail';

  /**
   * @description Probe that overrides only the facts a test sets.
   */
  private class FakeProbe extends WorkflowReadinessService.Probe {
    Boolean hasConfig;
    Boolean alertSet = false;
    Workflow_Alert_Config__mdt alert;
    Boolean triggerSet = false;
    String triggerStatus;
    Boolean triggerThrows = false;
    String livenessState;
    Set<Schema.SObjectType> unreadableObjects = new Set<Schema.SObjectType>();
    Set<Schema.SObjectType> uncreatableObjects = new Set<Schema.SObjectType>();
    Set<Schema.SObjectField> unreadableFields = new Set<Schema.SObjectField>();
    Set<Schema.SObjectField> uncreatableFields = new Set<Schema.SObjectField>();

    public override Boolean hasEngineConfig() {
      return hasConfig == null ? super.hasEngineConfig() : hasConfig;
    }

    public override Workflow_Alert_Config__mdt defaultAlertConfig() {
      return alertSet ? alert : super.defaultAlertConfig();
    }

    public override String eventTriggerStatus() {
      if (triggerThrows) {
        throw new IllegalArgumentException('Probe failed');
      }
      return triggerSet ? triggerStatus : super.eventTriggerStatus();
    }

    public override String watchdogLivenessState() {
      return livenessState == null
        ? super.watchdogLivenessState()
        : livenessState;
    }

    public override Boolean canRead(Schema.SObjectType objectType) {
      return !unreadableObjects.contains(objectType) &&
        super.canRead(objectType);
    }

    public override Boolean canCreate(Schema.SObjectType objectType) {
      return !uncreatableObjects.contains(objectType) &&
        super.canCreate(objectType);
    }

    public override Boolean canRead(Schema.SObjectField field) {
      return !unreadableFields.contains(field) && super.canRead(field);
    }

    public override Boolean canCreate(Schema.SObjectField field) {
      return !uncreatableFields.contains(field) && super.canCreate(field);
    }

    FakeProbe withAlert(Workflow_Alert_Config__mdt config) {
      alertSet = true;
      alert = config;
      return this;
    }

    FakeProbe withTrigger(String status) {
      triggerSet = true;
      triggerStatus = status;
      return this;
    }
  }

  private static Workflow_Alert_Config__mdt alertConfig(
    Boolean enabled,
    String recipients,
    Boolean publishEvent
  ) {
    return (Workflow_Alert_Config__mdt) JSON.deserialize(
      JSON.serialize(
        new Map<String, Object>{
          'DeveloperName' => 'Default',
          'Enable_Alerts__c' => enabled,
          'Email_Recipients__c' => recipients,
          'Publish_Alert_Event__c' => publishEvent
        }
      ),
      Workflow_Alert_Config__mdt.class
    );
  }

  private static Workflow_Alert_Config__mdt goodAlert() {
    return alertConfig(true, 'ops@example.com', false);
  }

  private static void seedWatchdog(String status) {
    insert new Workflow_Instance__c(
      Workflow_Name__c = 'WatchdogWorkflow',
      Status__c = status,
      Correlation_Key__c = 'SystemWatchdog'
    );
  }

  // Deployed fields give no field access to the org admin profile. Access tests use a
  // user with a known permission set, so the result does not depend on the org.
  private static User userWith(String permissionSetName) {
    Profile stdProfile = [
      SELECT Id
      FROM Profile
      WHERE Name = 'Standard User'
      LIMIT 1
    ];
    User u = new User(
      Alias = 'rdyusr',
      Email = 'readiness@testorg.com',
      EmailEncodingKey = 'UTF-8',
      LastName = 'Readiness',
      LanguageLocaleKey = 'en_US',
      LocaleSidKey = 'en_US',
      ProfileId = stdProfile.Id,
      TimeZoneSidKey = 'America/Los_Angeles',
      UserName = 'readiness_' +
        permissionSetName +
        '_' +
        DateTime.now().getTime() +
        '@testorg.com'
    );
    System.runAs(new User(Id = UserInfo.getUserId())) {
      insert u;
      if (permissionSetName != null) {
        insert new PermissionSetAssignment(
          AssigneeId = u.Id,
          PermissionSetId = [
            SELECT Id
            FROM PermissionSet
            WHERE Name = :permissionSetName
            LIMIT 1
          ]
          .Id
        );
      }
    }
    return u;
  }

  private static Map<String, WorkflowReadinessService.ReadinessCheck> byKey(
    List<WorkflowReadinessService.ReadinessCheck> checks
  ) {
    Map<String, WorkflowReadinessService.ReadinessCheck> result = new Map<String, WorkflowReadinessService.ReadinessCheck>();
    for (WorkflowReadinessService.ReadinessCheck check : checks) {
      result.put(check.key, check);
    }
    return result;
  }

  // AC3: every Warn and Fail names the fix. Every row has a name and a finding.
  private static void assertActionable(
    List<WorkflowReadinessService.ReadinessCheck> checks
  ) {
    System.assertEquals(7, checks.size(), 'Seven checks are expected');
    for (WorkflowReadinessService.ReadinessCheck check : checks) {
      System.assert(String.isNotBlank(check.name), 'Each check has a name');
      System.assert(
        String.isNotBlank(check.finding),
        'Each check has a finding: ' + check.key
      );
      System.assert(
        new Set<String>{ PASS, WARN, FAIL }.contains(check.status),
        'Status is Pass, Warn or Fail: ' + check.status
      );
      if (check.status == PASS) {
        System.assertEquals(
          null,
          check.remediation,
          'A passing check has no fix: ' + check.key
        );
      } else {
        System.assert(
          String.isNotBlank(check.remediation),
          'A Warn or Fail check names the fix: ' + check.key
        );
      }
    }
  }

  private static WorkflowReadinessService.ReadinessCheck check(
    String key,
    List<WorkflowReadinessService.ReadinessCheck> checks
  ) {
    WorkflowReadinessService.ReadinessCheck found = byKey(checks).get(key);
    System.assertNotEquals(null, found, 'Missing check: ' + key);
    return found;
  }

  /**
   * @description AC6: a broken install gives Fail and Warn rows with the fix.
   */
  @IsTest
  static void testBrokenInstallReportsFailAndWarnWithRemediation() {
    FakeProbe fake = new FakeProbe().withAlert(null).withTrigger('Inactive');
    fake.hasConfig = false;
    WorkflowReadinessService.probe = fake;

    List<WorkflowReadinessService.ReadinessCheck> checks;
    System.runAs(new User(Id = UserInfo.getUserId())) {
      checks = WorkflowReadinessController.getReadinessChecks();
    }

    assertActionable(checks);
    WorkflowReadinessService.ReadinessCheck config = check(
      'engineConfig',
      checks
    );
    System.assertEquals(FAIL, config.status, 'A missing config fails');
    System.assert(
      config.finding.contains('Revenant_Config__mdt'),
      config.finding
    );
    System.assert(
      config.remediation.contains('Custom Metadata Types > Revenant Config'),
      config.remediation
    );
    System.assert(
      config.remediation.contains('Revenant_Config.Default.md-meta.xml'),
      config.remediation
    );

    WorkflowReadinessService.ReadinessCheck alert = check(
      'alertConfig',
      checks
    );
    System.assertEquals(WARN, alert.status, 'A missing alert config warns');
    System.assert(
      alert.finding.contains('will not alert anyone'),
      alert.finding
    );
    System.assert(
      alert.remediation.contains('Workflow Alert Config'),
      alert.remediation
    );

    WorkflowReadinessService.ReadinessCheck trig = check(
      'eventTrigger',
      checks
    );
    System.assertEquals(FAIL, trig.status, 'An inactive trigger fails');
    System.assert(
      trig.finding.containsIgnoreCase(
        'inbound signals, approvals, and child-completion resumes will never fire'
      ),
      trig.finding
    );
    System.assert(
      trig.remediation.contains('<status>Active</status>'),
      trig.remediation
    );

    WorkflowReadinessService.ReadinessCheck watchdog = check(
      'watchdog',
      checks
    );
    System.assertEquals(FAIL, watchdog.status, 'No watchdog fails');
    System.assert(watchdog.finding.contains('not running'), watchdog.finding);
    System.assert(
      watchdog.remediation.contains('Enqueue Watchdog'),
      watchdog.remediation
    );
  }

  /**
   * @description AC6: a correct install returns all Pass. Config, trigger and access use
   * the real probe. The package ships no Default alert config, so the probe gives one.
   * The watchdog passes from a seeded Suspended instance.
   */
  @IsTest
  static void testConfiguredOrgReturnsAllPass() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      seedWatchdog('Suspended');
    }
    WorkflowReadinessService.probe = new FakeProbe().withAlert(goodAlert());
    User admin = userWith('Revenant_Admin');

    List<WorkflowReadinessService.ReadinessCheck> checks;
    System.runAs(admin) {
      checks = WorkflowReadinessController.getReadinessChecks();
    }

    assertActionable(checks);
    for (WorkflowReadinessService.ReadinessCheck c : checks) {
      System.assertEquals(PASS, c.status, c.key + ' should pass: ' + c.finding);
    }
  }

  /**
   * @description The rows come in a fixed order.
   */
  @IsTest
  static void testRowOrderIsFixed() {
    WorkflowReadinessService.probe = new FakeProbe().withAlert(goodAlert());
    List<WorkflowReadinessService.ReadinessCheck> checks;
    System.runAs(new User(Id = UserInfo.getUserId())) {
      checks = WorkflowReadinessController.getReadinessChecks();
    }
    List<String> keys = new List<String>();
    for (WorkflowReadinessService.ReadinessCheck c : checks) {
      keys.add(c.key);
    }
    System.assertEquals(
      new List<String>{
        'engineConfig',
        'alertConfig',
        'eventTrigger',
        'watchdog',
        'access.Workflow_Instance__c',
        'access.Workflow_Step_Execution__c',
        'access.Workflow_Signal__c'
      },
      keys,
      'Rows follow the checklist order'
    );
  }

  /**
   * @description A Default alert config that sends nothing warns and names the fields.
   */
  @IsTest
  static void testDisabledDefaultAlertWarns() {
    WorkflowReadinessService.probe = new FakeProbe()
      .withAlert(alertConfig(false, 'ops@example.com', true));
    List<WorkflowReadinessService.ReadinessCheck> checks;
    System.runAs(new User(Id = UserInfo.getUserId())) {
      checks = WorkflowReadinessController.getReadinessChecks();
    }
    WorkflowReadinessService.ReadinessCheck alert = check(
      'alertConfig',
      checks
    );
    System.assertEquals(WARN, alert.status, 'Disabled alerts warn');
    System.assert(alert.finding.contains('Enable_Alerts__c'), alert.finding);
    System.assert(
      alert.remediation.contains('Enable Alerts'),
      alert.remediation
    );
  }

  /**
   * @description An enabled Default alert config with no channel warns.
   */
  @IsTest
  static void testDefaultAlertWithoutChannelWarns() {
    WorkflowReadinessService.probe = new FakeProbe()
      .withAlert(alertConfig(true, null, false));
    List<WorkflowReadinessService.ReadinessCheck> checks;
    System.runAs(new User(Id = UserInfo.getUserId())) {
      checks = WorkflowReadinessController.getReadinessChecks();
    }
    WorkflowReadinessService.ReadinessCheck alert = check(
      'alertConfig',
      checks
    );
    System.assertEquals(WARN, alert.status, 'No channel warns');
    System.assert(alert.finding.contains('Email_Recipients__c'), alert.finding);
  }

  /**
   * @description A trigger that is not deployed fails.
   */
  @IsTest
  static void testMissingTriggerFails() {
    WorkflowReadinessService.probe = new FakeProbe()
      .withAlert(goodAlert())
      .withTrigger(null);
    List<WorkflowReadinessService.ReadinessCheck> checks;
    System.runAs(new User(Id = UserInfo.getUserId())) {
      checks = WorkflowReadinessController.getReadinessChecks();
    }
    WorkflowReadinessService.ReadinessCheck trig = check(
      'eventTrigger',
      checks
    );
    System.assertEquals(FAIL, trig.status, 'A missing trigger fails');
    System.assert(trig.finding.contains('not deployed'), trig.finding);
    System.assert(
      trig.remediation.contains('Deploy triggers/WorkflowEventTrigger.trigger'),
      trig.remediation
    );
  }

  /**
   * @description A deleted trigger is the same as a trigger that is not deployed.
   */
  @IsTest
  static void testDeletedTriggerFailsAsNotDeployed() {
    WorkflowReadinessService.probe = new FakeProbe()
      .withAlert(goodAlert())
      .withTrigger('Deleted');
    List<WorkflowReadinessService.ReadinessCheck> checks;
    System.runAs(new User(Id = UserInfo.getUserId())) {
      checks = WorkflowReadinessController.getReadinessChecks();
    }
    WorkflowReadinessService.ReadinessCheck trig = check(
      'eventTrigger',
      checks
    );
    System.assertEquals(FAIL, trig.status, 'A deleted trigger fails');
    System.assert(trig.finding.contains('not deployed'), trig.finding);
  }

  /**
   * @description A check that throws gives Warn with the error. The other checks run.
   */
  @IsTest
  static void testCheckThatThrowsWarnsAndOthersStillRun() {
    FakeProbe fake = new FakeProbe().withAlert(goodAlert());
    fake.triggerThrows = true;
    WorkflowReadinessService.probe = fake;
    List<WorkflowReadinessService.ReadinessCheck> checks;
    System.runAs(new User(Id = UserInfo.getUserId())) {
      checks = WorkflowReadinessController.getReadinessChecks();
    }
    assertActionable(checks);
    WorkflowReadinessService.ReadinessCheck trig = check(
      'eventTrigger',
      checks
    );
    System.assertEquals(WARN, trig.status, 'A failed probe warns');
    System.assert(trig.finding.contains('could not run'), trig.finding);
    System.assert(trig.finding.contains('Probe failed'), trig.finding);
    System.assertEquals(
      PASS,
      check('alertConfig', checks).status,
      'The other checks still run'
    );
  }

  /**
   * @description The real probe finds the deployed trigger as Active.
   */
  @IsTest
  static void testRealProbeFindsActiveTrigger() {
    System.assertEquals(
      'Active',
      new WorkflowReadinessService.Probe().eventTriggerStatus(),
      'The package deploys WorkflowEventTrigger as Active'
    );
    System.assertEquals(
      true,
      new WorkflowReadinessService.Probe().hasEngineConfig(),
      'The package deploys the Default config record'
    );
  }

  /**
   * @description A watchdog that ran and stopped fails, the same as System Doctor.
   */
  @IsTest
  static void testStoppedWatchdogFailsLikeSystemDoctor() {
    WorkflowReadinessService.probe = new FakeProbe().withAlert(goodAlert());
    List<WorkflowReadinessService.ReadinessCheck> checks;
    Map<String, Object> doctor;
    System.runAs(new User(Id = UserInfo.getUserId())) {
      seedWatchdog('Completed');
      checks = WorkflowReadinessController.getReadinessChecks();
      doctor = WorkflowDashboardController.getWatchdogStatus();
    }
    System.assertEquals(
      false,
      doctor.get('isRunning'),
      'System Doctor says Stopped'
    );
    System.assertEquals(
      FAIL,
      check('watchdog', checks).status,
      'Readiness agrees with System Doctor'
    );
  }

  /**
   * @description A watchdog record that exists but stopped its sweeps (#113 STALE)
   * warns and gives the #113 recovery step.
   */
  @IsTest
  static void testStaleWatchdogWarns() {
    FakeProbe fake = new FakeProbe().withAlert(goodAlert());
    fake.livenessState = 'STALE';
    WorkflowReadinessService.probe = fake;
    List<WorkflowReadinessService.ReadinessCheck> checks;
    System.runAs(new User(Id = UserInfo.getUserId())) {
      seedWatchdog('Suspended');
      checks = WorkflowReadinessController.getReadinessChecks();
    }
    WorkflowReadinessService.ReadinessCheck watchdog = check(
      'watchdog',
      checks
    );
    System.assertEquals(WARN, watchdog.status, 'A stale chain warns');
    System.assert(watchdog.finding.contains('Stale'), watchdog.finding);
    System.assert(
      watchdog.remediation.contains('Cancel the watchdog instance'),
      watchdog.remediation
    );
    System.assert(
      watchdog.remediation.contains('Enqueue Watchdog'),
      watchdog.remediation
    );
  }

  /**
   * @description A running chain with no sweep yet (UNKNOWN) passes. A new chain has
   * not swept yet.
   */
  @IsTest
  static void testRunningWatchdogWithNoSweepYetPasses() {
    FakeProbe fake = new FakeProbe().withAlert(goodAlert());
    fake.livenessState = 'UNKNOWN';
    WorkflowReadinessService.probe = fake;
    List<WorkflowReadinessService.ReadinessCheck> checks;
    System.runAs(new User(Id = UserInfo.getUserId())) {
      seedWatchdog('Suspended');
      checks = WorkflowReadinessController.getReadinessChecks();
    }
    System.assertEquals(
      PASS,
      check('watchdog', checks).status,
      'UNKNOWN liveness on a running chain passes'
    );
  }

  /**
   * @description A read-only operator gets Warn (no create access), not Fail.
   */
  @IsTest
  static void testOperatorGetsCreateWarnNotFail() {
    WorkflowReadinessService.probe = new FakeProbe().withAlert(goodAlert());
    User operator = userWith('Revenant_Operator');
    List<WorkflowReadinessService.ReadinessCheck> checks;
    System.runAs(operator) {
      checks = WorkflowReadinessController.getReadinessChecks();
    }
    assertActionable(checks);
    for (
      String key : new List<String>{
        'access.Workflow_Instance__c',
        'access.Workflow_Step_Execution__c',
        'access.Workflow_Signal__c'
      }
    ) {
      WorkflowReadinessService.ReadinessCheck access = check(key, checks);
      System.assertEquals(WARN, access.status, key + ': read-only warns');
      System.assert(access.finding.contains('cannot create'), access.finding);
      System.assert(
        access.finding.contains('(object)'),
        'Only the object is listed: ' + access.finding
      );
      System.assert(
        access.remediation.contains('Revenant_Operator'),
        access.remediation
      );
      System.assert(
        !access.remediation.contains('Revenant_Admin'),
        'A create gap never asks for the full admin set: ' + access.remediation
      );
    }
  }

  /**
   * @description An unreadable field fails and the finding names the field.
   */
  @IsTest
  static void testUnreadableFieldFailsAndNamesIt() {
    FakeProbe fake = new FakeProbe().withAlert(goodAlert());
    fake.unreadableFields.add(Workflow_Instance__c.Terminal_At__c);
    WorkflowReadinessService.probe = fake;
    List<WorkflowReadinessService.ReadinessCheck> checks;
    System.runAs(userWith('Revenant_Admin')) {
      checks = WorkflowReadinessController.getReadinessChecks();
    }
    WorkflowReadinessService.ReadinessCheck access = check(
      'access.Workflow_Instance__c',
      checks
    );
    System.assertEquals(FAIL, access.status, 'A read gap fails');
    System.assert(
      access.finding.contains('Workflow_Instance__c.Terminal_At__c'),
      access.finding
    );
    System.assert(access.finding.contains('No such column'), access.finding);
    System.assert(
      access.remediation.contains('Revenant Operator'),
      'A read gap points to the least-privilege set: ' + access.remediation
    );
  }

  /**
   * @description An unreadable object fails and the finding names the object.
   */
  @IsTest
  static void testUnreadableObjectFails() {
    FakeProbe fake = new FakeProbe().withAlert(goodAlert());
    fake.unreadableObjects.add(Workflow_Signal__c.SObjectType);
    WorkflowReadinessService.probe = fake;
    List<WorkflowReadinessService.ReadinessCheck> checks;
    System.runAs(userWith('Revenant_Admin')) {
      checks = WorkflowReadinessController.getReadinessChecks();
    }
    WorkflowReadinessService.ReadinessCheck access = check(
      'access.Workflow_Signal__c',
      checks
    );
    System.assertEquals(FAIL, access.status, 'No object read fails');
    System.assert(
      access.finding.contains('Workflow_Signal__c (object)'),
      access.finding
    );
    System.assert(
      !access.finding.contains('Workflow_Signal__c.Payload__c'),
      'Fields are not listed when the object is not readable: ' + access.finding
    );
  }

  /**
   * @description Every custom engine field is checked, not a fixed subset.
   */
  @IsTest
  static void testAnyCustomFieldGapIsFound() {
    FakeProbe fake = new FakeProbe().withAlert(goodAlert());
    fake.unreadableFields.add(Workflow_Signal__c.Signal_Key__c);
    fake.uncreatableFields.add(Workflow_Instance__c.Definition_Shape__c);
    WorkflowReadinessService.probe = fake;
    List<WorkflowReadinessService.ReadinessCheck> checks;
    System.runAs(userWith('Revenant_Admin')) {
      checks = WorkflowReadinessController.getReadinessChecks();
    }
    WorkflowReadinessService.ReadinessCheck signal = check(
      'access.Workflow_Signal__c',
      checks
    );
    System.assertEquals(FAIL, signal.status, 'Signal_Key__c read gap fails');
    System.assert(
      signal.finding.contains('Workflow_Signal__c.Signal_Key__c'),
      signal.finding
    );
    WorkflowReadinessService.ReadinessCheck instance = check(
      'access.Workflow_Instance__c',
      checks
    );
    System.assertEquals(WARN, instance.status, 'A create gap warns');
    System.assert(
      instance.finding.contains('Workflow_Instance__c.Definition_Shape__c'),
      instance.finding
    );
  }

  /**
   * @description Only fields of this package are checked. A field of another package
   * or, in a namespaced install, a subscriber field is not checked.
   */
  @IsTest
  static void testOnlyPackageFieldsAreChecked() {
    System.assert(
      WorkflowReadinessService.isPackageField('Input__c', 'Input__c', null),
      'No namespace: a field with no prefix belongs to the package'
    );
    System.assert(
      !WorkflowReadinessService.isPackageField(
        'other__Extra__c',
        'Extra__c',
        null
      ),
      'No namespace: a field of another package is skipped'
    );
    System.assert(
      WorkflowReadinessService.isPackageField(
        'rvnt__Input__c',
        'Input__c',
        'rvnt'
      ),
      'Namespace: a field with the package prefix belongs to the package'
    );
    System.assert(
      !WorkflowReadinessService.isPackageField('Extra__c', 'Extra__c', 'rvnt'),
      'Namespace: a subscriber field is skipped'
    );
    System.assert(
      !WorkflowReadinessService.isPackageField(
        'other__Extra__c',
        'Extra__c',
        'rvnt'
      ),
      'Namespace: a field of another package is skipped'
    );
  }

  /**
   * @description A read gap and a create gap on one object give one Fail row that
   * names both.
   */
  @IsTest
  static void testReadAndCreateGapsBothNamed() {
    FakeProbe fake = new FakeProbe().withAlert(goodAlert());
    fake.unreadableFields.add(Workflow_Instance__c.Output__c);
    fake.uncreatableFields.add(Workflow_Instance__c.Current_Step__c);
    WorkflowReadinessService.probe = fake;
    List<WorkflowReadinessService.ReadinessCheck> checks;
    System.runAs(userWith('Revenant_Admin')) {
      checks = WorkflowReadinessController.getReadinessChecks();
    }
    WorkflowReadinessService.ReadinessCheck access = check(
      'access.Workflow_Instance__c',
      checks
    );
    System.assertEquals(FAIL, access.status, 'A read gap wins');
    System.assert(
      access.finding.contains('cannot read: Workflow_Instance__c.Output__c'),
      access.finding
    );
    System.assert(
      access.finding.contains(
        'also cannot create: Workflow_Instance__c.Current_Step__c'
      ),
      access.finding
    );
  }

  /**
   * @description An object create gap lists only the object, not each field.
   */
  @IsTest
  static void testObjectCreateGapListsOnlyObject() {
    FakeProbe fake = new FakeProbe().withAlert(goodAlert());
    fake.uncreatableObjects.add(Workflow_Signal__c.SObjectType);
    fake.uncreatableFields.add(Workflow_Signal__c.Payload__c);
    WorkflowReadinessService.probe = fake;
    List<WorkflowReadinessService.ReadinessCheck> checks;
    System.runAs(userWith('Revenant_Admin')) {
      checks = WorkflowReadinessController.getReadinessChecks();
    }
    WorkflowReadinessService.ReadinessCheck access = check(
      'access.Workflow_Signal__c',
      checks
    );
    System.assertEquals(WARN, access.status, 'A create gap warns');
    System.assert(
      access.finding.contains('cannot create: Workflow_Signal__c (object).'),
      access.finding
    );
    System.assert(
      !access.finding.contains('Payload__c'),
      'Fields are not listed when the object has a gap: ' + access.finding
    );
  }

  /**
   * @description An uncreatable field warns and names the field.
   */
  @IsTest
  static void testUncreatableFieldWarnsAndNamesIt() {
    FakeProbe fake = new FakeProbe().withAlert(goodAlert());
    fake.uncreatableFields.add(Workflow_Step_Execution__c.Timeout_At__c);
    WorkflowReadinessService.probe = fake;
    List<WorkflowReadinessService.ReadinessCheck> checks;
    System.runAs(userWith('Revenant_Admin')) {
      checks = WorkflowReadinessController.getReadinessChecks();
    }
    WorkflowReadinessService.ReadinessCheck access = check(
      'access.Workflow_Step_Execution__c',
      checks
    );
    System.assertEquals(WARN, access.status, 'A create gap warns');
    System.assert(
      access.finding.contains('Workflow_Step_Execution__c.Timeout_At__c'),
      access.finding
    );
  }

  /**
   * @description AC4: the checks write nothing, start no job, publish no event, and
   * stay in a small governor budget.
   */
  @IsTest
  static void testChecksAreReadOnlyAndBounded() {
    WorkflowReadinessService.probe = new WorkflowReadinessService.Probe();
    System.runAs(new User(Id = UserInfo.getUserId())) {
      seedWatchdog('Suspended');
      Integer queries = Limits.getQueries();
      Integer dml = Limits.getDmlStatements();
      Integer jobs = Limits.getQueueableJobs();
      Integer events = Limits.getPublishImmediateDML();
      Integer cpu = Limits.getCpuTime();

      List<WorkflowReadinessService.ReadinessCheck> checks = WorkflowReadinessController.getReadinessChecks();

      System.assertEquals(7, checks.size(), 'All checks run');
      System.assertEquals(0, Limits.getDmlStatements() - dml, 'No DML');
      System.assertEquals(0, Limits.getQueueableJobs() - jobs, 'No jobs');
      System.assertEquals(
        0,
        Limits.getPublishImmediateDML() - events,
        'No events'
      );
      System.assert(
        Limits.getQueries() - queries <= 3,
        'At most 3 SOQL (auth, trigger, watchdog): ' +
        (Limits.getQueries() - queries)
      );
      System.assert(
        Limits.getCpuTime() - cpu < 2000,
        'CPU budget: checks use less than 2000 ms of CPU'
      );
    }
  }

  /**
   * @description A user without dashboard access gets the same denial as other panels.
   */
  @IsTest
  static void testUnauthorizedUserIsDenied() {
    User stdUser = userWith(null);
    System.runAs(stdUser) {
      String panelMessage;
      try {
        WorkflowDashboardController.getConcurrencyStatus();
      } catch (AuraHandledException e) {
        panelMessage = e.getMessage();
      }
      try {
        WorkflowReadinessController.getReadinessChecks();
        System.assert(false, 'Expected AuraHandledException');
      } catch (AuraHandledException e) {
        System.assertEquals(
          panelMessage,
          e.getMessage(),
          'The denial must match the other dashboard panels'
        );
      }
    }
  }

  /**
   * @description Both dashboard permission sets grant the controller class.
   */
  @IsTest
  static void testPermissionSetsGrantController() {
    Set<String> granted = new Set<String>();
    for (SetupEntityAccess sea : [
      SELECT Parent.Name
      FROM SetupEntityAccess
      WHERE
        SetupEntityId IN (
          SELECT Id
          FROM ApexClass
          WHERE Name = 'WorkflowReadinessController'
        )
        AND Parent.Name IN ('Revenant_Operator', 'Revenant_Admin')
    ]) {
      granted.add(sea.Parent.Name);
    }
    System.assert(granted.contains('Revenant_Operator'), granted);
    System.assert(granted.contains('Revenant_Admin'), granted);
  }
}
