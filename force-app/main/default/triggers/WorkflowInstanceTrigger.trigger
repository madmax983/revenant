trigger WorkflowInstanceTrigger on Workflow_Instance__c(
  before insert,
  before update
) {
  // Concurrency slot release (issue #28): the single centralized terminal chokepoint.
  // An instance that held a slot and is making its first transition into a terminal
  // state releases it so a parked instance is admitted promptly afterward. The
  // slot-held flag is cleared in-place (no extra DML) to guard against double-release;
  // decrements are grouped by workflow definition and applied once below.
  Map<String, Integer> slotsToRelease = new Map<String, Integer>();

  for (Workflow_Instance__c instance : Trigger.new) {
    // Default the chain root key to this instance's own correlation key on insert.
    // continueAsNew successors set Root_Correlation_Key__c explicitly (to the
    // predecessor's root), so they are already non-blank and are left untouched.
    if (Trigger.isInsert && String.isBlank(instance.Root_Correlation_Key__c)) {
      instance.Root_Correlation_Key__c = instance.Correlation_Key__c;
    }

    if (
      instance.Status__c == 'Pending' ||
      instance.Status__c == 'Running' ||
      instance.Status__c == 'Suspended' ||
      instance.Status__c == 'Compensating' ||
      instance.Status__c == 'Cancelling' ||
      instance.Status__c == 'CompensationFailed' ||
      instance.Status__c == 'Paused'
    ) {
      // A stalled rollback (CompensationFailed) is non-terminal: it still has
      // un-reversed side effects and can be resumed, so it must keep reserving its
      // correlation key to prevent a duplicate active workflow from starting with the
      // same key while the saga is only half-undone.
      instance.Active_Correlation_Key__c = instance.Correlation_Key__c;
    } else {
      instance.Active_Correlation_Key__c = null;
    }

    // Track terminal state transition to record Terminal_At__c timestamp
    Boolean isTerminal = (instance.Status__c == 'Completed' ||
    instance.Status__c == 'Failed' ||
    instance.Status__c == 'Compensated' ||
    instance.Status__c == 'Cancelled' ||
    instance.Status__c == 'ContinuedAsNew');
    Boolean wasTerminal = false;
    if (isTerminal) {
      if (Trigger.isInsert) {
        instance.Terminal_At__c = System.now();
      } else {
        Workflow_Instance__c oldInstance = Trigger.oldMap.get(instance.Id);
        wasTerminal = (oldInstance.Status__c == 'Completed' ||
        oldInstance.Status__c == 'Failed' ||
        oldInstance.Status__c == 'Compensated' ||
        oldInstance.Status__c == 'Cancelled' ||
        oldInstance.Status__c == 'ContinuedAsNew');
        if (!wasTerminal) {
          instance.Terminal_At__c = System.now();
        }
      }
    } else {
      instance.Terminal_At__c = null;
    }

    // Release the concurrency slot on the FIRST transition into a terminal state
    // (CompensationFailed is non-terminal and correctly retains its slot). Only an
    // instance that actually held a slot decrements; the flag is cleared in-place so
    // a re-saved terminal record never double-releases.
    if (
      Trigger.isUpdate &&
      isTerminal &&
      !wasTerminal &&
      instance.Concurrency_Slot_Held__c == true
    ) {
      String wf = instance.Workflow_Name__c;
      Integer prior = slotsToRelease.containsKey(wf) ? slotsToRelease.get(wf) : 0;
      slotsToRelease.put(wf, prior + 1);
      instance.Concurrency_Slot_Held__c = false;
      instance.Concurrency_Parked__c = false;
    }
  }

  if (!slotsToRelease.isEmpty()) {
    try {
      ConcurrencyGate.releaseBulk(slotsToRelease);
    } catch (Exception ex) {
      // Fire-and-forget: a failed release must never roll back the terminal-state
      // write. The watchdog reconcile sweep reclaims any leaked slot.
      System.debug(
        LoggingLevel.WARN,
        'Concurrency slot release failed (suppressed): ' + ex.getMessage()
      );
    }
  }
}
