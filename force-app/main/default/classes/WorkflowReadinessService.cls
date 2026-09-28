/**
 * @description Reads the install readiness checks for System Doctor (#114).
 * RED stub: returns no checks.
 */
public inherited sharing class WorkflowReadinessService {
  public static final String STATUS_PASS = 'Pass';
  public static final String STATUS_WARN = 'Warn';
  public static final String STATUS_FAIL = 'Fail';

  @TestVisible
  private static Probe probe = new Probe();

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
      return null;
    }

    /**
     * @description The Default Workflow_Alert_Config__mdt record, or null.
     * @return The record, or null.
     */
    public virtual Workflow_Alert_Config__mdt defaultAlertConfig() {
      return null;
    }

    /**
     * @description The status of WorkflowEventTrigger, or null when not found.
     * @return 'Active', 'Inactive', 'Deleted' or null.
     */
    public virtual String eventTriggerStatus() {
      return null;
    }

    /**
     * @description True when the watchdog chain runs.
     * @return True when running.
     */
    public virtual Boolean watchdogRunning() {
      return null;
    }

    /**
     * @description True when the running user can read the object.
     * @param objectType The object.
     * @return True when readable.
     */
    public virtual Boolean canRead(Schema.SObjectType objectType) {
      return null;
    }

    /**
     * @description True when the running user can create the object.
     * @param objectType The object.
     * @return True when creatable.
     */
    public virtual Boolean canCreate(Schema.SObjectType objectType) {
      return null;
    }

    /**
     * @description True when the running user can read the field.
     * @param field The field.
     * @return True when readable.
     */
    public virtual Boolean canRead(Schema.SObjectField field) {
      return null;
    }

    /**
     * @description True when the running user can set the field on create.
     * @param field The field.
     * @return True when creatable.
     */
    public virtual Boolean canCreate(Schema.SObjectField field) {
      return null;
    }
  }

  /**
   * @description Runs all readiness checks.
   * @return One row per check.
   */
  public static List<ReadinessCheck> runChecks() {
    return new List<ReadinessCheck>();
  }
}
