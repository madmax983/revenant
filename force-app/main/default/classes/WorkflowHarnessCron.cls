/**
 * Test-only CronTrigger lookups for the WorkflowTestHarness. Fetching all matching
 * job names once (up front) and matching prefixes in memory keeps the harness from
 * issuing SOQL inside its per-instance / per-step loops.
 */
@IsTest
public inherited sharing class WorkflowHarnessCron {
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

  public static Boolean anyStartsWith(List<String> names, String prefix) {
    for (String name : names) {
      if (name != null && name.startsWith(prefix)) {
        return true;
      }
    }
    return false;
  }
}
