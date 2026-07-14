/**
 * @description Child (sub-workflow) outcome resolution for a step execution,
 * split out of StepSignals. Resolves ChildCompleted/ChildFailed signals for one
 * or many child keys, bulk-resolving offloaded payloads to avoid N+1 queries.
 * Holds a back-reference to its owning StepSignals for the signal reads and the
 * matched/observed bookkeeping those reads drive.
 */
public inherited sharing class StepChildOutcomes {
  /** The owning signal accessor, for signal reads and match bookkeeping. */
  private final StepSignals signals;

  /**
   * @description Constructs the child-outcome resolver bound to its signal
   * accessor.
   * @param signals The owning StepSignals used for signal reads and marking.
   */
  public StepChildOutcomes(StepSignals signals) {
    this.signals = signals;
  }

  /**
   * @description Resolves the outcome of a single child (sub-workflow) by its key
   * from the pending ChildCompleted/ChildFailed signals.
   * @param childKey The child key to look up.
   * @return The child's outcome, or an empty (not-present) outcome when none is
   * pending.
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
   * @description Resolves the outcomes of several children in one pass, bulk-
   * resolving their payloads to avoid N+1 signal queries.
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
    ChildResolution res = new ChildResolution();
    // Step 1: probe each key's signals and collect raw payloads to resolve.
    for (Integer i = 0; i < childKeys.size(); i++) {
      collectChildPayloads(i, childKeys[i], res);
    }
    // Step 2: bulk-resolve the collected payloads and index them by key.
    resolveChildPayloads(res);
    // Step 3: construct the ChildOutcome list.
    for (Integer i = 0; i < childKeys.size(); i++) {
      outcomes.add(buildChildOutcome(i, childKeys[i], res));
    }
    return outcomes;
  }

  // Mutable accumulator for the three phases of getChildOutcomes so no phase
  // helper needs a long parameter list.
  private class ChildResolution {
    List<String> rawPayloads = new List<String>();
    List<Integer> targetKeyIndex = new List<Integer>();
    List<String> targetType = new List<String>(); // 'completed' or 'failedOutput'
    // Pre-deserialized maps for failed signals so we don't deserialize twice.
    Map<Integer, Map<String, Object>> failedDataMap = new Map<Integer, Map<String, Object>>();
    Map<Integer, String> resolvedCompleted = new Map<Integer, String>();
    Map<Integer, String> resolvedFailedOutput = new Map<Integer, String>();

    void addRawPayload(String payload, Integer keyIndex, String type) {
      this.rawPayloads.add(payload);
      this.targetKeyIndex.add(keyIndex);
      this.targetType.add(type);
    }
  }

  /**
   * @description Probes a single child key's completed/failed signals, marking
   * them observed and collecting their raw payloads for bulk resolution.
   * @param i The child key index.
   * @param childKey The child key to probe.
   * @param res The shared resolution accumulator.
   */
  private void collectChildPayloads(
    Integer i,
    String childKey,
    ChildResolution res
  ) {
    if (String.isBlank(childKey)) {
      return;
    }
    String completedName = 'ChildCompleted:' + childKey;
    String failedName = 'ChildFailed:' + childKey;
    StepContext.Signal completedSig = signals.getSignal(completedName);
    StepContext.Signal failedSig = signals.getSignal(failedName);

    if (completedSig.isPresent() || failedSig.isPresent()) {
      signals.markMatched(new StepContext.Signal(null, completedName, null));
      signals.markMatched(new StepContext.Signal(null, failedName, null));
    }

    if (completedSig.isPresent()) {
      if (String.isNotBlank(completedSig.payload)) {
        res.addRawPayload(completedSig.payload, i, 'completed');
      }
    } else if (failedSig.isPresent() && String.isNotBlank(failedSig.payload)) {
      collectFailedPayload(i, failedSig, res);
    }
  }

  /**
   * @description Deserializes a failed child signal's payload and, when its
   * output is a String, queues that output for bulk resolution.
   * @param i The child key index.
   * @param failedSig The failed child signal.
   * @param res The shared resolution accumulator.
   */
  private void collectFailedPayload(
    Integer i,
    StepContext.Signal failedSig,
    ChildResolution res
  ) {
    try {
      Map<String, Object> data = (Map<String, Object>) JSON.deserializeUntyped(
        failedSig.payload
      );
      res.failedDataMap.put(i, data);
      Object outputObj = data.get('output');
      if (outputObj instanceof String) {
        res.addRawPayload((String) outputObj, i, 'failedOutput');
      }
    } catch (Exception ignored) {
      // Deserialization failure will be handled during outcome construction
    }
  }

  /**
   * @description Bulk-resolves the collected child payloads and indexes them by
   * key index and type.
   * @param res The shared resolution accumulator to populate.
   */
  private void resolveChildPayloads(ChildResolution res) {
    if (res.rawPayloads.isEmpty()) {
      return;
    }
    List<String> resolvedPayloads = WorkflowPayloadOffload.resolvePayloads(
      res.rawPayloads
    );
    for (Integer j = 0; j < resolvedPayloads.size(); j++) {
      Integer keyIdx = res.targetKeyIndex[j];
      String type = res.targetType[j];
      if (type == 'completed') {
        res.resolvedCompleted.put(keyIdx, resolvedPayloads[j]);
      } else if (type == 'failedOutput') {
        res.resolvedFailedOutput.put(keyIdx, resolvedPayloads[j]);
      }
    }
  }

  /**
   * @description Constructs the ChildOutcome for one child key from its probed
   * signals and the bulk-resolved payloads.
   * @param i The child key index.
   * @param childKey The child key.
   * @param res The shared resolution accumulator.
   * @return The resolved child outcome, or an empty outcome when absent.
   */
  private StepContext.ChildOutcome buildChildOutcome(
    Integer i,
    String childKey,
    ChildResolution res
  ) {
    if (String.isBlank(childKey)) {
      return new StepContext.ChildOutcome();
    }
    StepContext.Signal completedSig = signals.getSignal(
      'ChildCompleted:' + childKey
    );
    StepContext.Signal failedSig = signals.getSignal('ChildFailed:' + childKey);

    if (completedSig.isPresent()) {
      String resolvedVal = res.resolvedCompleted.containsKey(i)
        ? res.resolvedCompleted.get(i)
        : completedSig.payload;
      return new StepContext.ChildOutcome('Completed', null, resolvedVal);
    }
    if (!failedSig.isPresent()) {
      return new StepContext.ChildOutcome();
    }
    if (String.isBlank(failedSig.payload)) {
      return new StepContext.ChildOutcome('Failed', null, null);
    }
    if (!res.failedDataMap.containsKey(i)) {
      return new StepContext.ChildOutcome('Failed', failedSig.payload, null);
    }
    return buildFailedOutcome(i, res);
  }

  /**
   * @description Builds a failed ChildOutcome from the pre-deserialized failure
   * data, resolving its output payload when present.
   * @param i The child key index.
   * @param res The shared resolution accumulator.
   * @return The failed child outcome.
   */
  private StepContext.ChildOutcome buildFailedOutcome(
    Integer i,
    ChildResolution res
  ) {
    Map<String, Object> data = res.failedDataMap.get(i);
    String status = data.get('status') != null
      ? String.valueOf(data.get('status'))
      : null;
    String errorMessage = data.get('errorMessage') != null
      ? String.valueOf(data.get('errorMessage'))
      : null;
    Object outputObj = data.get('output');
    String outputVal = null;
    if (outputObj instanceof String) {
      outputVal = res.resolvedFailedOutput.containsKey(i)
        ? res.resolvedFailedOutput.get(i)
        : (String) outputObj;
    } else if (outputObj != null) {
      outputVal = JSON.serialize(outputObj);
    }
    return new StepContext.ChildOutcome(status, errorMessage, outputVal);
  }
}
