/**
 * @description Capture-once determinism (issue #44) and named change markers /
 * patches (issue #130) for a single step execution, split out of StepContext.
 * Owns the captured-values map and the new-key tracking used to avoid no-op DML,
 * and coordinates the patch decision: it walks the stack to attribute the calling
 * class, asks StepExecutionIndex to load the prior-execution index, and records
 * the decision durably. Serialization and reserved-key round-tripping are handled
 * by StepCaptureSerde. Reached by step authors via StepContext.captures().
 *
 * State threading: this accessor holds a back-reference to its owning StepContext
 * for the step's identity, the step's visit sequence, the StepRetryInfo whose
 * reserved bookkeeping keys round-trip through the payload, and a
 * StepExecutionIndex for the patch prior-execution lookups.
 */
public inherited sharing class StepCaptures {
  // Capture-once state. capturedValues is loaded from Captured_Values__c on
  // hydration and extended in-memory as once() is called. newCaptureKeys tracks
  // which keys were added THIS execution so the engine can persist only when
  // there is something new to write (avoids a no-op DML on every re-execution).
  /** Captured effectively-once values, hydrated then extended by once(). */
  private Map<String, Object> capturedValues = new Map<String, Object>();
  /** Keys added during THIS execution, so the engine persists only when new. */
  private Set<String> newCaptureKeys = new Set<String>();

  /** The owning StepContext, for the step's identity fields. */
  private final StepContext ctx;
  /** The retry/error metadata whose reserved keys round-trip through captures. */
  private final StepRetryInfo retry;
  /** The prior-execution index backing patch decisions. */
  private final StepExecutionIndex executionIndex;

  /**
   * @description Constructs the capture accessor bound to its owning context.
   * @param ctx The owning StepContext supplying the step's identity fields.
   * @param stepVisit The step's 0-based visit sequence within the instance.
   * @param retry The retry/error metadata whose reserved keys round-trip here.
   */
  public StepCaptures(StepContext ctx, Integer stepVisit, StepRetryInfo retry) {
    this.ctx = ctx;
    this.retry = retry;
    this.executionIndex = new StepExecutionIndex(ctx, stepVisit);
  }

  /**
   * @description Assigns the pre-parsed captured values and extracts the reserved
   * retry/error bookkeeping keys into the bound StepRetryInfo, mirroring the
   * former withCapturedValuesMap factory.
   * @param cv The captured values map to seed.
   */
  public void applyCapturedValues(Map<String, Object> cv) {
    this.capturedValues = cv;
    StepCaptureSerde.extractReservedCaptures(this.capturedValues, this.retry);
  }

  /**
   * @description Records a value the first time it is produced and returns that
   * same value on every subsequent re-execution of this logical step, without
   * calling the producer again.
   *
   * Use this to stabilize any locally generated non-deterministic value -- a
   * generated reference number, a Crypto-random token, a random branch decision,
   * or a timestamp -- so that retries, yield/resume cycles, at-least-once event
   * resumes, and operator re-drives all observe the identical value.
   *
   * Scoping mirrors idempotencyKey: distinct keys within one step are
   * independent; the same key in a different step, a different instance, or a
   * different parallel branch is a distinct capture.
   *
   * Return type -- captures are JSON round-tripped for durability, so the value
   * returned is always the JSON-normalized form (the same whether freshly
   * produced or rehydrated from a prior run). Producers should therefore return
   * JSON-native values: String, Integer/Long/Decimal/Double, Boolean, or
   * Map/List of those. A native Date/Datetime/Blob comes back as its JSON String
   * form, NOT as the original type -- capture a serialized representation instead.
   *
   * @param key Caller-supplied name, unique within this step execution.
   * @param producer Invoked at most once: only on the first call for this key.
   * @return The originally produced value in its JSON-normalized form.
   */
  public Object once(String key, CaptureProducer producer) {
    if (capturedValues.containsKey(key)) {
      return StepCaptureSerde.defensiveCopy(capturedValues.get(key));
    }
    Object raw = producer.produce();
    // JSON round-trip ensures the in-memory value is byte-identical to what
    // would be returned after serialize -> store -> deserialize on a later run.
    Object normalized = JSON.deserializeUntyped(JSON.serialize(raw));
    capturedValues.put(key, normalized);
    newCaptureKeys.add(key);
    return StepCaptureSerde.defensiveCopy(normalized);
  }

  /**
   * @description Evaluates if a specific named change marker (patch) is active
   * for this instance.
   *
   * The first time a given (instance, changeId) decision is reached, the result
   * reflects the currently-deployed code's intent (new behavior = true); that
   * decision is recorded once and returns the identical value on every subsequent
   * re-execution of that step -- same capture-once durability contract as once().
   *
   * @param changeId The unique developer-supplied name for the patch/change.
   * @return True if the patch is active/enabled for this instance, else false.
   */
  public Boolean patched(String changeId) {
    return patched(changeId, null);
  }

  /**
   * @description Evaluates if a specific named change marker (patch) is active
   * for this instance, using an optional introduction date to safely handle
   * future redeployments of the class.
   * @param changeId The unique developer-supplied name for the patch/change.
   * @param introducedAt Optional DateTime representing when the patch was
   * introduced. If provided, any instance created before this date defaults to
   * false, while instances created after default to true. This avoids regression
   * risks when the class is redeployed for unrelated edits later.
   * @return True if the patch is active/enabled for this instance, else false.
   */
  public Boolean patched(String changeId, DateTime introducedAt) {
    if (String.isBlank(changeId)) {
      return false;
    }
    String key = '__patch:' + changeId;
    if (capturedValues.containsKey(key)) {
      return (Boolean) capturedValues.get(key);
    }

    // Check if any other step in this instance has already recorded a decision for this changeId.
    executionIndex.loadExecutions(getCallingClassName());
    Boolean decision = executionIndex.decisionFor(changeId, introducedAt);
    capturedValues.put(key, decision);
    newCaptureKeys.add(key);
    return decision;
  }

  /**
   * @description Asserts that a named change marker (patch) has been
   * retired/deprecated.
   *
   * If this instance is still expecting the old branch (i.e. patched(changeId) ==
   * false), reaching this marker throws a distinguishable WorkflowException to
   * prevent silently running the wrong path.
   *
   * @param changeId The unique developer-supplied name for the patch/change.
   */
  public void deprecated(String changeId) {
    deprecated(changeId, null);
  }

  /**
   * @description Asserts that a named change marker (patch) has been
   * retired/deprecated, using an optional introduction date to safely handle
   * future redeployments of the class.
   * @param changeId The unique developer-supplied name for the patch/change.
   * @param introducedAt Optional DateTime representing when the patch was
   * introduced.
   */
  public void deprecated(String changeId, DateTime introducedAt) {
    if (!patched(changeId, introducedAt)) {
      throw new WorkflowEngine.WorkflowException(
        'Workflow execution reached retired code path for patch: ' + changeId
      );
    }
  }

  /**
   * @description Returns a JSON serialization of all captured values accumulated
   * during this execution (re-injecting the reserved retry/error bookkeeping
   * keys), or null if nothing was captured. Used by the engine to persist
   * captures to Workflow_Step_Execution__c.Captured_Values__c.
   * @return The serialized captured values (including reserved metadata), or null
   * when there is nothing to persist.
   */
  public String getCapturedValuesJson() {
    return StepCaptureSerde.getCapturedValuesJson(
      this.capturedValues,
      this.retry
    );
  }

  /**
   * @description True when at least one new capture was added during this
   * execution (i.e. the engine needs to persist Captured_Values__c). False when
   * the step only read back prior captures without adding any new ones.
   * @return True if at least one new capture was added this execution.
   */
  public Boolean hasNewCaptures() {
    return !newCaptureKeys.isEmpty();
  }

  /**
   * @description Walks the stack trace to attribute the patch call to the
   * author's class, whose LastModifiedDate anchors the patch date comparison.
   * Skips the framework frames of this class (Class.StepCaptures.) so the first
   * remaining Class. frame is the calling step; falls back to the step or
   * workflow name's outer class when no author frame is found.
   * @return The calling (author) class name.
   */
  private String getCallingClassName() {
    String trace = new DmlException().getStackTraceString();
    List<String> lines = trace.split('\n');
    for (String line : lines) {
      String trimmed = line.trim();
      if (
        trimmed.startsWith('Class.') && !trimmed.contains('Class.StepCaptures.')
      ) {
        String classAndMethod = trimmed.substring(6);
        return classAndMethod.substringBefore('.');
      }
    }
    // Fallback: use outer class of stepName or workflowName
    return ctx.stepName != null
      ? ctx.stepName.substringBefore('.')
      : ctx.workflowName.substringBefore('.');
  }
}
