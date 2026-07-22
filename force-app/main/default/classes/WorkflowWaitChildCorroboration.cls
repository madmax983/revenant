/**
 * @description Read-time corroboration for a plural START_CHILDREN wait descriptor (issue #84),
 * used by {@link WorkflowWaitDescriptorService} on its single-row detail path.
 *
 * <p>A parked parent's bulk-child state persists only {@code {"childCorrelationKeys":[...]}} — the
 * engine (WorkflowStepSuspension.handleStartChildrenOutcome) writes NO in-state companion marker
 * for the plural join, so the mere presence of that array cannot distinguish a REAL bulk-child
 * join from opaque author state that happens to carry a {@code childCorrelationKeys} array. A stray
 * {@code ChildCompleted:<key>} suggestion would not unblock such a generic wait, so before labeling
 * the state a child-completion wait this helper CORROBORATES it against the engine's own
 * parent→child linkage: the parked parent must actually have spawned a child whose
 * {@code Correlation_Key__c} matches one of the awaited keys.
 *
 * <p>The single-child START_CHILD state ({@code {"childWorkflowName":...,"childCorrelationKey":...}})
 * already carries the {@code childWorkflowName} companion marker WorkflowStepSuspension writes, so
 * it is self-corroborating and needs no query.
 *
 * <p>{@code Parent_Instance__c} is written by WorkflowChildBulkPlanner and is an indexed lookup, so
 * the corroboration query is selective and BOUNDED — keyed by the single parent id with an explicit
 * {@code LIMIT} cap, never a scan of the child table by the awaited key list, so it stays bounded
 * regardless of how many keys the state holds. Key comparison mirrors WorkflowSignalChildGate /
 * WorkflowSignalGating exactly ({@link WorkflowKeys#normalizeKey}, i.e. lower-cased, null-safe) on
 * both the awaited keys and the child {@code Correlation_Key__c}. The one SOQL runs WITH SYSTEM_MODE
 * and this helper issues no DML.
 */
public inherited sharing class WorkflowWaitChildCorroboration {
  // Bounds the parent→child lookup regardless of fan-out. The query is keyed by the indexed
  // Parent_Instance__c so it is selective; the cap is a defensive ceiling on a pathological fan-out.
  private static final Integer CHILD_LOOKUP_CAP = 2000;

  /**
   * @description Decides whether a parked child-wait state is a GENUINE child-completion wait.
   * The single-child START_CHILD marker ({@code childWorkflowName} + {@code childCorrelationKey})
   * is self-corroborating and returns true with no query. A plural {@code childCorrelationKeys}
   * state is corroborated against the parent's real spawned children.
   * @param state the parsed, rehydrated parked-step state
   * @param instanceId the parked parent instance id (in hand on the detail path)
   * @return true when this is a real child-completion wait; false when it should degrade to generic
   */
  public static Boolean isGenuineChildWait(
    Map<String, Object> state,
    Id instanceId
  ) {
    if (
      String.isNotBlank(readString(state, 'childCorrelationKey')) &&
      String.isNotBlank(readString(state, 'childWorkflowName'))
    ) {
      return true;
    }
    return hasCorroboratingChild(instanceId, normalizedExpectedKeys(state));
  }

  // True when the parent really spawned a child whose (normalized) Correlation_Key__c is one of the
  // (normalized) awaited keys. Bounded, read-only, single query keyed by the indexed parent lookup.
  private static Boolean hasCorroboratingChild(
    Id instanceId,
    Set<String> expectedKeys
  ) {
    if (instanceId == null || expectedKeys.isEmpty()) {
      return false;
    }
    for (Workflow_Instance__c child : [
      SELECT Correlation_Key__c, Status__c
      FROM Workflow_Instance__c
      WHERE Parent_Instance__c = :instanceId
      WITH SYSTEM_MODE
      LIMIT :CHILD_LOOKUP_CAP
    ]) {
      if (
        String.isNotBlank(child.Correlation_Key__c) &&
        expectedKeys.contains(
          WorkflowKeys.normalizeKey(child.Correlation_Key__c)
        )
      ) {
        return true;
      }
    }
    return false;
  }

  // Extracts and normalizes the awaited plural childCorrelationKeys (mirroring the engine's
  // WorkflowKeys.normalizeKey so the intersection matches WorkflowSignalChildGate semantics).
  private static Set<String> normalizedExpectedKeys(Map<String, Object> state) {
    Set<String> keys = new Set<String>();
    Object raw = state.get('childCorrelationKeys');
    if (raw instanceof List<Object>) {
      for (Object k : (List<Object>) raw) {
        if (k != null) {
          keys.add(WorkflowKeys.normalizeKey(String.valueOf(k)));
        }
      }
    }
    return keys;
  }

  // Reads a string value from the parsed state, or null when absent.
  private static String readString(Map<String, Object> state, String key) {
    Object v = state.get(key);
    return v == null ? null : String.valueOf(v);
  }
}
