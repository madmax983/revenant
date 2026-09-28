/**
 * @description Flow action that cancels Revenant workflow instances (issue #107).
 * It finds each instance the same way as Get Workflow Status. It cancels all rows
 * in one set-based engine pass for each Run Compensations value. A keyed row
 * writes the same claim tombstone as a keyed Cancel signal, so a retry does not
 * cancel two times. It adds no engine behavior and no schema.
 */
public inherited sharing class WorkflowCancelInvocableAction {
  // Signal name on the claim tombstone. Same as the Cancel control signal.
  private static final String CLAIM_SIGNAL_NAME = 'Cancel';

  /**
   * @description One cancel request from Flow.
   */
  public class CancelRequest {
    @InvocableVariable(
      label='Correlation Key or Workflow Instance ID'
      description='A Workflow Instance record Id or a Correlation Key. A key finds the live instance and follows ContinuedAsNew.'
      required=true
    )
    public String workflowKeyOrId;

    @InvocableVariable(
      label='Run Compensations'
      description='True rolls back the completed steps that can roll back, last step first. False stops at once with no rollback. Empty means true.'
    )
    public Boolean runCompensations;

    @InvocableVariable(
      label='Idempotency Key'
      description='Optional. A repeat with the same key for the same instance does nothing. Signal Workflow uses the same keys, so do not use a key of a different signal.'
    )
    public String idempotencyKey;
  }

  /**
   * @description The outcome of one cancel request.
   */
  public class CancelResult {
    @InvocableVariable(
      label='Found'
      description='False when no workflow instance matches the key or Id.'
    )
    public Boolean found;

    @InvocableVariable(
      label='Workflow Instance ID'
      description='The instance that the action found.'
    )
    public Id workflowInstanceId;

    @InvocableVariable(
      label='Cancelled By This Request'
      description='True when this request cancelled the instance. False when the instance was not found, was already finished or rolling back, or another request did it.'
    )
    public Boolean cancelled;

    @InvocableVariable(
      label='Is Compensating'
      description='True when a rollback runs (Status is Cancelling or Compensating).'
    )
    public Boolean isCompensating;

    @InvocableVariable(
      label='Status'
      description='The instance Status after the action. A rollback shows Cancelling, then Cancelled when it ends.'
    )
    public String status;

    /**
     * @description Makes a not-found, not-cancelled result.
     */
    public CancelResult() {
      this.found = false;
      this.cancelled = false;
      this.isCompensating = false;
    }
  }

  @InvocableMethod(
    label='Cancel Workflow'
    category='Revenant Workflows'
    description='Cancels a Revenant durable workflow instance and its active children, with or without saga compensation.'
  )
  /**
   * @description Cancels one instance per request. Bulk-safe: SOQL and DML do not
   * grow with the row count. A request that matches nothing, or an instance that
   * is already finished, gives a result and no fault. When two rows find the
   * same instance, the first row wins.
   * @param requests The cancel requests; null or empty gives an empty list.
   * @return One result per request, in the same order.
   */
  public static List<CancelResult> cancelWorkflow(
    List<CancelRequest> requests
  ) {
    if (requests == null || requests.isEmpty()) {
      return new List<CancelResult>();
    }
    CancelBatch batch = new CancelBatch(requests);
    Set<Id> cancelledRoots = new Set<Id>();
    if (batch.hasCandidates()) {
      Savepoint sp = Database.setSavepoint();
      // A claim error rolls back to sp and throws inside claimKeyedRows.
      batch.selectOwners(claimKeyedRows(batch, sp));
      try {
        cancelledRoots = cancelOwners(batch);
      } catch (Exception e) {
        Database.rollback(sp);
        throw e;
      }
    }
    return assembleResults(batch, cancelledRoots);
  }

  /**
   * @description The rows of one call and their resolved instances. A row is a
   * candidate when its instance is live and, for a rollback row, not already
   * rolling back. The first candidate row per instance whose key is not a
   * duplicate is the owner. Only an owner row cancels.
   */
  private class CancelBatch {
    final List<CancelRequest> requests;
    final List<Workflow_Instance__c> resolved;
    // Claim key per row (null when the row has no claim).
    final List<String> claimKeys = new List<String>();
    final Map<Id, Integer> ownerRows = new Map<Id, Integer>();

    CancelBatch(List<CancelRequest> requests) {
      this.requests = requests;
      List<String> keysOrIds = new List<String>();
      for (CancelRequest req : requests) {
        keysOrIds.add((req == null) ? null : req.workflowKeyOrId);
      }
      this.resolved = WorkflowStatusInvocableAction.resolveInstances(keysOrIds);
    }

    // True when row i asks for a rollback. Empty means true.
    Boolean wantsRollback(Integer i) {
      return requests[i].runCompensations != false;
    }

    // True when row i can cancel its instance.
    Boolean isCandidate(Integer i) {
      Workflow_Instance__c inst = resolved[i];
      return inst != null &&
        !WorkflowCancellation.isTerminalForCancel(inst.Status__c) &&
        !(wantsRollback(i) &&
        WorkflowCancellation.isRollingBack(inst.Status__c));
    }

    Boolean hasCandidates() {
      for (Integer i = 0; i < resolved.size(); i++) {
        if (isCandidate(i)) {
          return true;
        }
      }
      return false;
    }

    // Picks the owner rows. A row whose claim key lost is a duplicate.
    void selectOwners(Set<String> lostKeys) {
      for (Integer i = 0; i < resolved.size(); i++) {
        if (
          isCandidate(i) &&
          !lostKeys.contains(claimKeys[i]) &&
          !ownerRows.containsKey(resolved[i].Id)
        ) {
          ownerRows.put(resolved[i].Id, i);
        }
      }
    }

    // True when row i is the owner row of its instance.
    Boolean isOwner(Integer i) {
      Workflow_Instance__c inst = resolved[i];
      return inst != null && ownerRows.get(inst.Id) == i;
    }
  }

  /**
   * @description Writes one claim tombstone for each distinct (instance, key)
   * pair of the keyed candidate rows, in one DML. Uses the same row and key as a
   * keyed Cancel signal. Sets the claim key of each keyed candidate row.
   * @param batch The rows of the call.
   * @param sp The savepoint to roll back on a claim error.
   * @return The claim keys that were already claimed (duplicates).
   */
  private static Set<String> claimKeyedRows(CancelBatch batch, Savepoint sp) {
    List<Workflow_Signal__c> claims = new List<Workflow_Signal__c>();
    Set<String> seen = new Set<String>();
    for (Integer i = 0; i < batch.resolved.size(); i++) {
      String key = batch.isCandidate(i)
        ? batch.requests[i].idempotencyKey
        : null;
      if (String.isBlank(key)) {
        batch.claimKeys.add(null);
        continue;
      }
      Workflow_Signal__c claim = WorkflowSignalBatchCancel.buildCancelClaim(
        batch.resolved[i].Id,
        CLAIM_SIGNAL_NAME,
        key
      );
      batch.claimKeys.add(claim.Signal_Key__c);
      if (seen.add(claim.Signal_Key__c)) {
        claims.add(claim);
      }
    }
    Set<String> lostKeys = new Set<String>(seen);
    if (claims.isEmpty()) {
      return lostKeys;
    }
    for (
      Integer won : WorkflowSignalBatchCancel.insertCancelClaims(claims, sp)
    ) {
      lostKeys.remove(claims[won].Signal_Key__c);
    }
    return lostKeys;
  }

  /**
   * @description Cancels the owner rows in one engine call for each Run
   * Compensations value. The hard-stop call runs first. A parent hard stop
   * therefore also stops a child that another row asked to roll back.
   * @param batch The rows of the call, with owners selected.
   * @return The root Ids that their own row cancelled.
   */
  private static Set<Id> cancelOwners(CancelBatch batch) {
    List<Id> hardStopIds = new List<Id>();
    List<Id> rollbackIds = new List<Id>();
    for (Integer i = 0; i < batch.resolved.size(); i++) {
      if (!batch.isOwner(i)) {
        continue;
      }
      if (batch.wantsRollback(i)) {
        rollbackIds.add(batch.resolved[i].Id);
      } else {
        hardStopIds.add(batch.resolved[i].Id);
      }
    }
    Set<Id> cancelledRoots = new Set<Id>(hardStopIds);
    cancelledRoots.retainAll(WorkflowCancellation.cancelInstances(hardStopIds));
    Set<Id> rolledBack = new Set<Id>(rollbackIds);
    rolledBack.retainAll(
      WorkflowCancellation.cancelWithCompensationsInstances(rollbackIds)
    );
    cancelledRoots.addAll(rolledBack);
    return cancelledRoots;
  }

  /**
   * @description Builds one result per row. Reads the status again (one query),
   * so each row shows the status after the cancel.
   * @param batch The rows of the call.
   * @param cancelledRoots The root Ids that their own row cancelled.
   * @return One result per row, in order.
   */
  private static List<CancelResult> assembleResults(
    CancelBatch batch,
    Set<Id> cancelledRoots
  ) {
    Map<Id, Workflow_Instance__c> current = readStatuses(batch.resolved);
    List<CancelResult> results = new List<CancelResult>();
    for (Integer i = 0; i < batch.resolved.size(); i++) {
      Workflow_Instance__c inst = batch.resolved[i];
      CancelResult res = new CancelResult();
      if (inst != null) {
        Workflow_Instance__c latest = current.get(inst.Id);
        res.found = true;
        res.workflowInstanceId = inst.Id;
        res.status = (latest == null) ? inst.Status__c : latest.Status__c;
        res.isCompensating = WorkflowCancellation.isRollingBack(res.status);
        res.cancelled = batch.isOwner(i) && cancelledRoots.contains(inst.Id);
      }
      results.add(res);
    }
    return results;
  }

  /**
   * @description Reads the current status of each found instance in one query.
   * @param resolved The resolved instance per row (null where no match).
   * @return The current instances by Id.
   */
  private static Map<Id, Workflow_Instance__c> readStatuses(
    List<Workflow_Instance__c> resolved
  ) {
    Set<Id> foundIds = new Set<Id>();
    for (Workflow_Instance__c inst : resolved) {
      if (inst != null) {
        foundIds.add(inst.Id);
      }
    }
    if (foundIds.isEmpty()) {
      return new Map<Id, Workflow_Instance__c>();
    }
    return new Map<Id, Workflow_Instance__c>(
      [
        SELECT Id, Status__c
        FROM Workflow_Instance__c
        WHERE Id IN :foundIds
        WITH SYSTEM_MODE
      ]
    );
  }
}
