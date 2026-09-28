/**
 * @description Runs the install readiness checks for the Readiness panel in System Doctor
 * (#114). Each check gives Pass, Warn or Fail, a finding, and a fix for Warn and Fail.
 * It only reads: getInstance, describe, and two bounded SOQL queries (plus one for the
 * view gate when the user passes it through Modify All Data). It makes no DML, starts no
 * job, and publishes no event. The watchdog check uses the System Doctor signal.
 */
public inherited sharing class WorkflowReadinessService {
  public static final String STATUS_PASS = 'Pass';
  public static final String STATUS_WARN = 'Warn';
  public static final String STATUS_FAIL = 'Fail';

  private static final String CONFIG_NAME = 'Default';
  private static final String TRIGGER_NAME = 'WorkflowEventTrigger';
  private static final String NO_FIRE = 'Inbound signals, approvals, and child-completion resumes will never fire.';
  private static final String NO_ALERT = 'Workflow failures will not alert anyone.';
  private static final String OPERATOR_PATH = 'Setup > Permission Sets > Revenant Operator > Manage Assignments > Add Assignment';

  // Tests replace the probe to make a broken install.
  @TestVisible
  private static Probe probe = new Probe();

  // The core engine objects. Each rule checks all custom fields of its object. Built
  // after the view gate, because each rule runs a describe.
  private static List<AccessRule> accessRules() {
    return new List<AccessRule>{
      new AccessRule(Workflow_Instance__c.SObjectType),
      new AccessRule(Workflow_Step_Execution__c.SObjectType),
      new AccessRule(Workflow_Signal__c.SObjectType)
    };
  }

  /**
   * @description Reads org facts. Tests extend it to make a broken install.
   */
  public virtual class Probe {
    /**
     * @description True when the Default Revenant_Config__mdt record exists.
     * @return True when present.
     */
    public virtual Boolean hasEngineConfig() {
      return Revenant_Config__mdt.getInstance(CONFIG_NAME) != null;
    }

    /**
     * @description The Default Workflow_Alert_Config__mdt record, or null.
     * @return The record, or null.
     */
    public virtual Workflow_Alert_Config__mdt defaultAlertConfig() {
      return Workflow_Alert_Config__mdt.getInstance(CONFIG_NAME);
    }

    /**
     * @description The status of WorkflowEventTrigger in this namespace.
     * @return 'Active', 'Inactive', 'Deleted', or null when not found.
     */
    public virtual String eventTriggerStatus() {
      String namespace = packageNamespace();
      List<ApexTrigger> triggers = [
        SELECT Status
        FROM ApexTrigger
        WHERE Name = :TRIGGER_NAME AND NamespacePrefix = :namespace
        WITH SYSTEM_MODE
        LIMIT 1
      ];
      return triggers.isEmpty() ? null : triggers[0].Status;
    }

    /**
     * @description True when the watchdog chain runs. Same signal as System Doctor.
     * @return True when running.
     */
    public virtual Boolean watchdogRunning() {
      return WorkflowDashboardStatusService.watchdogRunning();
    }

    /**
     * @description The watchdog liveness state of System Doctor (#113). It only reads:
     * it does not run the stall detector, so it sends no alert.
     * @return 'HEALTHY', 'STALE' or 'UNKNOWN'.
     */
    public virtual String watchdogLivenessState() {
      return WatchdogLiveness.evaluateNow().state;
    }

    /**
     * @description True when the running user can read the object.
     * @param objectType The object.
     * @return True when readable.
     */
    public virtual Boolean canRead(Schema.SObjectType objectType) {
      return objectType.getDescribe(SObjectDescribeOptions.DEFERRED)
        .isAccessible();
    }

    /**
     * @description True when the running user can create the object.
     * @param objectType The object.
     * @return True when creatable.
     */
    public virtual Boolean canCreate(Schema.SObjectType objectType) {
      return objectType.getDescribe(SObjectDescribeOptions.DEFERRED)
        .isCreateable();
    }

    /**
     * @description True when the running user can read the field.
     * @param field The field.
     * @return True when readable.
     */
    public virtual Boolean canRead(Schema.SObjectField field) {
      return field.getDescribe().isAccessible();
    }

    /**
     * @description True when the running user can set the field on create.
     * @param field The field.
     * @return True when creatable.
     */
    public virtual Boolean canCreate(Schema.SObjectField field) {
      return field.getDescribe().isCreateable();
    }
  }

  /**
   * @description Runs all readiness checks in a fixed order. It checks the dashboard
   * view gate first. A check that throws gives Warn; the other checks still run.
   * @return One row per check.
   */
  public static List<WorkflowReadinessCheck> runChecks() {
    WorkflowDashboardSupport.checkAuthorization();
    List<Rule> rules = new List<Rule>{
      new EngineConfigRule(),
      new AlertConfigRule(),
      new EventTriggerRule(),
      new WatchdogRule()
    };
    for (AccessRule rule : accessRules()) {
      rules.add(rule);
    }

    List<WorkflowReadinessCheck> checks = new List<WorkflowReadinessCheck>();
    for (Rule rule : rules) {
      checks.add(rule.safeRun());
    }
    return checks;
  }

  // True when the field belongs to this package. With a namespace, the field name must
  // start with it. Without a namespace, the field must have no namespace prefix, so
  // fields of other packages are not included.
  @TestVisible
  private static Boolean isPackageField(
    String name,
    String localName,
    String namespace
  ) {
    if (String.isBlank(namespace)) {
      return name == localName;
    }
    return name.startsWithIgnoreCase(namespace + '__');
  }

  // The namespace of this package, or null when not in a namespace.
  private static String packageNamespace() {
    String className = WorkflowReadinessService.class.getName();
    return className.contains('.') ? className.substringBefore('.') : null;
  }

  // One check. Subclasses give the key, the name and evaluate().
  private abstract class Rule {
    protected String key;
    protected String name;

    protected abstract WorkflowReadinessCheck evaluate();

    public WorkflowReadinessCheck safeRun() {
      try {
        return evaluate();
      } catch (Exception ex) {
        return row(
          STATUS_WARN,
          'This check could not run: ' + ex.getMessage(),
          'Click Run Checks again. If the error stays, send the message to your Salesforce admin.'
        );
      }
    }

    protected WorkflowReadinessCheck pass(String finding) {
      return row(STATUS_PASS, finding, null);
    }

    // Builds a row. A Pass row has no remediation.
    protected WorkflowReadinessCheck row(
      String status,
      String finding,
      String remediation
    ) {
      WorkflowReadinessCheck check = new WorkflowReadinessCheck();
      check.key = key;
      check.name = name;
      check.status = status;
      check.finding = finding;
      check.remediation = remediation;
      return check;
    }
  }

  // (a) The Default engine config record.
  private class EngineConfigRule extends Rule {
    public EngineConfigRule() {
      key = 'engineConfig';
      name = 'Engine config';
    }

    protected override WorkflowReadinessCheck evaluate() {
      if (probe.hasEngineConfig()) {
        return pass('The Default Revenant_Config__mdt record is present.');
      }
      return row(
        STATUS_FAIL,
        'No Revenant_Config__mdt record named Default. The engine uses built-in defaults, and you cannot change engine settings.',
        'Setup > Custom Metadata Types > Revenant Config > Manage Records > New. Set Label and Name to Default. Or deploy customMetadata/Revenant_Config.Default.md-meta.xml.'
      );
    }
  }

  // (b) The Default alert config record. It must be able to send an alert.
  private class AlertConfigRule extends Rule {
    public AlertConfigRule() {
      key = 'alertConfig';
      name = 'Failure alerts';
    }

    protected override WorkflowReadinessCheck evaluate() {
      Workflow_Alert_Config__mdt config = probe.defaultAlertConfig();
      if (config == null) {
        return row(
          STATUS_WARN,
          'No Workflow_Alert_Config__mdt record named Default. ' +
            NO_ALERT +
            ' Only workflows with their own record send alerts.',
          'Setup > Custom Metadata Types > Workflow Alert Config > Manage Records > New. Set Label and Name to Default, select Enable Alerts, and set Email Recipients or select Publish Alert Event.'
        );
      }
      if (WorkflowAlertManager.isAlertActionable(config)) {
        return pass(
          'The Default Workflow_Alert_Config__mdt record sends failure alerts.'
        );
      }
      String cause = config.Enable_Alerts__c == true
        ? 'has no address in Email_Recipients__c and Publish_Alert_Event__c is off.'
        : 'has Enable_Alerts__c off.';
      return row(
        STATUS_WARN,
        'The Default Workflow_Alert_Config__mdt record ' +
          cause +
          ' Failures of workflows without their own alert record will not alert anyone.',
        'Setup > Custom Metadata Types > Workflow Alert Config > Manage Records > Default > Edit. Select Enable Alerts, and set Email Recipients or select Publish Alert Event.'
      );
    }
  }

  // (c) The platform event trigger that delivers signals and resumes.
  private class EventTriggerRule extends Rule {
    public EventTriggerRule() {
      key = 'eventTrigger';
      name = 'Event trigger';
    }

    protected override WorkflowReadinessCheck evaluate() {
      String status = probe.eventTriggerStatus();
      if (status == 'Active') {
        return pass('WorkflowEventTrigger is Active.');
      }
      if (status == 'Inactive') {
        return row(
          STATUS_FAIL,
          'WorkflowEventTrigger is Inactive. ' + NO_FIRE,
          'Set <status>Active</status> in WorkflowEventTrigger.trigger-meta.xml and deploy. In a sandbox, you can also use Setup > Apex Triggers > WorkflowEventTrigger > Edit > Is Active.'
        );
      }
      return row(
        STATUS_FAIL,
        'WorkflowEventTrigger is not deployed. ' + NO_FIRE,
        'Deploy triggers/WorkflowEventTrigger.trigger with <status>Active</status> in WorkflowEventTrigger.trigger-meta.xml.'
      );
    }
  }

  // (d) The watchdog chain. Uses the System Doctor signals: Running/Stopped and the
  // #113 liveness state. UNKNOWN (no sweep yet) on a running chain passes.
  private class WatchdogRule extends Rule {
    public WatchdogRule() {
      key = 'watchdog';
      name = 'Watchdog chain';
    }

    protected override WorkflowReadinessCheck evaluate() {
      if (!probe.watchdogRunning()) {
        return row(
          STATUS_FAIL,
          'The watchdog chain is not running (System Doctor shows Stopped). Sleeps, timeouts, retries, and stall recovery do not resume.',
          'Click Enqueue Watchdog in the Watchdog Daemon Health panel on this tab.'
        );
      }
      if (probe.watchdogLivenessState() == WatchdogLiveness.STATE_STALE) {
        return row(
          STATUS_WARN,
          'The watchdog record is active, but its sweeps stopped (System Doctor shows Stale). Sleeps, timeouts, retries, and stall recovery do not resume.',
          'Cancel the watchdog instance (Correlation Key SystemWatchdog) on this dashboard, then click Enqueue Watchdog. See docs/watchdog-liveness.md.'
        );
      }
      return pass('The watchdog chain is running.');
    }
  }

  // (e) Read and create access of the running user to one engine object and its fields.
  // A read gap gives Fail. When only create access is missing, the check gives Warn,
  // because the engine writes in system mode and a read-only operator needs no create.
  private class AccessRule extends Rule {
    private Schema.SObjectType objectType;

    public AccessRule(Schema.SObjectType objectType) {
      this.objectType = objectType;
      key = 'access.' + describeObjectName();
      name = 'Access: ' + describeObjectName();
    }

    private String describeObjectName() {
      return objectType.getDescribe(SObjectDescribeOptions.DEFERRED)
        .getLocalName();
    }

    // When the object itself has a gap, only the object is listed for that gap.
    protected override WorkflowReadinessCheck evaluate() {
      String objectName = describeObjectName();
      Boolean objectReadable = probe.canRead(objectType);
      Boolean objectCreatable = probe.canCreate(objectType);
      List<String> readGaps = new List<String>();
      List<String> createGaps = new List<String>();
      if (!objectReadable) {
        readGaps.add(objectName + ' (object)');
      }
      if (!objectCreatable) {
        createGaps.add(objectName + ' (object)');
      }
      for (Schema.SObjectField field : customFields()) {
        String fieldName =
          objectName +
          '.' +
          field.getDescribe().getLocalName();
        if (objectReadable && !probe.canRead(field)) {
          readGaps.add(fieldName);
        }
        if (objectCreatable && !probe.canCreate(field)) {
          createGaps.add(fieldName);
        }
      }
      return toCheck(objectName, readGaps, createGaps);
    }

    // The custom fields of this package that hold data (no formula, no auto number),
    // sorted by name. Fields of other packages are not included.
    private List<Schema.SObjectField> customFields() {
      Map<String, Schema.SObjectField> byName = objectType.getDescribe()
        .fields.getMap();
      List<String> names = new List<String>(byName.keySet());
      names.sort();
      String namespace = packageNamespace();
      List<Schema.SObjectField> result = new List<Schema.SObjectField>();
      for (String fieldName : names) {
        Schema.DescribeFieldResult d = byName.get(fieldName).getDescribe();
        if (
          d.isCustom() &&
          !d.isCalculated() &&
          !d.isAutoNumber() &&
          isPackageField(d.getName(), d.getLocalName(), namespace)
        ) {
          result.add(byName.get(fieldName));
        }
      }
      return result;
    }

    private WorkflowReadinessCheck toCheck(
      String objectName,
      List<String> readGaps,
      List<String> createGaps
    ) {
      if (!readGaps.isEmpty()) {
        String finding =
          'This user cannot read: ' +
          String.join(readGaps, ', ') +
          '. Queries in user mode (custom Apex, Flow, reports) fail on these items. A missing field gives "No such column".';
        if (!createGaps.isEmpty()) {
          finding +=
            ' This user also cannot create: ' +
            String.join(createGaps, ', ') +
            '.';
        }
        return row(
          STATUS_FAIL,
          finding,
          'Assign Revenant_Operator (read only) to this user: ' +
            OPERATOR_PATH +
            '. Or grant read access to the listed items.'
        );
      }
      if (!createGaps.isEmpty()) {
        return row(
          STATUS_WARN,
          'This user can read but cannot create: ' +
            String.join(createGaps, ', ') +
            '. The engine writes in system mode, but custom Apex, Flow, or integrations that create these records in user mode fail for this user.',
          'No action for workflow starts or a read-only operator (Revenant_Operator). Only if this user creates these records in user mode, grant create access on the listed items in a small permission set: Setup > Permission Sets > New > Object Settings.'
        );
      }
      return pass(
        'This user can read and create ' +
          objectName +
          ' and all its package fields.'
      );
    }
  }
}
