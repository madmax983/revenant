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

  // Statuses of an instance whose rollback runs.
  private static final Set<String> ROLLBACK_STATUSES = new Set<String>{
    'Cancelling',
    'Compensating'
  };

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
      description='True rolls back completed compensatable steps (LIFO). False stops at once with no rollback. Empty means true.'
    )
    public Boolean runCompensations;

    @InvocableVariable(
      label='Idempotency Key'
      description='Optional. A repeat with the same key for the same instance does nothing. Same key space as Signal Workflow.'
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
      label='Cancelled'
      description='True when this request cancelled the instance. False when the instance was not found, was already finished, or a duplicate request did it.'
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
    Set<Id> cancelledIds = cancelOwners(batch);
    return assembleResults(batch, cancelledIds);
  }

  /**
   * @description The rows of one call, their resolved instances, and the owner
   * row of each live instance. The first row for an instance is its owner.
   */
  private class CancelBatch {
    final List<CancelRequest> requests;
    final List<Workflow_Instance__c> resolved;
    final Map<Id, Integer> ownerRows = new Map<Id, Integer>();

    CancelBatch(List<CancelRequest> requests) {
      this.requests = requests;
      List<String> keysOrIds = new List<String>();
      for (CancelRequest req : requests) {
        keysOrIds.add((req == null) ? null : req.workflowKeyOrId);
      }
      this.resolved = WorkflowStatusInvocableAction.resolveInstances(keysOrIds);
      for (Integer i = 0; i < resolved.size(); i++) {
        Workflow_Instance__c inst = resolved[i];
        if (
          inst != null &&
          !WorkflowCancellation.TERMINAL_STATUSES.contains(inst.Status__c) &&
          !ownerRows.containsKey(inst.Id)
        ) {
          ownerRows.put(inst.Id, i);
        }
      }
    }

    // True when row i is the owner row of its live instance.
    Boolean isOwner(Integer i) {
      Workflow_Instance__c inst = resolved[i];
      return inst != null && ownerRows.get(inst.Id) == i;
    }
  }

  /**
   * @description Claims the keyed rows, then cancels the owner rows in one engine
   * call for each Run Compensations value. On an error, it rolls back the claims
   * and the cancels, then throws.
   * @param batch The rows of the call.
   * @return The Ids that the engine cancelled.
   */
  private static Set<Id> cancelOwners(CancelBatch batch) {
    if (batch.ownerRows.isEmpty()) {
      return new Set<Id>();
    }
    Savepoint sp = Database.setSavepoint();
    // A claim error rolls back to sp and throws inside claimKeyedRows.
    Set<Id> duplicates = claimKeyedRows(batch, sp);
    try {
      List<Id> hardStopIds = new List<Id>();
      List<Id> rollbackIds = new List<Id>();
      for (Integer i = 0; i < batch.resolved.size(); i++) {
        if (!batch.isOwner(i) || duplicates.contains(batch.resolved[i].Id)) {
          continue;
        }
        if (batch.requests[i].runCompensations == false) {
          hardStopIds.add(batch.resolved[i].Id);
        } else {
          rollbackIds.add(batch.resolved[i].Id);
        }
      }
      Set<Id> cancelledIds = WorkflowCancellation.cancelInstances(hardStopIds);
      cancelledIds.addAll(
        WorkflowCancellation.cancelWithCompensationsInstances(rollbackIds)
      );
      return cancelledIds;
    } catch (Exception e) {
      Database.rollback(sp);
      throw e;
    }
  }

  /**
   * @description Writes one claim tombstone for each keyed owner row, in one DML.
   * Uses the same row and key as a keyed Cancel signal.
   * @param batch The rows of the call.
   * @param sp The savepoint to roll back on a claim error.
   * @return The instance Ids whose key was already claimed.
   */
  private static Set<Id> claimKeyedRows(CancelBatch batch, Savepoint sp) {
    List<Workflow_Signal__c> claims = new List<Workflow_Signal__c>();
    List<Id> claimIds = new List<Id>();
    for (Integer i = 0; i < batch.resolved.size(); i++) {
      if (
        !batch.isOwner(i) || String.isBlank(batch.requests[i].idempotencyKey)
      ) {
        continue;
      }
      Id instanceId = batch.resolved[i].Id;
      claims.add(
        WorkflowSignalBatchCancel.buildCancelClaim(
          instanceId,
          CLAIM_SIGNAL_NAME,
          batch.requests[i].idempotencyKey
        )
      );
      claimIds.add(instanceId);
    }
    Set<Id> duplicates = new Set<Id>(claimIds);
    if (claims.isEmpty()) {
      return duplicates;
    }
    for (
      Integer won : WorkflowSignalBatchCancel.insertCancelClaims(claims, sp)
    ) {
      duplicates.remove(claimIds[won]);
    }
    return duplicates;
  }

  /**
   * @description Builds one result per row. Reads the status again (one query),
   * so each row shows the status after the cancel.
   * @param batch The rows of the call.
   * @param cancelledIds The Ids that the engine cancelled.
   * @return One result per row, in order.
   */
  private static List<CancelResult> assembleResults(
    CancelBatch batch,
    Set<Id> cancelledIds
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
        res.isCompensating = ROLLBACK_STATUSES.contains(res.status);
        res.cancelled = batch.isOwner(i) && cancelledIds.contains(inst.Id);
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
