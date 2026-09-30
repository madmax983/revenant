/**
 * @description The one active/failed/suspended mapping of workflow statuses (#54, #225).
 * The Workflow Catalog and the dashboard stat tiles both use it, so the two health views
 * agree. Pure: no SOQL, no DML. Statuses with no bucket (Completed, ContinuedAsNew,
 * Compensated, Cancelled) return null.
 */
public inherited sharing class WorkflowHealthBuckets {
  public static final String ACTIVE = 'active';
  public static final String FAILED = 'failed';
  public static final String SUSPENDED = 'suspended';

  private static final String SUSPENDED_STATUS = 'Suspended';

  private static final Set<String> ACTIVE_STATUSES = new Set<String>{
    'Pending',
    'Running',
    'Compensating',
    'Cancelling',
    'Paused',
    'DefinitionChanged',
    'Held'
  };

  private static final Set<String> FAILED_STATUSES = new Set<String>{
    'Failed',
    'CompensationFailed'
  };

  /**
   * @description Every status that has a bucket. Use it to bound health queries.
   */
  public static final Set<String> HEALTH_STATUSES = buildHealthStatuses();

  /**
   * @description Returns the bucket of a status.
   * @param status The workflow instance status.
   * @return active, failed or suspended; null when the status has no bucket.
   */
  public static String bucketOf(String status) {
    if (ACTIVE_STATUSES.contains(status)) {
      return ACTIVE;
    }
    if (FAILED_STATUSES.contains(status)) {
      return FAILED;
    }
    return status == SUSPENDED_STATUS ? SUSPENDED : null;
  }

  private static Set<String> buildHealthStatuses() {
    Set<String> all = new Set<String>(ACTIVE_STATUSES);
    all.addAll(FAILED_STATUSES);
    all.add(SUSPENDED_STATUS);
    return all;
  }
}
