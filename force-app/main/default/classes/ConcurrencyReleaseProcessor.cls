/**
 * ConcurrencyReleaseProcessor — decrements `Concurrency_State__c` counter rows when
 * instances reach a terminal transition, lifted out of `ConcurrencyGate` (issue #28)
 * to keep the admission gate below the class-level complexity thresholds.
 *
 * The release discipline is unchanged: each existing counter row is locked once
 * `SELECT ... FOR UPDATE` and decremented (floored at zero), with the requested
 * per-workflow counts folded into a case-normalized map so a differently-cased key
 * cannot silently skip a decrement and leak a slot. The public `release` /
 * `releaseBulk` entry points remain on `ConcurrencyGate` as thin delegators into this
 * class's single entry.
 */
public inherited sharing class ConcurrencyReleaseProcessor {
  /**
   * @description Bulk release keyed by workflow definition to number of slots to free. Locks
   * each existing counter row once and decrements (floored at zero). Called (via the gate)
   * from the instance trigger so many concurrent terminal transitions decrement correctly.
   * @param countsByWorkflow Map of workflow definition name to the number of slots to free.
   */
  public static void releaseBulk(Map<String, Integer> countsByWorkflow) {
    if (countsByWorkflow == null || countsByWorkflow.isEmpty()) {
      return;
    }
    Set<String> keys = countsByWorkflow.keySet();
    // Workflow_Definition__c is a case-insensitive unique field, so the SOQL below
    // matches a state row regardless of the casing the terminal instance was started
    // with. Apex Map lookups are case-sensitive, though, so a differently-cased key
    // would miss the count and silently skip the decrement (leaking a slot). Fold the
    // requested counts into a case-normalized map and look up by the same normalization.
    Map<String, Integer> normalizedCounts = normalizeCounts(countsByWorkflow);
    List<Concurrency_State__c> states = [
      SELECT Workflow_Definition__c, In_Flight_Count__c
      FROM Concurrency_State__c
      WHERE Workflow_Definition__c IN :keys
      WITH SYSTEM_MODE
      FOR UPDATE
    ];
    List<Concurrency_State__c> toUpdate = applyRelease(
      states,
      normalizedCounts
    );
    if (!toUpdate.isEmpty()) {
      update as system toUpdate;
    }
  }

  // Folds the requested per-workflow release counts into a case-normalized (lower-cased)
  // map, summing counts whose keys differ only by casing and skipping null counts.
  private static Map<String, Integer> normalizeCounts(
    Map<String, Integer> countsByWorkflow
  ) {
    Map<String, Integer> normalizedCounts = new Map<String, Integer>();
    for (String key : countsByWorkflow.keySet()) {
      Integer c = countsByWorkflow.get(key);
      if (c == null) {
        continue;
      }
      String nk = key.toLowerCase();
      normalizedCounts.put(
        nk,
        (normalizedCounts.containsKey(nk) ? normalizedCounts.get(nk) : 0) + c
      );
    }
    return normalizedCounts;
  }

  // Decrements each locked counter row by its normalized release count, floored at zero,
  // returning the rows that should be updated.
  private static List<Concurrency_State__c> applyRelease(
    List<Concurrency_State__c> states,
    Map<String, Integer> normalizedCounts
  ) {
    List<Concurrency_State__c> toUpdate = new List<Concurrency_State__c>();
    for (Concurrency_State__c state : states) {
      Integer current = (state.In_Flight_Count__c == null)
        ? 0
        : (Integer) state.In_Flight_Count__c;
      Integer dec = normalizedCounts.get(
        state.Workflow_Definition__c.toLowerCase()
      );
      Integer next = current - (dec == null ? 0 : dec);
      state.In_Flight_Count__c = next < 0 ? 0 : next;
      toUpdate.add(state);
    }
    return toUpdate;
  }
}
