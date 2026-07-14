/**
 * @description Outbound domain-event buffer for a single step execution (issue
 * #64), split out of StepContext. Events buffered via emit() are published by
 * the engine effectively-once, coupled to the step's COMPLETE/SPLIT transition
 * commit; they are discarded (never published) on a yield/retry/suspend/rollback
 * because the buffer lives only on this in-memory context, which is rebuilt
 * fresh on every re-execution. Reached by step authors via StepContext.events().
 */
public inherited sharing class StepEmitter {
  /** Outbound domain events buffered via emit() during this execution. */
  private List<SObject> pendingEmits = new List<SObject>();

  /**
   * @description Buffers a platform event for publication when the step
   * completes. Call it as many times as needed; events publish in arrival order
   * once the step completes. The author chooses the __e type and its fields; the
   * engine imposes no envelope. The emitted __e should use
   * publishBehavior=PublishAfterCommit so a rolled-back transition fires nothing.
   * Delivery to subscribers stays at-least-once -- the guarantee is
   * effectively-once publication at the producer, so subscribers must remain
   * idempotent. A null event is ignored.
   * @param event The platform event (__e) SObject to buffer for publication.
   */
  public void emit(SObject event) {
    if (event != null) {
      this.pendingEmits.add(event);
    }
  }

  /**
   * @description The outbound events buffered via emit() during this execution,
   * in arrival order. Never null. The engine reads this at the step's
   * COMPLETE/SPLIT transition and publishes the union of these and any events
   * passed to StepResult.complete(next, output, events).
   * @return A cloned list of the buffered outbound events, in arrival order.
   */
  public List<SObject> getPendingEmits() {
    return this.pendingEmits.clone();
  }
}
