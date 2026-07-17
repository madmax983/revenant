/**
 * @description Single-signal routing for the durable-execution engine's
 * exactly-once signal delivery. Resolves the one instance a `SignalRequest`
 * addresses (id first, then correlation key, both FOR UPDATE-locked), then
 * routes it: an unmatched non-cancel signal is captured as Unrouted, an
 * unmatched unkeyed cancel throws while an unmatched keyed cancel is an
 * idempotent no-op, a matched cancel runs claim-before-cancel dedup, and a
 * matched forward signal inserts a Received row and wakes the instance. A
 * caller-supplied idempotency key makes delivery at-most-once per (instance,
 * key): the row insert and wake-up share one savepoint, and the unique
 * `Signal_Key__c` makes a duplicate insert a silent no-op. The bulk path lives
 * in `WorkflowSignalBatch`; all DML/SOQL runs in system mode.
 */
public inherited sharing class WorkflowSignalRouter {
  /**
   * @description Sends an external signal with an optional caller-supplied
   * idempotency key. When idempotencyKey is non-blank, at-most-once delivery is
   * enforced per (instance, key) pair: a duplicate with the same key is
   * swallowed as a successful no-op — no error is returned and no second wake-up
   * fires. Dedup is constraint-based (unique Signal_Key__c per instance hash) so
   * it holds across concurrent transactions without adding SOQL to the hot path.
   * Passing null preserves the existing at-least-once behavior.
   * @param req the signal request (keyOrId, signalName, payload and optional
   * idempotencyKey); when idempotencyKey is null, at-least-once behavior applies
   */
  public static void routeSignalRequest(WorkflowEngine.SignalRequest req) {
    String keyOrId = req.keyOrId;
    String signalName = req.signalName;
    Boolean isId = isInstanceId(keyOrId);

    // A Cancel signal must also be able to reach a stalled rollback (CompensationFailed)
    // so cancellation can resume it to completion or force it terminal. Other signals keep
    // the active-only lookup — a stalled rollback is not a forward-signal target.
    // 'Paused' is included in both branches so a signal reaches a parked instance:
    // a forward signal is held (Received) and re-observed on resume, and a Cancel
    // signal can still cancel a paused instance (matching the bulk signal path).
    Boolean isCancelSignal = WorkflowSignalHelpers.isCancelSignalName(
      signalName
    );
    List<String> lookupStatuses = signalLookupStatuses(isCancelSignal);

    List<Workflow_Instance__c> instances = findSignalTargetInstances(
      keyOrId,
      isId,
      lookupStatuses
    );

    if (instances.isEmpty()) {
      handleUnmatchedSignal(req, isCancelSignal);
      return;
    }

    Workflow_Instance__c instance = instances[0];

    if (
      signalName.equalsIgnoreCase('Cancel') ||
      signalName.equalsIgnoreCase('CancelWorkflow')
    ) {
      handleCancelSignal(instance, req);
      return;
    }

    // Insert the signal record. When a caller-supplied idempotency key is present,
    // store a per-instance-scoped hash on Signal_Key__c and catch DUPLICATE_VALUE
    // to treat a repeat delivery as an idempotent no-op (no row, no wake-up).
    deliverSignal(instance, req);
  }

  /**
   * @description Tests whether the given key-or-id string is a
   * Workflow_Instance__c record id (15/18-char id-shaped and carrying the
   * object's key prefix).
   * @param keyOrId the correlation key or instance id supplied by the caller
   * @return true when the value is a workflow instance id
   */
  private static Boolean isInstanceId(String keyOrId) {
    String wflowPrefix = Workflow_Instance__c.SObjectType.getDescribe(
        SObjectDescribeOptions.DEFERRED
      )
      .getKeyPrefix();
    Pattern idPattern = Pattern.compile('^[a-zA-Z0-9]{15}([a-zA-Z0-9]{3})?$');
    return String.isNotBlank(keyOrId) &&
      idPattern.matcher(keyOrId).matches() &&
      keyOrId.startsWith(wflowPrefix);
  }

  /**
   * @description Resolves the instance statuses eligible to receive a signal. A
   * Cancel signal must also reach a stalled rollback (CompensationFailed) so
   * cancellation can resume or force it terminal; other signals keep the
   * active-only lookup. 'Paused' is included in both so a signal reaches a
   * parked instance.
   * @param isCancelSignal true when the signal is a cancellation
   * @return the statuses eligible for the signal lookup
   */
  private static List<String> signalLookupStatuses(Boolean isCancelSignal) {
    return isCancelSignal
      ? new List<String>{
          'Pending',
          'Running',
          'Suspended',
          'CompensationFailed',
          'Paused'
        }
      : new List<String>{
          'Pending',
          'Running',
          'Suspended',
          'Compensating',
          'Cancelling',
          'Paused'
        };
  }

  /**
   * @description Locks (FOR UPDATE) the single signal target instance, preferring
   * an id match (queried first so a correlation key equal to an id string cannot
   * shadow it) and falling back to a correlation-key match.
   * @param keyOrId the correlation key or instance id
   * @param isId true when keyOrId is a workflow instance id
   * @param lookupStatuses the statuses eligible for the lookup
   * @return the matched instance in a (possibly empty) single-element list
   */
  private static List<Workflow_Instance__c> findSignalTargetInstances(
    String keyOrId,
    Boolean isId,
    List<String> lookupStatuses
  ) {
    List<Workflow_Instance__c> instances = new List<Workflow_Instance__c>();
    if (isId) {
      // Query by ID first to prevent matching a correlation key that equals this ID string
      Id targetId = (Id) keyOrId;
      instances = [
        SELECT
          Id,
          Status__c,
          Concurrency_Parked__c,
          Concurrency_Slot_Held__c,
          Sleep_Until__c
        FROM Workflow_Instance__c
        WHERE Id = :targetId AND Status__c IN :lookupStatuses
        WITH SYSTEM_MODE
        LIMIT 1
        FOR UPDATE
      ];
    }

    if (instances.isEmpty()) {
      instances = [
        SELECT
          Id,
          Status__c,
          Concurrency_Parked__c,
          Concurrency_Slot_Held__c,
          Sleep_Until__c
        FROM Workflow_Instance__c
        WHERE Correlation_Key__c = :keyOrId AND Status__c IN :lookupStatuses
        WITH SYSTEM_MODE
        LIMIT 1
        FOR UPDATE
      ];
    }
    return instances;
  }

  /**
   * @description Handles a signal that matched no active instance. A keyed cancel
   * with no match is an idempotent no-op; an unkeyed cancel throws; a non-cancel
   * signal is captured as Unrouted so it is never silently lost.
   * @param req the original signal request
   * @param isCancelSignal true when the signal is a cancellation
   */
  private static void handleUnmatchedSignal(
    WorkflowEngine.SignalRequest req,
    Boolean isCancelSignal
  ) {
    if (isCancelSignal) {
      // A keyed cancel with no active match is an idempotent no-op: either the
      // first delivery already drove the instance terminal (and a duplicate is
      // now arriving) or there is nothing to cancel. Swallow rather than throw
      // so an at-least-once redelivered keyed cancel never faults the publisher.
      if (String.isNotBlank(req.idempotencyKey)) {
        return;
      }
      throw new WorkflowEngine.WorkflowException(
        'No active workflow found with key or ID: ' + req.keyOrId
      );
    }
    // Non-cancel signal with no active match: capture as Unrouted so it is
    // never silently lost and can be re-delivered by an operator.
    WorkflowUnroutedCapture.captureUnroutedSignals(
      new List<WorkflowEngine.SignalRequest>{
        new WorkflowEngine.SignalRequest(
            req.keyOrId,
            req.signalName,
            req.payload
          )
          .withDedupKey(req.dedupKey)
          .withIdempotencyKey(req.idempotencyKey)
      }
    );
  }

  /**
   * @description Delivers a cancellation signal to a matched instance. A keyed
   * cancel is deduped via a Consumed tombstone sharing one savepoint with the
   * cancel, so an at-least-once redelivery runs cancellation at most once; a
   * duplicate is a silent no-op.
   * @param instance the matched target instance
   * @param req the cancellation signal request
   */
  private static void handleCancelSignal(
    Workflow_Instance__c instance,
    WorkflowEngine.SignalRequest req
  ) {
    Boolean runCompensations = WorkflowSignalHelpers.parseRunCompensations(
      req.payload
    );
    if (String.isNotBlank(req.idempotencyKey)) {
      Savepoint sp = Database.setSavepoint();
      if (!claimKeyedCancel(instance.Id, req.signalName, req.idempotencyKey)) {
        return;
      }
      try {
        cancelInstance(instance.Id, runCompensations);
      } catch (Exception e) {
        Database.rollback(sp);
        throw e;
      }
      return;
    }
    cancelInstance(instance.Id, runCompensations);
  }

  /**
   * @description Claims a keyed Cancel/CancelWorkflow delivery by persisting a
   * dedup tombstone (Status='Consumed', so it is never surfaced as a pending
   * signal) keyed by the per-instance hash. Returns true for the first delivery
   * (caller should proceed to cancel); false if a duplicate with the same key
   * was already delivered (idempotent no-op). Mirrors the forward-signal dedup
   * so an at-least-once redelivered cancel runs cancellation at most once.
   * @param instanceId Id of the instance being cancelled
   * @param signalName name of the cancel signal
   * @param idempotencyKey caller-supplied idempotency key for the delivery
   * @return true for the first delivery; false when a duplicate was already claimed
   */
  private static Boolean claimKeyedCancel(
    Id instanceId,
    String signalName,
    String idempotencyKey
  ) {
    Workflow_Signal__c marker = new Workflow_Signal__c(
      Workflow_Instance__c = instanceId,
      Signal_Name__c = signalName,
      Status__c = 'Consumed',
      Signal_Key__c = WorkflowSignalDedup.deriveSignalDedupKey(
        instanceId,
        idempotencyKey
      )
    );
    try {
      Database.insert(marker, true, AccessLevel.SYSTEM_MODE);
      return true;
    } catch (DmlException ex) {
      if (ex.getDmlStatusCode(0) == 'DUPLICATE_VALUE') {
        return false;
      }
      throw ex;
    }
  }

  /**
   * @description Inserts the Received signal record and wakes the instance. When
   * a caller idempotency key is present, the row insert and wake-up share one
   * savepoint (unique Signal_Key__c makes a duplicate insert a silent no-op; a
   * failed wake-up rolls the row back so a retry re-inserts and re-wakes).
   * @param instance the matched target instance
   * @param req the signal request being delivered
   */
  private static void deliverSignal(
    Workflow_Instance__c instance,
    WorkflowEngine.SignalRequest req
  ) {
    Workflow_Signal__c sig = new Workflow_Signal__c();
    sig.Workflow_Instance__c = instance.Id;
    sig.Signal_Name__c = req.signalName;
    sig.Payload__c = req.payload;
    sig.Status__c = 'Received';

    if (String.isNotBlank(req.idempotencyKey)) {
      sig.Signal_Key__c = WorkflowSignalDedup.deriveSignalDedupKey(
        instance.Id,
        req.idempotencyKey
      );
      Savepoint sp = Database.setSavepoint();
      try {
        Database.insert(sig, true, AccessLevel.SYSTEM_MODE);
      } catch (DmlException ex) {
        if (ex.getDmlStatusCode(0) == 'DUPLICATE_VALUE') {
          return; // idempotent no-op: duplicate key already delivered
        }
        throw ex;
      }
      try {
        WorkflowResumeEnqueue.wakeInstanceForSignal(instance);
      } catch (Exception e) {
        Database.rollback(sp);
        WorkflowResumeEnqueue.clearEnqueueGuards(new Set<Id>{ instance.Id });
        throw e;
      }
      return;
    }

    Database.insert(sig, true, AccessLevel.SYSTEM_MODE);
    WorkflowResumeEnqueue.wakeInstanceForSignal(instance);
  }

  // Cancels a workflow instance, optionally running saga compensations across the
  // instance and its active descendant tree. Thin dispatcher mirroring the
  // engine's internal cancel call sites; the cancellation logic lives on
  // WorkflowCancellation.
  private static void cancelInstance(Id instanceId, Boolean runCompensations) {
    if (runCompensations) {
      WorkflowCancellation.cancelWithCompensationsInstance(instanceId);
    } else {
      WorkflowCancellation.cancelInstance(instanceId);
    }
  }
}
