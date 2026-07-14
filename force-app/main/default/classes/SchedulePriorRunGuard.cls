/**
 * Overlap / blocked-prefix concurrency guard lifted out of WorkflowScheduleSweeper
 * to keep that class under its complexity budget.
 *
 * A Skip-policy schedule must not start a new instance while a prior run from a
 * DIFFERENT window is still in flight. This class answers that question two ways:
 *   - computeBlockedPrefixes: bulk, one coarse query for the whole 0-slot sweep.
 *   - hasActivePriorRun: single-schedule, for the dedicated-slot fire path.
 *
 * Both use a coarse `LIKE prefix + '_%'` pre-filter and then an EXACT
 * case-insensitive `startsWith(prefix + '_')` check in Apex, so an unrelated key
 * such as "JobManual_..." can never falsely block the "Job" schedule and
 * admin-entered `%`/`_` wildcards in a prefix cannot widen the match. All SOQL
 * and comparison logic is byte-identical to the original sweeper helpers.
 */
public inherited sharing class SchedulePriorRunGuard {
  /**
   * @description For all Skip-policy due items, returns the set of prefixes that currently have
   * an ACTIVE instance from a DIFFERENT window (i.e. a prior run still in flight).
   *
   * Uses a single dynamic query (coarse LIKE per prefix) and then an EXACT
   * `startsWith(prefix + '_')` filter in Apex, so an unrelated key such as
   * "JobManual_..." can never falsely block the "Job" schedule, and admin-entered
   * `%`/`_` wildcards in a prefix cannot widen the match.
   * @param skipCorrKeyByPrefix The Skip-policy prefixes mapped to the current window's
   * correlation key for each, which is excluded from the prior-run match.
   * @return The set of Skip-policy prefixes blocked by an active prior run.
   */
  public static Set<String> computeBlockedPrefixes(
    Map<String, String> skipCorrKeyByPrefix
  ) {
    if (skipCorrKeyByPrefix.isEmpty()) {
      return new Set<String>();
    }

    Map<String, Object> binds = new Map<String, Object>();
    String soql = buildActivePriorRunQuery(skipCorrKeyByPrefix.keySet(), binds);
    List<Workflow_Instance__c> active = Database.queryWithBinds(
      soql,
      binds,
      AccessLevel.SYSTEM_MODE
    );

    return collectBlockedPrefixes(active, skipCorrKeyByPrefix);
  }

  /**
   * @description Builds the coarse LIKE-per-prefix query for in-flight instances, populating the
   * bind map. The exact startsWith filter in collectBlockedPrefixes guarantees
   * correctness, so this pre-filter can be broad.
   * @param prefixes The Skip-policy prefixes to match against active instances.
   * @param binds The bind map populated with one LIKE pattern per prefix.
   * @return The dynamic SOQL string querying active instances by prefix.
   */
  private static String buildActivePriorRunQuery(
    Set<String> prefixes,
    Map<String, Object> binds
  ) {
    List<String> ors = new List<String>();
    Integer i = 0;
    for (String prefix : prefixes) {
      String key = 'p' + i;
      binds.put(key, prefix + '_%');
      ors.add('Correlation_Key__c LIKE :' + key);
      i++;
    }
    return 'SELECT Correlation_Key__c FROM Workflow_Instance__c ' +
      'WHERE Active_Correlation_Key__c != null AND (' +
      String.join(ors, ' OR ') +
      ')';
  }

  /**
   * @description From the coarse query result, returns the set of Skip prefixes that have an
   * ACTIVE instance from a DIFFERENT window (a prior run still in flight). Prefixes/
   * keys are compared case-insensitively (the prefix field is caseSensitive=false and
   * SOQL LIKE ignores case) so an admin re-casing a prefix still recognises a prior run.
   * @param active The active instances returned by the coarse prefix query.
   * @param skipCorrKeyByPrefix The Skip-policy prefixes mapped to the current window's
   * correlation key for each, which is excluded from the prior-run match.
   * @return The set of prefixes with an active prior run from a different window.
   */
  private static Set<String> collectBlockedPrefixes(
    List<Workflow_Instance__c> active,
    Map<String, String> skipCorrKeyByPrefix
  ) {
    Set<String> blocked = new Set<String>();
    for (Workflow_Instance__c inst : active) {
      if (inst.Correlation_Key__c == null) {
        continue;
      }
      String lcKey = inst.Correlation_Key__c.toLowerCase();
      for (String prefix : skipCorrKeyByPrefix.keySet()) {
        if (
          lcKey.startsWith(prefix.toLowerCase() + '_') &&
          inst.Correlation_Key__c != skipCorrKeyByPrefix.get(prefix)
        ) {
          blocked.add(prefix);
        }
      }
    }
    return blocked;
  }

  /**
   * @description Single-schedule overlap check (case-insensitive): is there an ACTIVE instance
   * whose correlation key shares this prefix but is from a different window?
   * @param prefix The correlation-key prefix identifying the schedule.
   * @param currentCorrKey The current window's correlation key, excluded from the match.
   * @return True when an active instance from a different window shares the prefix.
   */
  public static Boolean hasActivePriorRun(
    String prefix,
    String currentCorrKey
  ) {
    String likePattern = prefix + '_%';
    List<Workflow_Instance__c> active = [
      SELECT Correlation_Key__c
      FROM Workflow_Instance__c
      WHERE
        Active_Correlation_Key__c != NULL
        AND Correlation_Key__c LIKE :likePattern
      WITH SYSTEM_MODE
    ];
    String lcPrefix = prefix.toLowerCase();
    for (Workflow_Instance__c inst : active) {
      if (inst.Correlation_Key__c == null) {
        continue;
      }
      if (
        inst.Correlation_Key__c.toLowerCase().startsWith(lcPrefix + '_') &&
        inst.Correlation_Key__c != currentCorrKey
      ) {
        return true;
      }
    }
    return false;
  }

  /**
   * @description Truncates a DateTime to the start of its minute in UTC (seconds = 0).
   * @param dt The DateTime to truncate.
   * @return The same instant with seconds zeroed, in UTC.
   */
  public static DateTime truncateToMinute(DateTime dt) {
    return DateTime.newInstanceGmt(
      dt.yearGmt(),
      dt.monthGmt(),
      dt.dayGmt(),
      dt.hourGmt(),
      dt.minuteGmt(),
      0
    );
  }
}
