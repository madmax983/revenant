/**
 * @description One row of the Readiness panel in System Doctor (#114). It is a top-level
 * class because the LWC reads it from an @AuraEnabled return value.
 */
public inherited sharing class WorkflowReadinessCheck {
  /** @description Stable key of the check, for example engineConfig. */
  @AuraEnabled
  public String key;
  /** @description Display name of the check. */
  @AuraEnabled
  public String name;
  /** @description Pass, Warn or Fail. */
  @AuraEnabled
  public String status;
  /** @description What the check found. */
  @AuraEnabled
  public String finding;
  /** @description The fix for Warn and Fail. Null for Pass. */
  @AuraEnabled
  public String remediation;
}
