/**
 * @description Step-history guard (issue #112). RED stub.
 */
public inherited sharing class WorkflowStepHistoryGuard {
  /** @description Log_Type__c of the warning row. */
  public static final String LOG_TYPE = 'StepHistoryWarning';

  /** @description Default warn threshold (rows). */
  public static final Integer DEFAULT_WARN = 5000;

  /** @description Default ceiling (rows). */
  public static final Integer DEFAULT_CEILING = 10000;

  /** @description Highest value the engine accepts for a threshold. */
  public static final Integer MAX_THRESHOLD = 10000;

  /** @description Result of a history check. */
  public enum Verdict {
    OK,
    WARN,
    HALT
  }

  /** @description Effective thresholds. 0 means the check is off. */
  public class Thresholds {
    public Integer warn;
    public Integer ceiling;

    /**
     * @description Makes a threshold pair.
     * @param warn Warn threshold, or 0.
     * @param ceiling Ceiling, or 0.
     */
    public Thresholds(Integer warn, Integer ceiling) {
      this.warn = warn;
      this.ceiling = ceiling;
    }
  }

  /**
   * @description Stub.
   * @param warnRaw Configured warn value.
   * @param ceilingRaw Configured ceiling value.
   * @return Thresholds.
   */
  public static Thresholds resolve(Integer warnRaw, Integer ceilingRaw) {
    return new Thresholds(0, 0);
  }

  /**
   * @description Stub.
   * @param count Row count.
   * @param t Thresholds.
   * @return Verdict.
   */
  public static Verdict evaluate(Integer count, Thresholds t) {
    return Verdict.OK;
  }

  /**
   * @description Stub.
   * @param workflowName Workflow name.
   * @return False.
   */
  public static Boolean isExempt(String workflowName) {
    return false;
  }

  /**
   * @description Stub.
   * @param ctx Run context.
   * @return False.
   */
  public static Boolean check(WorkflowStepRunner.RunStepContext ctx) {
    return false;
  }

  /**
   * @description Stub.
   * @param ctx Run context.
   */
  public static void recordWarning(WorkflowStepRunner.RunStepContext ctx) {
    return;
  }

  /**
   * @description Stub.
   * @param instanceId Instance Id.
   * @return Key.
   */
  public static String fireKey(Id instanceId) {
    return null;
  }

  /**
   * @description Stub.
   * @param instanceIds Instance Ids.
   * @return Empty set.
   */
  public static Set<Id> warnedInstanceIds(Set<Id> instanceIds) {
    return new Set<Id>();
  }

  /**
   * @description Stub.
   * @param instanceId Instance Id.
   * @return Null.
   */
  public static Map<String, Object> describeWarning(Id instanceId) {
    return null;
  }
}
