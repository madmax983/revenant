/**
 * @description Ordering-critical core of the step-outcome seam for the Revenant
 * engine. Re-locks the freshly-completed instance FOR UPDATE, prepares it
 * (stale-completion guard, progress and capture persistence, runnable
 * assertion) and dispatches the step's directive to the matching outcome
 * handler. Also owns the effectively-once outbound-event publish coupled to the
 * COMPLETE, SPLIT and FAIL transitions. Extracted from `WorkflowEngine`; the
 * engine's step runner invokes {@link WorkflowStepOutcome#handleStepResult} at
 * the outcome seam. All SOQL and DML run in system mode.
 */
public inherited sharing class WorkflowStepOutcome {
  /**
   * @description Handles a step's returned outcome at the seam: re-locks the
   * instance FOR UPDATE, prepares the freshly-locked record and, unless the
   * completion is stale, dispatches the directive to its outcome handler. The
   * re-lock is the first durable operation so a concurrent timeout or finalizer
   * crash cannot be overwritten. Invoked by the engine's step runner in the same
   * transaction that already holds the step-execution and instance locks.
   * @param outcome the step outcome bundle carrying instance, step exec, result
   * and context
   */
  public static void handleStepResult(
    WorkflowEngine.StepOutcomeContext outcome
  ) {
    WorkflowBreadcrumbs.persistStepBreadcrumbs(outcome);
    // Re-query to avoid overwriting a timeout or finalizer crash status and race conditions
    Workflow_Instance__c freshInstance = [
      SELECT
        Id,
        Status__c,
        Current_Step__c,
        Compensation_Stack__c,
        Output__c,
        Parent_Instance__c,
        Workflow_Name__c,
        Correlation_Key__c,
        Root_Correlation_Key__c,
        Input__c,
        Definition_Version__c,
        Previous_Run_At__c,
        Concurrency_Parked__c,
        Concurrency_Slot_Held__c,
        CreatedDate,
        Progress__c,
        Causation_Id__c
      FROM Workflow_Instance__c
      WHERE Id = :outcome.instance.Id
      WITH SYSTEM_MODE
      FOR UPDATE
    ];
    if (!WorkflowOutcomePrepare.prepareStepOutcome(outcome, freshInstance)) {
      return;
    }
    dispatchStepOutcome(outcome);
  }

  // Dispatch the step outcome to the matching action handler.
  private static void dispatchStepOutcome(
    WorkflowEngine.StepOutcomeContext outcome
  ) {
    if (dispatchTerminalOrAdvanceOutcome(outcome)) {
      return;
    }
    dispatchSuspendingOutcome(outcome);
  }

  // Handlers that advance, split, retry, continue-as-new, or terminally fail the
  // instance. Returns true when the action was handled here.
  private static Boolean dispatchTerminalOrAdvanceOutcome(
    WorkflowEngine.StepOutcomeContext outcome
  ) {
    StepResult.ActionType action = outcome.result.directive().action;
    if (action == StepResult.ActionType.COMPLETE) {
      WorkflowStepAdvance.handleCompleteOutcome(outcome);
      return true;
    }
    if (action == StepResult.ActionType.SPLIT) {
      WorkflowStepSuspension.handleSplitOutcome(outcome);
      return true;
    }
    if (action == StepResult.ActionType.RETRY) {
      WorkflowContinueAsNew.handleRetryOutcome(outcome);
      return true;
    }
    if (action == StepResult.ActionType.CONTINUE_AS_NEW) {
      WorkflowContinueAsNew.handleContinueAsNewOutcome(outcome);
      return true;
    }
    if (action == StepResult.ActionType.FAIL) {
      WorkflowContinueAsNew.handleFailOutcome(outcome);
      return true;
    }
    return false;
  }

  // Handlers that suspend the instance awaiting an external event.
  private static void dispatchSuspendingOutcome(
    WorkflowEngine.StepOutcomeContext outcome
  ) {
    StepResult.ActionType action = outcome.result.directive().action;
    if (action == StepResult.ActionType.YIELD) {
      WorkflowStepSuspension.handleYieldOutcome(outcome);
    } else if (action == StepResult.ActionType.SUSPEND) {
      WorkflowStepSuspension.handleSuspendOutcome(outcome);
    } else if (action == StepResult.ActionType.SLEEP) {
      WorkflowStepSuspension.handleSleepOutcome(outcome);
    } else if (action == StepResult.ActionType.START_CHILD) {
      WorkflowStepSuspension.handleStartChildOutcome(outcome);
    } else if (action == StepResult.ActionType.START_CHILDREN) {
      WorkflowStepSuspension.handleStartChildrenOutcome(outcome);
    } else if (action == StepResult.ActionType.WAIT_FOR_APPROVAL) {
      WorkflowStepSuspension.handleWaitForApprovalOutcome(outcome);
    }
  }

  /**
   * @description Publishes the union of the events a step buffered via ctx.events().emit() and those
   * handed to StepResult.complete(next, output, events), coupled to the step's
   * COMPLETE/SPLIT transition commit (issue #64). Called only from the COMPLETE
   * and SPLIT paths, in the same transaction as the Completed record write, so
   * a non-completing transition (retry/yield/suspend/rollback) publishes
   * nothing. Delegates the actual publish (with DML-budget guard and
   * fire-and-forget failure isolation) to WorkflowOutboundEventPublisher.
   * @param result step result whose complete(...) events are published
   * @param context step context whose buffered emit() events are published
   */
  public static void publishOutboundEvents(
    StepResult result,
    StepContext context
  ) {
    List<SObject> events = new List<SObject>();
    // Filter null entries from both sources: a null SObject in the EventBus
    // publish list throws before any per-row SaveResult, which the publisher then
    // swallows (fire-and-forget) — silently dropping every valid event in the
    // same batch. ctx.events().emit(null) is already ignored at the buffer; do the same
    // for the complete(..., events) overload, where an author may have built the
    // list conditionally.
    if (context != null) {
      addNonNullEvents(context.events().getPendingEmits(), events);
    }
    if (result != null) {
      addNonNullEvents(result.directive().outboundEvents, events);
    }
    if (events.isEmpty()) {
      return;
    }
    WorkflowOutboundEventPublisher.publish(events);
  }

  /**
   * Appends the non-null entries of a source event list onto the publish list.
   * @param source the candidate events (may be null)
   * @param events the accumulating publish list
   */
  private static void addNonNullEvents(
    List<SObject> source,
    List<SObject> events
  ) {
    if (source == null) {
      return;
    }
    for (SObject e : source) {
      if (e != null) {
        events.add(e);
      }
    }
  }
}
