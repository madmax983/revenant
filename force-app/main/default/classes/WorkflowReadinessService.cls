/**
 * @description Runs the install readiness checks for the Readiness panel in System Doctor
 * (#114). Each check gives Pass, Warn or Fail, a finding, and a fix for Warn and Fail.
 * It only reads: getInstance, describe, and two bounded SOQL queries. It makes no DML,
 * starts no job, and publishes no event. The watchdog check uses the System Doctor signal.
 */
public inherited sharing class WorkflowReadinessService {
  public static final String STATUS_PASS = 'Pass';
  public static final String STATUS_WARN = 'Warn';
  public static final String STATUS_FAIL = 'Fail';

  private static final String CONFIG_NAME = 'Default';
  private static final String TRIGGER_NAME = 'WorkflowEventTrigger';
  private static final String NO_FIRE = 'Thus, inbound signals, approvals, and child-completion resumes will never fire.';
  private static final String NO_ALERT = 'Workflow failures will not alert anyone.';
  private static final String ADMIN_PATH = 'Setup > Permission Sets > Revenant Admin > Manage Assignments > Add Assignment';

  // Tests replace the probe to make a broken install.
  @TestVisible
  private static Probe probe = new Probe();

  // The core engine objects and the fields the engine writes on them.
  private static final List<AccessRule> ACCESS_RULES = new List<AccessRule>{
    new AccessRule(
      Workflow_Instance__c.SObjectType,
      new List<Schema.SObjectField>{
        Workflow_Instance__c.Workflow_Name__c,
        Workflow_Instance__c.Status__c,
        Workflow_Instance__c.Correlation_Key__c,
        Workflow_Instance__c.Current_Step__c,
        Workflow_Instance__c.Input__c,
        Workflow_Instance__c.Output__c,
        Workflow_Instance__c.Error_Message__c,
        Workflow_Instance__c.Sleep_Until__c,
        Workflow_Instance__c.Terminal_At__c,
        Workflow_Instance__c.Parent_Instance__c
      }
    ),
    new AccessRule(
      Workflow_Step_Execution__c.SObjectType,
      new List<Schema.SObjectField>{
        Workflow_Step_Execution__c.Workflow_Instance__c,
        Workflow_Step_Execution__c.Step_Name__c,
        Workflow_Step_Execution__c.Status__c,
        Workflow_Step_Execution__c.Input__c,
        Workflow_Step_Execution__c.Output__c,
        Workflow_Step_Execution__c.Error_Details__c,
        Workflow_Step_Execution__c.Retry_Count__c,
        Workflow_Step_Execution__c.Timeout_At__c
      }
    ),
    new AccessRule(
      Workflow_Signal__c.SObjectType,
      new List<Schema.SObjectField>{
        Workflow_Signal__c.Workflow_Instance__c,
        Workflow_Signal__c.Signal_Name__c,
        Workflow_Signal__c.Status__c,
        Workflow_Signal__c.Correlation_Key__c,
        Workflow_Signal__c.Payload__c
      }
    )
  };

  /**
   * @description One readiness check row.
   */
  public class ReadinessCheck {
    @AuraEnabled
    public String key;
    @AuraEnabled
    public String name;
    @AuraEnabled
    public String status;
    @AuraEnabled
    public String finding;
    @AuraEnabled
    public String remediation;
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
  public static List<ReadinessCheck> runChecks() {
    WorkflowDashboardSupport.checkAuthorization();
    List<Rule> rules = new List<Rule>{
      new EngineConfigRule(),
      new AlertConfigRule(),
      new EventTriggerRule(),
      new WatchdogRule()
    };
    for (AccessRule rule : ACCESS_RULES) {
      rules.add(rule);
    }

    List<ReadinessCheck> checks = new List<ReadinessCheck>();
    for (Rule rule : rules) {
      checks.add(rule.safeRun());
    }
    return checks;
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

    protected abstract ReadinessCheck evaluate();

    public ReadinessCheck safeRun() {
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

    protected ReadinessCheck pass(String finding) {
      return row(STATUS_PASS, finding, null);
    }

    // Builds a row. A Pass row has no remediation.
    protected ReadinessCheck row(
      String status,
      String finding,
      String remediation
    ) {
      ReadinessCheck check = new ReadinessCheck();
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

    protected override ReadinessCheck evaluate() {
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

    protected override ReadinessCheck evaluate() {
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
        ? 'has no Email_Recipients__c and Publish_Alert_Event__c is off.'
        : 'has Enable_Alerts__c off.';
      return row(
        STATUS_WARN,
        'The Default Workflow_Alert_Config__mdt record ' +
          cause +
          ' ' +
          NO_ALERT,
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

    protected override ReadinessCheck evaluate() {
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

  // (d) The watchdog chain. Uses the System Doctor signal.
  private class WatchdogRule extends Rule {
    public WatchdogRule() {
      key = 'watchdog';
      name = 'Watchdog chain';
    }

    protected override ReadinessCheck evaluate() {
      if (probe.watchdogRunning()) {
        return pass('The watchdog chain is running.');
      }
      return row(
        STATUS_FAIL,
        'The watchdog chain is not running (System Doctor shows Stopped). Sleeps, timeouts, retries, and stall recovery do not resume.',
        'Click Enqueue Watchdog in the Watchdog Daemon Health panel on this tab.'
      );
    }
  }

  // (e) Read and create access of the running user to one engine object and its fields.
  // A read gap is Fail. A create gap only is Warn, because a read-only operator needs no
  // create access.
  private class AccessRule extends Rule {
    private Schema.SObjectType objectType;
    private List<Schema.SObjectField> fields;

    public AccessRule(
      Schema.SObjectType objectType,
      List<Schema.SObjectField> fields
    ) {
      this.objectType = objectType;
      this.fields = fields;
      key = 'access.' + objectName();
      name = 'Access: ' + objectName();
    }

    private String objectName() {
      return objectType.getDescribe(SObjectDescribeOptions.DEFERRED)
        .getLocalName();
    }

    // When the object itself has a gap, only the object is listed for that gap.
    protected override ReadinessCheck evaluate() {
      String objectName = objectName();
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
      for (Schema.SObjectField field : fields) {
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

    private ReadinessCheck toCheck(
      String objectName,
      List<String> readGaps,
      List<String> createGaps
    ) {
      if (!readGaps.isEmpty()) {
        String finding =
          'This user cannot read: ' +
          String.join(readGaps, ', ') +
          '. User-mode queries on these items fail with "No such column".';
        if (!createGaps.isEmpty()) {
          finding +=
            ' This user also cannot create: ' +
            String.join(createGaps, ', ') +
            '.';
        }
        return row(
          STATUS_FAIL,
          finding,
          'Assign Revenant_Admin to this user: ' +
            ADMIN_PATH +
            '. Or grant read access to the listed items.'
        );
      }
      if (!createGaps.isEmpty()) {
        return row(
          STATUS_WARN,
          'This user can read but cannot create: ' +
            String.join(createGaps, ', ') +
            '. Users that start workflows need create access.',
          'Assign Revenant_Admin to users that start workflows: ' +
            ADMIN_PATH +
            '. A read-only operator (Revenant_Operator) does not need create access.'
        );
      }
      return pass(
        'This user can read and create ' +
          objectName +
          ' and its engine fields.'
      );
    }
  }
}
