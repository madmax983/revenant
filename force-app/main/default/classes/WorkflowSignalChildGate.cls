/**
 * @description Child-completion evaluation for the durable-execution engine's
 * parallel-join gating. A suspended parent that spawned child workflows tracks
 * the expected child correlation keys in its pending step's output; this class
 * extracts those expected keys, determines which expected children have finished
 * (reached a non-active status), and decides whether the only signals awaiting a
 * still-gated parent are child completion/failure signals. `WorkflowSignalGating`
 * uses these to decide whether a parent may wake. Stateless; no DML or SOQL.
 */
public inherited sharing class WorkflowSignalChildGate {
  /**
   * @description Extracts the normalized set of expected child correlation keys
   * from a resolved pending-step output payload. Returns null when the payload
   * cannot be parsed or does not carry a childCorrelationKeys list, signalling
   * that the parent should be treated as ready (not gated).
   * @param resolvedOutput the resolved step output JSON
   * @return normalized expected child keys, or null when absent/unparseable
   */
  public static Set<String> extractExpectedChildKeys(String resolvedOutput) {
    try {
      Map<String, Object> data = (Map<String, Object>) JSON.deserializeUntyped(
        resolvedOutput
      );
      if (!data.containsKey('childCorrelationKeys')) {
        return null;
      }
      List<Object> keysObj = (List<Object>) data.get('childCorrelationKeys');
      if (keysObj == null) {
        return null;
      }
      Set<String> expectedKeys = new Set<String>();
      for (Object o : keysObj) {
        if (o != null) {
          expectedKeys.add(WorkflowKeys.normalizeKey(String.valueOf(o)));
        }
      }
      return expectedKeys;
    } catch (Exception ignored) {
      // If JSON parse fails or does not contain childCorrelationKeys, treat as ready
      return null;
    }
  }

  /**
   * @description Collects the normalized correlation keys of children that have
   * reached a non-active (finished) status and are among the expected keys.
   * @param children the child instances of a gated parent (may be null)
   * @param expectedKeys the expected child correlation keys to match against
   * @return the subset of expected keys whose child has finished
   */
  public static Set<String> collectFinishedChildKeys(
    List<Workflow_Instance__c> children,
    Set<String> expectedKeys
  ) {
    Set<String> finishedKeys = new Set<String>();
    if (children == null) {
      return finishedKeys;
    }
    for (Workflow_Instance__c child : children) {
      if (String.isNotBlank(child.Correlation_Key__c)) {
        String normChildKey = WorkflowKeys.normalizeKey(
          child.Correlation_Key__c
        );
        if (
          expectedKeys.contains(normChildKey) &&
          child.Status__c != null &&
          !WorkflowEngine.ACTIVE_STATUSES.contains(child.Status__c)
        ) {
          finishedKeys.add(normChildKey);
        }
      }
    }
    return finishedKeys;
  }

  /**
   * @description Determines whether every signal awaiting a non-ready parent is
   * a child-completion/failure signal, meaning the parent is genuinely gated on
   * outstanding children rather than an unrelated inbound signal.
   * @param sigNames the signal names pending for the parent (may be null)
   * @return true when all pending signals are child completion/failure signals
   */
  public static Boolean isAllChildSignals(Set<String> sigNames) {
    if (sigNames == null) {
      return true;
    }
    for (String name : sigNames) {
      if (String.isNotBlank(name)) {
        String lower = name.toLowerCase();
        if (
          !lower.startsWith('childcompleted:') &&
          !lower.startsWith('childfailed:')
        ) {
          return false;
        }
      }
    }
    return true;
  }
}
