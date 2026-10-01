/**
 * @description Child (sub-workflow) outcome resolution for a step execution,
 * split out of StepSignals. A `ChildCompleted:<key>` or `ChildFailed:<key>`
 * signal only wakes the parent. Any caller can send these names, so the signal
 * name and payload prove nothing. The outcome comes from the child record of
 * the reading instance: its status gives the type, and its stored output is
 * resolved and decoded. One query serves all keys. Holds a back-reference to
 * its owning StepSignals for the signal reads and the matched bookkeeping.
 */
public inherited sharing class StepChildOutcomes {
  // A child in one of these statuses has a final result to read.
  private static final Set<String> OUTCOME_STATUSES = new Set<String>{
    'Completed',
    'Failed',
    'Compensated',
    'Cancelled',
    'ContinuedAsNew',
    'CompensationFailed'
  };
  private static final Integer ERROR_LIMIT = 10000;

  /** The owning signal accessor, for signal reads and match bookkeeping. */
  private final StepSignals signals;
  /** The reading instance. Its children are the only trusted source. */
  private Id instanceId;
  /** In-memory children for unit tests. Null means read the records. */
  private List<Workflow_Instance__c> seededChildren;

  /**
   * @description Constructs the child-outcome resolver bound to its signal
   * accessor.
   * @param signals The owning StepSignals used for signal reads and marking.
   */
  public StepChildOutcomes(StepSignals signals) {
    this(signals, null);
  }

  /**
   * @description Constructs the child-outcome resolver for one instance.
   * @param signals The owning StepSignals used for signal reads and marking.
   * @param instanceId The reading instance Id, or null for none.
   */
  public StepChildOutcomes(StepSignals signals, Id instanceId) {
    this.signals = signals;
    this.instanceId = instanceId;
  }

  /**
   * @description Binds the reading instance. A seeded list replaces the child
   * query (unit tests: 0 DML, 0 SOQL).
   * @param instanceId The reading instance Id.
   * @param seededChildren In-memory child records, or null to query.
   */
  public void bindChildren(
    Id instanceId,
    List<Workflow_Instance__c> seededChildren
  ) {
    this.instanceId = instanceId;
    this.seededChildren = seededChildren;
  }

  /**
   * @description Resolves the outcome of a single child (sub-workflow) by its key.
   * @param childKey The child key to look up.
   * @return The child's outcome, or an empty (not-present) outcome when the
   * child has no final result for this instance.
   */
  public StepContext.ChildOutcome getChildOutcome(String childKey) {
    List<StepContext.ChildOutcome> outcomes = this.getChildOutcomes(
      new List<String>{ childKey }
    );
    if (outcomes.isEmpty()) {
      return new StepContext.ChildOutcome();
    }
    return outcomes[0];
  }

  /**
   * @description Resolves the outcomes of several children in one pass. A key
   * has an outcome only when a child signal is pending for it and a child of
   * this instance has a final status.
   * @param childKeys The child keys to resolve, in order.
   * @return A list of outcomes aligned to childKeys; blank/unknown keys yield an
   * empty (not-present) outcome.
   */
  public List<StepContext.ChildOutcome> getChildOutcomes(
    List<String> childKeys
  ) {
    signals.preloadAll(); // Pre-load all pending signals to bulkify and avoid N+1 queries
    List<StepContext.ChildOutcome> outcomes = new List<StepContext.ChildOutcome>();
    if (childKeys == null || childKeys.isEmpty()) {
      return outcomes;
    }
    Map<String, String> woken = wokenKeys(childKeys);
    Map<String, Workflow_Instance__c> children = finishedChildren(woken);
    Map<String, String> outputs = resolveOutputs(children);
    for (String childKey : childKeys) {
      String normKey = WorkflowKeys.normalizeKey(childKey);
      Workflow_Instance__c child = woken.containsKey(normKey)
        ? children.get(normKey)
        : null;
      outcomes.add(
        child == null
          ? new StepContext.ChildOutcome()
          : toOutcome(child, outputs.get(normKey))
      );
    }
    return outcomes;
  }

  // Probes the wake signals of each key and marks them matched. Returns the
  // keys that have a pending signal (normalized key to given key). The signal
  // payload is not read.
  private Map<String, String> wokenKeys(List<String> childKeys) {
    Map<String, String> woken = new Map<String, String>();
    for (String childKey : childKeys) {
      if (String.isBlank(childKey)) {
        continue;
      }
      String completedName = 'ChildCompleted:' + childKey;
      String failedName = 'ChildFailed:' + childKey;
      // Read both names, so a branch tracks every row that it claimed.
      Boolean completedPresent = signals.getSignal(completedName).isPresent();
      Boolean failedPresent = signals.getSignal(failedName).isPresent();
      if (completedPresent || failedPresent) {
        woken.put(WorkflowKeys.normalizeKey(childKey), childKey);
        signals.markMatched(new StepContext.Signal(null, completedName, null));
        signals.markMatched(new StepContext.Signal(null, failedName, null));
      }
    }
    return woken;
  }

  // Loads the children of the reading instance by normalized key. A child key
  // is its correlation key, or its Id when the key is blank. The newest child
  // of a key wins, then the status filter applies: a running child hides an
  // older finished child with the same key. An Id match wins over a key match.
  private Map<String, Workflow_Instance__c> finishedChildren(
    Map<String, String> woken
  ) {
    Map<String, Workflow_Instance__c> byKey = new Map<String, Workflow_Instance__c>();
    if (woken.isEmpty()) {
      return byKey;
    }
    Set<String> keys = woken.keySet();
    List<Workflow_Instance__c> children = childRecords(woken.values());
    for (Workflow_Instance__c child : children) {
      String corrKey = WorkflowKeys.normalizeKey(child.Correlation_Key__c);
      if (String.isNotBlank(corrKey) && keys.contains(corrKey)) {
        byKey.put(corrKey, child);
      }
    }
    for (Workflow_Instance__c child : children) {
      String idKey = child.Id == null
        ? null
        : WorkflowKeys.normalizeKey(String.valueOf(child.Id));
      if (idKey != null && keys.contains(idKey)) {
        byKey.put(idKey, child);
      }
    }
    for (String key : new List<String>(byKey.keySet())) {
      if (!OUTCOME_STATUSES.contains(byKey.get(key).Status__c)) {
        byKey.remove(key);
      }
    }
    return byKey;
  }

  // The given keys keep their case: an Id key is case-sensitive.
  private List<Workflow_Instance__c> childRecords(List<String> keys) {
    if (seededChildren != null) {
      return seededChildren;
    }
    if (instanceId == null) {
      return new List<Workflow_Instance__c>();
    }
    Set<Id> idKeys = new Set<Id>();
    for (String key : keys) {
      if (key instanceof Id) {
        idKeys.add(key);
      }
    }
    return [
      SELECT Id, Correlation_Key__c, Status__c, Error_Message__c, Output__c
      FROM Workflow_Instance__c
      WHERE
        Parent_Instance__c = :instanceId
        AND (Correlation_Key__c IN :keys
        OR Id IN :idKeys)
      WITH SYSTEM_MODE
      ORDER BY CreatedDate ASC, Id ASC
    ];
  }

  // Resolves offload markers and decodes the stored outputs of the verified
  // children in one pass. Only a verified child record gives a stored value.
  private Map<String, String> resolveOutputs(
    Map<String, Workflow_Instance__c> children
  ) {
    List<String> keys = new List<String>();
    List<String> stored = new List<String>();
    for (String key : children.keySet()) {
      if (String.isNotBlank(children.get(key).Output__c)) {
        keys.add(key);
        stored.add(children.get(key).Output__c);
      }
    }
    Map<String, String> outputs = new Map<String, String>();
    if (stored.isEmpty()) {
      return outputs;
    }
    // An offloaded output is a file of this instance or of one of its children.
    List<String> resolved = WorkflowPayloadOffload.resolveChildPayloads(
      stored,
      instanceId
    );
    for (Integer i = 0; i < keys.size(); i++) {
      outputs.put(keys[i], resolved[i]);
    }
    return outputs;
  }

  // The status of the record decides the outcome type.
  private static StepContext.ChildOutcome toOutcome(
    Workflow_Instance__c child,
    String output
  ) {
    if (child.Status__c == 'Completed') {
      return new StepContext.ChildOutcome('Completed', null, output);
    }
    return new StepContext.ChildOutcome(
      child.Status__c,
      child.Error_Message__c == null
        ? null
        : child.Error_Message__c.left(ERROR_LIMIT),
      output
    );
  }
}
