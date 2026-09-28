/**
 * @description Resolves the effective retry policy of a step from
 * `Workflow_Retry_Config__mdt` (issue #103). An operator changes the policy in
 * Setup. No deploy is necessary.
 *
 * Resolution:
 * 1. Start with the author policy, else the engine default. The values of a
 *    `RetryPolicy.fromConfig()` policy are a start value, not an author policy.
 * 2. With no author policy, put the most specific record over it.
 * 3. Put the most specific override record over the result.
 *
 * "Most specific" is the step record, else the definition record (blank step
 * name). The match ignores case and outer spaces. For two records with the
 * same key, the lowest DeveloperName wins. A blank or bad record field keeps
 * the value below it. The resolver always sanitizes the result.
 *
 * Reads use `getAll()`, which uses no SOQL. The resolver does no DML. Apex
 * tests ignore org records unless a test sets `readOrgRecordsInTest`, so an
 * incident record cannot block a deploy.
 */
public inherited sharing class WorkflowRetryConfigResolver {
  private static final String KEY_SEPARATOR = '\n';
  private static final String OVERRIDE_PREFIX = 'override' + KEY_SEPARATOR;

  // Test records. When set, they replace getAll() fully and are not cached.
  @TestVisible
  private static List<Workflow_Retry_Config__mdt> mockRecords;

  // True lets a test read the org records through getAll().
  @TestVisible
  private static Boolean readOrgRecordsInTest = false;

  // Index for one transaction. A new transaction reads the metadata cache
  // again, so a record change applies to the next retry outcome.
  private static Map<String, Workflow_Retry_Config__mdt> cachedIndex;

  /**
   * @description Returns the effective retry policy for a retry outcome.
   * @param workflowName The workflow API name (`Workflow_Name__c`).
   * @param stepName The step name (`Step_Name__c`).
   * @param policy The author policy. Null or `RetryPolicy.fromConfig()` means
   * no author policy.
   * @return The sanitized effective policy.
   */
  public static RetryPolicy resolve(
    String workflowName,
    String stepName,
    RetryPolicy policy
  ) {
    RetryPolicy effective = WorkflowRetryScheduling.sanitizePolicy(policy);
    Boolean hasAuthorPolicy = policy != null && !policy.isFromConfig();
    if (!hasAuthorPolicy) {
      applyConfig(effective, findConfig(workflowName, stepName, ''));
    }
    applyConfig(effective, findConfig(workflowName, stepName, OVERRIDE_PREFIX));
    return effective;
  }

  /**
   * @description Returns the attempt cap of an override record, for
   * `ctx.isFinalAttempt()`. Other records do not change the value.
   * @param workflowName The workflow API name (`Workflow_Name__c`).
   * @param stepName The step name (`Step_Name__c`).
   * @param current The max attempts that the context has now.
   * @return The override cap, or `current` when no override cap applies.
   */
  public static Integer overrideMaxAttempts(
    String workflowName,
    String stepName,
    Integer current
  ) {
    Workflow_Retry_Config__mdt config = findConfig(
      workflowName,
      stepName,
      OVERRIDE_PREFIX
    );
    if (config == null || !isValidCount(config.Maximum_Attempts__c)) {
      return current;
    }
    return config.Maximum_Attempts__c.intValue();
  }

  // Step record first, then the definition record. The prefix selects all
  // records ('') or override records only.
  private static Workflow_Retry_Config__mdt findConfig(
    String workflowName,
    String stepName,
    String prefix
  ) {
    if (String.isBlank(workflowName)) {
      return null;
    }
    Map<String, Workflow_Retry_Config__mdt> index = getIndex();
    if (index.isEmpty()) {
      return null;
    }
    Workflow_Retry_Config__mdt config = null;
    if (String.isNotBlank(stepName)) {
      config = index.get(prefix + key(workflowName, stepName));
    }
    if (config == null) {
      config = index.get(prefix + key(workflowName, null));
    }
    return config;
  }

  // Puts each valid record field over the base policy.
  private static void applyConfig(
    RetryPolicy base,
    Workflow_Retry_Config__mdt config
  ) {
    if (config == null) {
      return;
    }
    if (isValidCount(config.Initial_Interval_Seconds__c)) {
      base.initialIntervalSeconds = config.Initial_Interval_Seconds__c.intValue();
    }
    if (
      config.Backoff_Coefficient__c != null &&
      config.Backoff_Coefficient__c >= 1
    ) {
      base.backoffCoefficient = config.Backoff_Coefficient__c.doubleValue();
    }
    if (isValidCount(config.Maximum_Attempts__c)) {
      base.maximumAttempts = config.Maximum_Attempts__c.intValue();
    }
  }

  // A count field is valid when its whole-number part is 1 or more.
  private static Boolean isValidCount(Decimal value) {
    return value != null && value.intValue() >= 1;
  }

  private static String key(String workflowName, String stepName) {
    return normalize(workflowName) + KEY_SEPARATOR + normalize(stepName);
  }

  private static String normalize(String value) {
    return String.isBlank(value) ? '' : value.trim().toLowerCase();
  }

  private static Map<String, Workflow_Retry_Config__mdt> getIndex() {
    if (mockRecords != null) {
      return buildIndex(mockRecords);
    }
    if (Test.isRunningTest() && !readOrgRecordsInTest) {
      return new Map<String, Workflow_Retry_Config__mdt>();
    }
    if (cachedIndex == null) {
      cachedIndex = buildIndex(Workflow_Retry_Config__mdt.getAll().values());
    }
    return cachedIndex;
  }

  // Keys each record by workflow and step. An override record also goes under
  // OVERRIDE_PREFIX. For a duplicate key, the lowest DeveloperName wins, so
  // the result does not depend on the read order.
  private static Map<String, Workflow_Retry_Config__mdt> buildIndex(
    List<Workflow_Retry_Config__mdt> records
  ) {
    Map<String, Workflow_Retry_Config__mdt> index = new Map<String, Workflow_Retry_Config__mdt>();
    for (Workflow_Retry_Config__mdt record : records) {
      if (String.isBlank(record.Workflow_Definition__c)) {
        continue;
      }
      String recordKey = key(
        record.Workflow_Definition__c,
        record.Step_Name__c
      );
      putLowest(index, recordKey, record);
      if (record.Override_Author_Policy__c == true) {
        putLowest(index, OVERRIDE_PREFIX + recordKey, record);
      }
    }
    return index;
  }

  private static void putLowest(
    Map<String, Workflow_Retry_Config__mdt> index,
    String recordKey,
    Workflow_Retry_Config__mdt record
  ) {
    Workflow_Retry_Config__mdt existing = index.get(recordKey);
    if (
      existing == null ||
      record.DeveloperName.compareTo(existing.DeveloperName) < 0
    ) {
      index.put(recordKey, record);
    }
  }
}
