/**
 * @description Signal consume/rollback lifecycle for the durable-execution
 * engine's exactly-once signal handling. Owns the terminal half of the
 * Received → Processing → Consumed pipeline: a successful step transition
 * consumes the signals it matched (promoting its own claims and cleaning up
 * same-name at-least-once duplicates), while a non-COMPLETE outcome rolls the
 * step's uncommitted Processing claims back to Received. All DML runs in system
 * mode. The consume pass is capped at 9 000 rows so it stays under the
 * 10 000-row DML governor limit; any excess is consumed on the next COMPLETE
 * that observes it.
 */
public inherited sharing class WorkflowSignalConsume {
  /**
   * @description Rolls back the Processing claims a parallel branch step made but
   * did not durably COMPLETE (e.g. YIELD, SUSPEND, SLEEP, WAIT_FOR_APPROVAL,
   * START_CHILD, RETRY), restoring them to Received so the branch (next run) or
   * a sibling can re-observe them. Scoped to ids this branch actually CLAIMED --
   * never rows it merely observed (a CalloutStep branch reads without claiming),
   * so it can never flip a sibling's concurrent claim back to Received.
   * @param context the step context whose claimed signal ids are rolled back
   */
  public static void rollbackClaimedSignals(StepContext context) {
    if (context == null) {
      return;
    }
    Set<Id> claimedIds = context.signals().getClaimedSignalIds();
    if (claimedIds == null || claimedIds.isEmpty()) {
      return;
    }
    List<Workflow_Signal__c> toRollback = [
      SELECT Id
      FROM Workflow_Signal__c
      WHERE Id IN :claimedIds AND Status__c = 'Processing'
      WITH SYSTEM_MODE
    ];
    if (toRollback.isEmpty()) {
      return;
    }
    for (Workflow_Signal__c sig : toRollback) {
      sig.Status__c = 'Received';
    }
    Database.update(toRollback, true, AccessLevel.SYSTEM_MODE);
  }

  /**
   * @description Coalesces a possibly-null id set to a usable set.
   * @param ids the id set, possibly null
   * @return the given id set, or a new empty set when it is null
   */
  private static Set<Id> orEmptyIds(Set<Id> ids) {
    return ids == null ? new Set<Id>() : ids;
  }

  /**
   * @description Coalesces a possibly-null string set to a usable set.
   * @param vals the string set, possibly null
   * @return the given string set, or a new empty set when it is null
   */
  private static Set<String> orEmptyStrings(Set<String> vals) {
    return vals == null ? new Set<String>() : vals;
  }

  /**
   * @description 1a. Claimed ids: buckets rows to consume while Received OR
   * Processing (this branch's own exclusive claim).
   * @param claimedIds ids exclusively claimed by this branch
   * @param toConsume the accumulating rows-to-consume map
   */
  private static void addClaimedConsumable(
    Set<Id> claimedIds,
    Map<Id, Workflow_Signal__c> toConsume
  ) {
    if (claimedIds.isEmpty()) {
      return;
    }
    for (Workflow_Signal__c sig : [
      SELECT Id
      FROM Workflow_Signal__c
      WHERE Id IN :claimedIds AND Status__c IN ('Received', 'Processing')
      WITH SYSTEM_MODE
      LIMIT 9000
    ]) {
      toConsume.put(sig.Id, sig);
    }
  }

  /**
   * @description 1b. Observed-but-not-claimed ids: buckets rows only while STILL
   * Received, so a row a sibling has since claimed (Processing) is left for the
   * sibling.
   * @param observedOnly matched-but-unclaimed ids
   * @param toConsume the accumulating rows-to-consume map
   */
  private static void addObservedConsumable(
    Set<Id> observedOnly,
    Map<Id, Workflow_Signal__c> toConsume
  ) {
    if (observedOnly.isEmpty() || toConsume.size() >= 9000) {
      return;
    }
    for (Workflow_Signal__c sig : [
      SELECT Id
      FROM Workflow_Signal__c
      WHERE Id IN :observedOnly AND Status__c = 'Received'
      WITH SYSTEM_MODE
      LIMIT 9000
    ]) {
      toConsume.put(sig.Id, sig);
    }
  }

  /**
   * @description 2. Serial same-name at-least-once duplicate cleanup (caller
   * gates on serial + uncapped read): buckets still-Received same-name rows the
   * step did not match. Restricted to still-Received rows so it never steals a
   * sibling's claim.
   * @param instanceId the instance whose duplicates are cleaned up
   * @param context step context carrying matched names/ids
   * @param toConsume the accumulating rows-to-consume map
   */
  private static void addDuplicateConsumable(
    Id instanceId,
    StepContext context,
    Map<Id, Workflow_Signal__c> toConsume
  ) {
    Set<String> matchedNames = orEmptyStrings(
      context.signals().getConsumedSignalNames()
    );
    Set<Id> matchedIds = orEmptyIds(context.signals().getConsumedSignalIds());
    Integer remaining = 9000 - toConsume.size();
    if (matchedNames.isEmpty() || remaining <= 0) {
      return;
    }
    for (Workflow_Signal__c sig : [
      SELECT Id
      FROM Workflow_Signal__c
      WHERE
        Workflow_Instance__c = :instanceId
        AND Status__c = 'Received'
        AND Signal_Name__c IN :matchedNames
        AND Id NOT IN :matchedIds
      WITH SYSTEM_MODE
      LIMIT :remaining
    ]) {
      toConsume.put(sig.Id, sig);
    }
  }

  /**
   * @description Flips the bucketed rows to Consumed and persists them in a
   * single update.
   * @param toConsume the rows to consume (may be empty)
   */
  private static void consumeSignals(Map<Id, Workflow_Signal__c> toConsume) {
    if (toConsume.isEmpty()) {
      return;
    }
    for (Workflow_Signal__c sig : toConsume.values()) {
      sig.Status__c = 'Consumed';
    }
    Database.update(toConsume.values(), true, AccessLevel.SYSTEM_MODE);
  }

  /**
   * @description Marks the signals a step matched consumed at its successful
   * transition. The exact rows the step observed/claimed
   * (context.signals().getConsumedSignalIds()) are consumed FIRST so they can
   * never be starved by the row cap when a name has a large backlog of
   * duplicates; only then is any remaining budget spent cleaning up same-name
   * at-least-once duplicates (including one delivered mid-execution after the
   * snapshot was taken). A name only probed absent never consumes a signal that
   * arrives afterwards (it contributes no matched id and no matched name).
   *
   * Ownership-scoped consumption (per signal id, not per transition kind):
   *  - CLAIMED ids (this branch holds them as exclusive Processing) are consumed
   *    while Received OR Processing -- promoting this branch's own claim.
   *  - OBSERVED-ONLY ids (matched but not claimed: serial reads, SPLIT spawn,
   *    compensation, CalloutStep branches, and claim-budget overflow rows) are
   *    consumed only while STILL Received. If a sibling has since claimed one
   *    (Processing), it now belongs to that sibling and is left alone, so this
   *    branch can never consume a row out from under a sibling's rollback.
   *  - Same-name duplicate cleanup (serial only, and only when no read was
   *    capped) catches an at-least-once redelivery that arrived after the
   *    snapshot, restricted to still-Received rows. It is skipped when a read
   *    was capped, because backlog rows the step never saw would otherwise be
   *    consumed and lost.
   *
   * Matched ids are consumed first so the exact row the step read is never left
   * behind in favor of unrelated duplicates. The combined update is capped at
   * 9 000 rows to stay below the 10 000 DML-row governor limit; any excess rows
   * are consumed on the next COMPLETE that observes them.
   * @param instanceId Id of the instance whose signals are consumed
   * @param context step context carrying the matched/claimed signal ids and names
   * @param parallelBranch true when consuming for a parallel-branch step (enables
   * ownership-scoped claim promotion; disables serial same-name cleanup)
   */
  private static void markSignalsConsumed(
    Id instanceId,
    StepContext context,
    Boolean parallelBranch
  ) {
    if (context == null) {
      return;
    }
    Set<Id> matchedIds = orEmptyIds(context.signals().getConsumedSignalIds());
    Set<Id> claimedIds = orEmptyIds(context.signals().getClaimedSignalIds());
    Set<String> matchedNames = orEmptyStrings(
      context.signals().getConsumedSignalNames()
    );
    // A step that matched nothing triggers no query, keeping non-signal steps cheap.
    if (matchedIds.isEmpty() && matchedNames.isEmpty()) {
      return;
    }

    Map<Id, Workflow_Signal__c> toConsume = new Map<Id, Workflow_Signal__c>();
    addClaimedConsumable(claimedIds, toConsume);

    Set<Id> observedOnly = new Set<Id>(matchedIds);
    observedOnly.removeAll(claimedIds);
    addObservedConsumable(observedOnly, toConsume);

    // Serial steps only, and only when no read was capped (see addDuplicateConsumable).
    // Skipped on a capped read so backlog rows the step never observed are not
    // consumed (lost). Known limitation: signalReadWasCapped() is a single flag for
    // the whole execution, so if ANY name's read was capped, duplicate cleanup is
    // suppressed for EVERY matched name -- those names degrade to at-least-once. The
    // cap only triggers at pathological scale, where at-least-once is the contract.
    if (!parallelBranch && !context.signals().signalReadWasCapped()) {
      addDuplicateConsumable(instanceId, context, toConsume);
    }

    consumeSignals(toConsume);
  }

  /**
   * @description Consumes the signals a completing step observed, scoping claim
   * promotion by the outcome's computed parallel-branch flag. A
   * no-boolean-parameter seam so the extracted outcome handlers can drive the
   * ownership-scoped consume without exposing a public Boolean parameter.
   * @param instanceId Id of the instance whose signals are consumed
   * @param outcome the step outcome bundle carrying the step context and the
   * computed parallel-branch flag
   */
  public static void markSignalsConsumedForOutcome(
    Id instanceId,
    WorkflowEngine.StepOutcomeContext outcome
  ) {
    markSignalsConsumed(instanceId, outcome.context, outcome.isParallel);
  }

  /**
   * @description Consumes the signals a serial (non-branch) transition observed.
   * A no-boolean-parameter seam so the extracted SPLIT handler can drive the
   * consume for its serially-run spawning step without exposing a public Boolean
   * parameter.
   * @param instanceId Id of the instance whose signals are consumed
   * @param context the step context carrying the observed signal ids and names
   */
  public static void markSignalsConsumedSerial(
    Id instanceId,
    StepContext context
  ) {
    markSignalsConsumed(instanceId, context, false);
  }
}
