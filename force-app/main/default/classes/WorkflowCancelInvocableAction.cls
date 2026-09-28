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

  // Statuses that a cancel skips. Same set as the engine cancel.
  private static final Set<String> TERMINAL_STATUSES = new Set<String>{
    'Completed',
    'Failed',
    'Compensated',
    'Cancelled',
    'ContinuedAsNew'
  };

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
    List<String> keysOrIds = new List<String>();
    for (CancelRequest req : requests) {
      keysOrIds.add((req == null) ? null : req.workflowKeyOrId);
    }
    List<Workflow_Instance__c> resolved = WorkflowStatusInvocableAction.resolveInstances(
      keysOrIds
    );
    Map<Id, Integer> ownerRows = selectOwnerRows(resolved);
    Set<Id> cancelledIds = cancelOwners(requests, resolved, ownerRows);
    return assembleResults(resolved, ownerRows, cancelledIds);
  }

  /**
   * @description Picks the first row for each live instance. Skips rows with no
   * match and rows whose instance is already finished.
   * @param resolved The resolved instance per row (null where no match).
   * @return The owner row index for each live instance Id.
   */
  private static Map<Id, Integer> selectOwnerRows(
    List<Workflow_Instance__c> resolved
  ) {
    Map<Id, Integer> ownerRows = new Map<Id, Integer>();
    for (Integer i = 0; i < resolved.size(); i++) {
      Workflow_Instance__c inst = resolved[i];
      if (
        inst != null &&
        !TERMINAL_STATUSES.contains(inst.Status__c) &&
        !ownerRows.containsKey(inst.Id)
      ) {
        ownerRows.put(inst.Id, i);
      }
    }
    return ownerRows;
  }

  /**
   * @description Claims the keyed rows, then cancels the owner rows in one engine
   * call for each Run Compensations value. On an error, it rolls back the claims
   * and the cancels, then throws.
   * @param requests The cancel requests, in order.
   * @param resolved The resolved instance per row.
   * @param ownerRows The owner row index for each live instance Id.
   * @return The Ids that the engine cancelled.
   */
  private static Set<Id> cancelOwners(
    List<CancelRequest> requests,
    List<Workflow_Instance__c> resolved,
    Map<Id, Integer> ownerRows
  ) {
    if (ownerRows.isEmpty()) {
      return new Set<Id>();
    }
    Savepoint sp = Database.setSavepoint();
    Set<Id> duplicates = claimKeyedRows(requests, resolved, ownerRows, sp);
    List<Id> hardStopIds = new List<Id>();
    List<Id> rollbackIds = new List<Id>();
    for (Integer i = 0; i < resolved.size(); i++) {
      Workflow_Instance__c inst = resolved[i];
      if (!isOwner(inst, i, ownerRows) || duplicates.contains(inst.Id)) {
        continue;
      }
      if (requests[i].runCompensations == false) {
        hardStopIds.add(inst.Id);
      } else {
        rollbackIds.add(inst.Id);
      }
    }
    try {
      Set<Id> cancelledIds = WorkflowCancellation.cancelInstances(
        hardStopIds,
        false
      );
      cancelledIds.addAll(
        WorkflowCancellation.cancelInstances(rollbackIds, true)
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
   * @param requests The cancel requests, in order.
   * @param resolved The resolved instance per row.
   * @param ownerRows The owner row index for each live instance Id.
   * @param sp The savepoint to roll back on a claim error.
   * @return The instance Ids whose key was already claimed.
   */
  private static Set<Id> claimKeyedRows(
    List<CancelRequest> requests,
    List<Workflow_Instance__c> resolved,
    Map<Id, Integer> ownerRows,
    Savepoint sp
  ) {
    List<Workflow_Signal__c> claims = new List<Workflow_Signal__c>();
    List<Id> claimIds = new List<Id>();
    for (Integer i = 0; i < resolved.size(); i++) {
      Workflow_Instance__c inst = resolved[i];
      if (
        !isOwner(inst, i, ownerRows) ||
        String.isBlank(requests[i].idempotencyKey)
      ) {
        continue;
      }
      claims.add(
        WorkflowSignalBatchCancel.buildCancelClaim(
          inst.Id,
          CLAIM_SIGNAL_NAME,
          requests[i].idempotencyKey
        )
      );
      claimIds.add(inst.Id);
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
   * @description Tests whether a row is the owner row of its instance.
   * @param inst The resolved instance of the row (null allowed).
   * @param row The row index.
   * @param ownerRows The owner row index for each live instance Id.
   * @return True when the row owns the cancel of its instance.
   */
  private static Boolean isOwner(
    Workflow_Instance__c inst,
    Integer row,
    Map<Id, Integer> ownerRows
  ) {
    return inst != null && ownerRows.get(inst.Id) == row;
  }

  /**
   * @description Builds one result per row. Reads the status again (one query),
   * so each row shows the status after the cancel.
   * @param resolved The resolved instance per row.
   * @param ownerRows The owner row index for each live instance Id.
   * @param cancelledIds The Ids that the engine cancelled.
   * @return One result per row, in order.
   */
  private static List<CancelResult> assembleResults(
    List<Workflow_Instance__c> resolved,
    Map<Id, Integer> ownerRows,
    Set<Id> cancelledIds
  ) {
    Set<Id> foundIds = new Set<Id>();
    for (Workflow_Instance__c inst : resolved) {
      if (inst != null) {
        foundIds.add(inst.Id);
      }
    }
    Map<Id, Workflow_Instance__c> current = foundIds.isEmpty()
      ? new Map<Id, Workflow_Instance__c>()
      : new Map<Id, Workflow_Instance__c>(
          [
            SELECT Id, Status__c
            FROM Workflow_Instance__c
            WHERE Id IN :foundIds
            WITH SYSTEM_MODE
          ]
        );
    List<CancelResult> results = new List<CancelResult>();
    for (Integer i = 0; i < resolved.size(); i++) {
      Workflow_Instance__c inst = resolved[i];
      CancelResult res = new CancelResult();
      if (inst != null) {
        Workflow_Instance__c latest = current.get(inst.Id);
        res.found = true;
        res.workflowInstanceId = inst.Id;
        res.status = (latest == null) ? inst.Status__c : latest.Status__c;
        res.isCompensating = ROLLBACK_STATUSES.contains(res.status);
        res.cancelled =
          isOwner(inst, i, ownerRows) && cancelledIds.contains(inst.Id);
      }
      results.add(res);
    }
    return results;
  }
}
