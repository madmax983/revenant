/**
 * @description Unrouted-signal capture & re-delivery for the workflow engine.
 * Re-homes captured Unrouted signals back onto their resolved instance as
 * Received — single (savepoint-guarded, duplicate-key tombstoning), by-instance
 * match, or bulk grouped-by-instance — then wakes the successfully-redelivered
 * instances. Extracted from `WorkflowEngine` so the engine sheds this cross-called
 * cluster toward a thin facade; callers invoke every entry qualified. Delegates
 * the actual wake and guard-clearing to {@link WorkflowResumeEnqueue}, called
 * qualified. All DML and SOQL run in system mode.
 */
public inherited sharing class WorkflowSignalRedelivery {
  /**
   * Re-parents the captured signal to the resolved instance and wakes it, sharing
   * one savepoint so the redelivery is all-or-none. On a unique-key collision with
   * a routed delivery that already claimed this instance+key, retires this row as a
   * keyless Consumed tombstone rather than delivering a second copy.
   * @param sig the captured Unrouted signal (locked)
   * @param instance the resolved active instance (locked)
   * @return true once the signal has been delivered or tombstoned
   */
  public static Boolean deliverRedeliveredSignal(
    Workflow_Signal__c sig,
    Workflow_Instance__c instance
  ) {
    sig.Workflow_Instance__c = instance.Id;
    sig.Status__c = 'Received';
    if (String.isNotBlank(sig.Idempotency_Key__c)) {
      // Rewrite the correlation-scoped capture key to the instance-scoped routed
      // key so a later routed delivery of the same idempotency key dedups against
      // this row instead of inserting a second Received signal.
      sig.Signal_Key__c = WorkflowSignalDedup.deriveSignalDedupKey(
        instance.Id,
        sig.Idempotency_Key__c
      );
    }
    // The re-parent update and the wake-up share one savepoint so the
    // redelivery is all-or-none. The update flips the row to Received and
    // rewrites Signal_Key__c to the instance-scoped routed hash; if the wake
    // then fails, the row is rolled back to its Unrouted/capture-key state so
    // redelivery can be retried. Otherwise a stranded Received row with the
    // rewritten unique key would cause a later routed duplicate of the same
    // idempotency key to no-op, leaving the workflow unwoken.
    Savepoint sp = Database.setSavepoint();
    try {
      Database.update(sig, true, AccessLevel.SYSTEM_MODE);
    } catch (DmlException ex) {
      if (ex.getDmlStatusCode(0) != 'DUPLICATE_VALUE') {
        throw ex;
      }
      // A routed delivery already claimed this instance+key, so the canonical
      // Received row exists and was (or will be) woken. This captured row is a
      // duplicate: retire it as a keyless Consumed tombstone (releasing the
      // key it could not take) rather than delivering a second copy.
      sig.Workflow_Instance__c = null;
      sig.Signal_Key__c = null;
      sig.Status__c = 'Consumed';
      Database.update(sig, true, AccessLevel.SYSTEM_MODE);
      return true;
    }

    try {
      WorkflowResumeEnqueue.wakeInstanceForSignal(instance);
    } catch (Exception e) {
      Database.rollback(sp);
      WorkflowResumeEnqueue.clearEnqueueGuards(new Set<Id>{ instance.Id });
      throw e;
    }

    return true;
  }

  /**
   * @description Re-homes any Unrouted signals matching an instance (by id or
   * correlation key) back onto it as Received, so a step that just suspended
   * awaiting a signal immediately re-observes one that arrived during its run.
   * Public so the extracted suspension handlers can invoke it, called qualified.
   * @param instanceId Id of the instance to redeliver matching signals to
   * @param correlationKey the instance's correlation key to match signals on
   */
  public static void redeliverMatchingSignalsForInstance(
    Id instanceId,
    String correlationKey
  ) {
    if (instanceId == null) {
      return;
    }
    List<Workflow_Instance__c> matchInsts = [
      SELECT Id, Status__c, Concurrency_Parked__c, Concurrency_Slot_Held__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
      WITH SYSTEM_MODE
      LIMIT 1
      FOR UPDATE
    ];

    if (matchInsts.isEmpty()) {
      return;
    }

    List<String> matchKeys = new List<String>{ String.valueOf(instanceId) };
    if (String.isNotBlank(correlationKey)) {
      matchKeys.add(correlationKey);
    }

    List<Workflow_Signal__c> allSignals = [
      SELECT
        Id,
        Correlation_Key__c,
        Status__c,
        Idempotency_Key__c,
        Signal_Key__c,
        CreatedDate
      FROM Workflow_Signal__c
      WHERE Status__c = 'Unrouted' AND Correlation_Key__c IN :matchKeys
      WITH SYSTEM_MODE
      ORDER BY CreatedDate ASC, Id ASC
      LIMIT 10000
    ];

    if (!allSignals.isEmpty()) {
      Map<Id, List<Workflow_Signal__c>> instIdToSignals = new Map<Id, List<Workflow_Signal__c>>{
        instanceId => allSignals
      };
      redeliverCapturedSignalsBulk(matchInsts, instIdToSignals);
    }
  }

  /**
   * Re-homes each captured signal onto its matched instance (Received, with a
   * per-instance dedup key when idempotency-keyed) and returns the flat list of
   * signals to update.
   * @param matchInsts the matched instances to redeliver to
   * @param instIdToSignals the captured signals grouped by instance id
   * @return the signals prepared for the redelivery update
   */
  private static List<Workflow_Signal__c> collectSignalsToRedeliver(
    List<Workflow_Instance__c> matchInsts,
    Map<Id, List<Workflow_Signal__c>> instIdToSignals
  ) {
    List<Workflow_Signal__c> signalsToUpdate = new List<Workflow_Signal__c>();
    for (Workflow_Instance__c inst : matchInsts) {
      List<Workflow_Signal__c> sigs = instIdToSignals.get(inst.Id);
      if (sigs == null) {
        continue;
      }
      for (Workflow_Signal__c sig : sigs) {
        sig.Workflow_Instance__c = inst.Id;
        sig.Status__c = 'Received';
        if (String.isNotBlank(sig.Idempotency_Key__c)) {
          sig.Signal_Key__c = WorkflowSignalDedup.deriveSignalDedupKey(
            inst.Id,
            sig.Idempotency_Key__c
          );
        }
        signalsToUpdate.add(sig);
      }
    }
    return signalsToUpdate;
  }

  /**
   * Tests whether a partial-success save result failed with a duplicate-value
   * error.
   * @param sr the save result to inspect
   * @return true when any of the result's errors is DUPLICATE_VALUE
   */
  private static Boolean isDuplicateError(Database.SaveResult sr) {
    for (Database.Error err : sr.getErrors()) {
      if (err.getStatusCode() == StatusCode.DUPLICATE_VALUE) {
        return true;
      }
    }
    return false;
  }

  /**
   * Partitions the redelivery save results: successful signals are appended to
   * successfulSignals, duplicate failures are reset to a Consumed tombstone and
   * returned, and any other failure is rethrown as a DmlException.
   * @param srs the partial-success save results (positionally aligned)
   * @param signalsToUpdate the signals that were updated (positionally aligned)
   * @param successfulSignals out: signals that updated successfully
   * @return the duplicate signals reset to Consumed tombstones
   */
  private static List<Workflow_Signal__c> partitionSaveResults(
    Database.SaveResult[] srs,
    List<Workflow_Signal__c> signalsToUpdate,
    List<Workflow_Signal__c> successfulSignals
  ) {
    List<Workflow_Signal__c> duplicateSignals = new List<Workflow_Signal__c>();
    for (Integer i = 0; i < srs.size(); i++) {
      Database.SaveResult sr = srs[i];
      Workflow_Signal__c sig = signalsToUpdate[i];
      if (sr.isSuccess()) {
        successfulSignals.add(sig);
      } else if (isDuplicateError(sr)) {
        sig.Workflow_Instance__c = null;
        sig.Signal_Key__c = null;
        sig.Status__c = 'Consumed';
        duplicateSignals.add(sig);
      } else {
        throw new DmlException(sr.getErrors()[0].getMessage());
      }
    }
    return duplicateSignals;
  }

  /**
   * Wakes each distinct instance that had a signal successfully redelivered.
   * @param successfulSignals the signals that updated successfully
   * @param instMap the matched instances by id
   */
  private static void wakeSuccessfulInstances(
    List<Workflow_Signal__c> successfulSignals,
    Map<Id, Workflow_Instance__c> instMap
  ) {
    Set<Id> wokenInstanceIds = new Set<Id>();
    for (Workflow_Signal__c sig : successfulSignals) {
      if (wokenInstanceIds.add(sig.Workflow_Instance__c)) {
        Workflow_Instance__c inst = instMap.get(sig.Workflow_Instance__c);
        if (inst != null) {
          WorkflowResumeEnqueue.wakeInstanceForSignal(inst);
        }
      }
    }
  }

  /**
   * @description Redelivers the captured Unrouted signals grouped per matched
   * instance: updates them to Captured (partitioning true duplicates), then wakes
   * the successfully-captured instances. Public so the extracted watchdog
   * sleep/orphan sweep can invoke it, called qualified.
   * @param matchInsts the suspended instances the signals were matched to
   * @param instIdToSignals the still-Unrouted signals grouped by instance id
   */
  public static void redeliverCapturedSignalsBulk(
    List<Workflow_Instance__c> matchInsts,
    Map<Id, List<Workflow_Signal__c>> instIdToSignals
  ) {
    List<Workflow_Signal__c> signalsToUpdate = collectSignalsToRedeliver(
      matchInsts,
      instIdToSignals
    );
    Map<Id, Workflow_Instance__c> instMap = new Map<Id, Workflow_Instance__c>(
      matchInsts
    );

    if (signalsToUpdate.isEmpty()) {
      return;
    }

    Savepoint sp = Database.setSavepoint();
    try {
      Database.SaveResult[] srs = Database.update(
        signalsToUpdate,
        false,
        AccessLevel.SYSTEM_MODE
      );

      List<Workflow_Signal__c> successfulSignals = new List<Workflow_Signal__c>();
      List<Workflow_Signal__c> duplicateSignals = partitionSaveResults(
        srs,
        signalsToUpdate,
        successfulSignals
      );

      if (!duplicateSignals.isEmpty()) {
        Database.update(duplicateSignals, true, AccessLevel.SYSTEM_MODE);
      }

      wakeSuccessfulInstances(successfulSignals, instMap);
    } catch (Exception e) {
      Database.rollback(sp);
      Set<Id> instIdsToClear = new Set<Id>();
      for (Workflow_Instance__c inst : matchInsts) {
        instIdsToClear.add(inst.Id);
      }
      WorkflowResumeEnqueue.clearEnqueueGuards(instIdsToClear);
      throw e;
    }
  }
}
