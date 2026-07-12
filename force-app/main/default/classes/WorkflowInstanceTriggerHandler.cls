/**
 * Handler for WorkflowInstanceTrigger. All before-insert / before-update logic for
 * Workflow_Instance__c lives here so the trigger stays a thin delegate
 * (AvoidLogicInTrigger). Behavior is identical to the original in-trigger implementation:
 * correlation-key defaulting, active-key reservation, terminal-timestamp stamping,
 * failure-category clearing, and the single centralized concurrency-slot release
 * chokepoint (issue #28) are all preserved in the same order.
 *
 * Sharing: inherited sharing. Triggers execute in system context; a handler with
 * inherited sharing runs with the sharing of its caller (the trigger, i.e. system) and
 * imposes no additional record-level restriction, preserving the original behavior.
 */
public inherited sharing class WorkflowInstanceTriggerHandler {
  private static final Set<String> ACTIVE_STATUSES = new Set<String>{
    'Pending',
    'Running',
    'Suspended',
    'Compensating',
    'Cancelling',
    'CompensationFailed',
    'Paused'
  };
  private static final Set<String> TERMINAL_STATUSES = new Set<String>{
    'Completed',
    'Failed',
    'Compensated',
    'Cancelled',
    'ContinuedAsNew'
  };

  private final List<Workflow_Instance__c> newInstances;
  private final Map<Id, Workflow_Instance__c> oldMap;
  private final Boolean isInsert;
  private final Boolean isUpdate;

  // Concurrency slot release (issue #28): the single centralized terminal chokepoint.
  // An instance that held a slot and is making its first transition into a terminal
  // state releases it so a parked instance is admitted promptly afterward. The
  // slot-held flag is cleared in-place (no extra DML) to guard against double-release;
  // decrements are grouped by workflow definition and applied once below.
  private final Map<String, Integer> slotsToRelease = new Map<String, Integer>();

  /**
   * @description Constructs the handler with the trigger's new records, old-map,
   * and operation type, deriving the insert/update flags used by the save logic.
   * @param newInstances Trigger.new list of Workflow_Instance__c records.
   * @param oldMap Trigger.oldMap of prior record states (null on insert).
   * @param operationType The trigger operation being handled.
   */
  public WorkflowInstanceTriggerHandler(
    List<Workflow_Instance__c> newInstances,
    Map<Id, Workflow_Instance__c> oldMap,
    System.TriggerOperation operationType
  ) {
    this.newInstances = newInstances;
    this.oldMap = oldMap;
    this.isInsert = operationType == System.TriggerOperation.BEFORE_INSERT;
    this.isUpdate = operationType == System.TriggerOperation.BEFORE_UPDATE;
  }

  /**
   * @description Applies all before-insert/before-update logic for each record —
   * correlation-key defaulting and reservation, terminal-timestamp stamping,
   * failure-category clearing — then releases any accumulated concurrency slots.
   */
  public void handleBeforeSave() {
    for (Workflow_Instance__c instance : newInstances) {
      applyRootCorrelationKeyDefault(instance);
      applyActiveCorrelationKey(instance);
      Boolean isTerminal = TERMINAL_STATUSES.contains(instance.Status__c);
      Boolean wasTerminal = applyTerminalTimestamp(instance, isTerminal);
      clearFailureCategoryIfResolved(instance);
      accumulateSlotRelease(instance, isTerminal, wasTerminal);
    }

    releaseSlots();
  }

  private void applyRootCorrelationKeyDefault(Workflow_Instance__c instance) {
    // Default the chain root key to this instance's own correlation key on insert.
    // continueAsNew successors set Root_Correlation_Key__c explicitly (to the
    // predecessor's root), so they are already non-blank and are left untouched.
    if (isInsert && String.isBlank(instance.Root_Correlation_Key__c)) {
      instance.Root_Correlation_Key__c = instance.Correlation_Key__c;
    }
  }

  private void applyActiveCorrelationKey(Workflow_Instance__c instance) {
    // A stalled rollback (CompensationFailed) is non-terminal: it still has un-reversed
    // side effects and can be resumed, so it must keep reserving its correlation key to
    // prevent a duplicate active workflow from starting with the same key while the saga
    // is only half-undone.
    if (ACTIVE_STATUSES.contains(instance.Status__c)) {
      instance.Active_Correlation_Key__c = instance.Correlation_Key__c;
    } else {
      instance.Active_Correlation_Key__c = null;
    }
  }

  /**
   * Stamps or clears Terminal_At__c for the terminal-state transition and returns
   * whether the record was ALREADY terminal before this save (used downstream to gate
   * the slot release to the FIRST terminal transition only).
   *
   * @param instance The record being saved.
   * @param isTerminal Whether the record's new status is a terminal status.
   * @return True if the record was already terminal before this save.
   */
  private Boolean applyTerminalTimestamp(
    Workflow_Instance__c instance,
    Boolean isTerminal
  ) {
    if (!isTerminal) {
      instance.Terminal_At__c = null;
      return false;
    }
    if (isInsert) {
      instance.Terminal_At__c = System.now();
      return false;
    }
    Workflow_Instance__c oldInstance = oldMap.get(instance.Id);
    Boolean wasTerminal = TERMINAL_STATUSES.contains(oldInstance.Status__c);
    if (!wasTerminal) {
      instance.Terminal_At__c = System.now();
    }
    return wasTerminal;
  }

  private void clearFailureCategoryIfResolved(Workflow_Instance__c instance) {
    // Clear failure category for non-failed states
    if (
      instance.Status__c != 'Failed' &&
      instance.Status__c != 'CompensationFailed'
    ) {
      instance.Failure_Category__c = null;
    }
  }

  private void accumulateSlotRelease(
    Workflow_Instance__c instance,
    Boolean isTerminal,
    Boolean wasTerminal
  ) {
    // Release the concurrency slot on the FIRST transition into a terminal state
    // (CompensationFailed is non-terminal and correctly retains its slot). Only an
    // instance that actually held a slot decrements; the flag is cleared in-place so
    // a re-saved terminal record never double-releases.
    if (
      !(isUpdate &&
      isTerminal &&
      !wasTerminal &&
      instance.Concurrency_Slot_Held__c == true)
    ) {
      return;
    }
    String wf = instance.Workflow_Name__c;
    Integer prior = slotsToRelease.containsKey(wf) ? slotsToRelease.get(wf) : 0;
    slotsToRelease.put(wf, prior + 1);
    instance.Concurrency_Slot_Held__c = false;
    instance.Concurrency_Parked__c = false;
  }

  private void releaseSlots() {
    if (slotsToRelease.isEmpty()) {
      return;
    }
    try {
      ConcurrencyGate.releaseBulk(slotsToRelease);
    } catch (Exception ignored) {
      // Fire-and-forget: a failed release must never roll back the terminal-state
      // write. The watchdog reconcile sweep reclaims any leaked slot.
    }
  }
}
