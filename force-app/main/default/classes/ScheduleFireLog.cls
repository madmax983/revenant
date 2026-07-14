/**
 * Builds the Workflow_Log__c audit row for a single schedule fire.
 *
 * Lifted out of WorkflowScheduleSweeper (as its LogSpec value object + buildLog
 * helper) so the 0-slot sweep pipeline, the dedicated-slot fire path, and manual
 * runs all assemble the exact same audit row through one place and cannot drift.
 * The persisting DML (upsert on the Fire_Key__c external id) stays with each
 * caller so its as-system mode and batching are preserved byte-for-byte.
 */
public inherited sharing class ScheduleFireLog {
  private static final String LOG_TYPE = 'ScheduleFire';
  private static final String LEVEL_INFO = 'Info';

  /**
   * Assembles the fields of one fire's audit log. Bundled into a single value
   * object so build() needs no long parameter list. logType null → 'ScheduleFire'.
   * Public so every schedule fire path can populate it across class boundaries.
   */
  public class Spec {
    /** @description The schedule this fire belongs to. */
    public Workflow_Schedule__c sched;
    /** @description The correlation key for this fire's window. */
    public String corrKey;
    /** @description The window instant this fire corresponds to. */
    public DateTime fireTime;
    /** @description The log type; null falls back to 'ScheduleFire'. */
    public String logType;
    /** @description The recorded outcome (Started, Skipped, Error, Deduped). */
    public String outcome;
    /** @description The started workflow instance Id, when one was started. */
    public Id instanceId;
    /** @description The audit message detail. */
    public String message;
  }

  /**
   * @description Builds the in-memory Workflow_Log__c audit row for a fire from its spec.
   * @param spec The assembled fields describing the fire to log.
   * @return The unsaved Workflow_Log__c row keyed by Fire_Key__c for upsert.
   */
  public static Workflow_Log__c build(Spec spec) {
    return new Workflow_Log__c(
      Fire_Key__c = spec.corrKey + ':' + spec.outcome,
      Log_Type__c = String.isNotBlank(spec.logType) ? spec.logType : LOG_TYPE,
      Level__c = LEVEL_INFO,
      Outcome__c = spec.outcome,
      Schedule__c = spec.sched.Id,
      Schedule_Name__c = spec.sched.Name,
      Workflow_Name__c = spec.sched.Workflow_Name__c,
      Correlation_Key__c = spec.corrKey,
      Fire_Time__c = spec.fireTime,
      Workflow_Instance__c = spec.instanceId,
      Message__c = spec.message
    );
  }
}
