/**
 * Test-only CronTrigger lookups for the WorkflowTestHarness. Fetching all matching
 * job names once (up front) and matching prefixes in memory keeps the harness from
 * issuing SOQL inside its per-instance / per-step loops.
 */
@IsTest
public inherited sharing class WorkflowHarnessCron {
  /**
   * @description Returns the names of all CronJobDetail records whose name matches
   * the given SOQL LIKE pattern, fetched once so the harness avoids SOQL inside its
   * per-instance and per-step loops.
   * @param pattern The SOQL LIKE pattern to match against CronJobDetail.Name.
   * @return The matching cron job names.
   */
  public static List<String> namesLike(String pattern) {
    List<String> names = new List<String>();
    for (CronTrigger ct : [
      SELECT CronJobDetail.Name
      FROM CronTrigger
      WHERE CronJobDetail.Name LIKE :pattern
      WITH SYSTEM_MODE
    ]) {
      names.add(ct.CronJobDetail.Name);
    }
    return names;
  }

  /**
   * @description Tests in memory whether any of the previously fetched cron job
   * names begins with the given prefix.
   * @param names The cron job names to scan.
   * @param prefix The prefix to look for.
   * @return True if at least one name starts with the prefix; false otherwise.
   */
  public static Boolean anyStartsWith(List<String> names, String prefix) {
    for (String name : names) {
      if (name != null && name.startsWith(prefix)) {
        return true;
      }
    }
    return false;
  }
}
