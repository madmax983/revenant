/**
 * @description Per-step scheduling-metadata lookups for the Revenant engine.
 * Resolves (and transaction-caches) a step's configured timeout in seconds by
 * instantiating the step type and reading its {@link TimeoutConfigurable}
 * contract, and derives the deterministic sleep-job name prefix used to locate
 * or abort a step's sleep cron job without storing its Id. Extracted from
 * `WorkflowEngine`; pure/read-only (no DML). Consumed by the timeout scheduler,
 * the resume re-arm path and the sleep/retry rescheduler.
 */
public inherited sharing class WorkflowStepTimeoutConfig {
  private static Map<String, Integer> stepTimeoutCache = new Map<String, Integer>();

  /**
   * @description Resolves the configured timeout (seconds) for a step, caching
   * the result per transaction. Returns null when the step declares no timeout,
   * is blank, or its type is not instantiable here.
   * @param stepName the step name (optionally `_Compensate`-suffixed)
   * @param contextNamespace the workflow namespace used to resolve the step type
   * @return the configured positive timeout in seconds, or null when unset
   */
  public static Integer getStepTimeoutSeconds(
    String stepName,
    String contextNamespace
  ) {
    if (String.isBlank(stepName)) {
      return null;
    }
    String cacheKey = (stepName +
      (String.isNotBlank(contextNamespace) ? ('|' + contextNamespace) : ''))
      .toLowerCase();
    if (stepTimeoutCache.containsKey(cacheKey)) {
      return stepTimeoutCache.get(cacheKey);
    }
    String className = stepName.endsWith('_Compensate')
      ? stepName.substring(0, stepName.lastIndexOf('_Compensate'))
      : stepName;
    Integer timeout = null;
    try {
      Type stepType = WorkflowTypeResolver.resolve(className, contextNamespace);
      if (stepType != null) {
        Object stepObj = stepType.newInstance();
        if (stepObj instanceof TimeoutConfigurable) {
          timeout = ((TimeoutConfigurable) stepObj).getTimeoutSeconds();
        }
      }
    } catch (Exception ignored) {
      // Step type may not be instantiable here; leave timeout unset.
    }
    stepTimeoutCache.put(cacheKey, timeout);
    return timeout;
  }

  /**
   * @description Builds the deterministic cron job name prefix for an instance and
   * step's sleep job, so the job can be located or aborted without storing its Id.
   * @param instanceId Id of the instance the sleep job belongs to
   * @param stepName name of the sleeping step
   * @return the sleep job name prefix
   */
  public static String getSleepJobPrefix(Id instanceId, String stepName) {
    String cleanStepName = String.isNotBlank(stepName)
      ? stepName.replaceAll('[^a-zA-Z0-9]', '_')
      : '';
    if (cleanStepName.length() > 25) {
      cleanStepName =
        cleanStepName.substring(0, 15) +
        '_' +
        Math.abs(cleanStepName.hashCode());
    }
    return 'WorkflowSleep_' +
      instanceId +
      (String.isNotBlank(cleanStepName) ? '_' + cleanStepName : '');
  }
}
