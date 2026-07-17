/**
 * @description Bulk signal-or-start orchestrator for the durable-execution
 * engine. For each request it resolves the target instance by the embedded start
 * request's correlation key (get-or-start), then delivers the signal, starting a
 * new instance when none exists. The whole batch runs under one savepoint so a
 * mid-batch failure rolls back cleanly. This class owns the phase sequence, the
 * shared `SignalOrStartRun` accumulator, the start-request intake and the
 * existing-instance lock query; the cancel pre-pass lives on
 * `WorkflowSignalOrStartCancel`, the signal-record prepare/insert on
 * `WorkflowSignalOrStartPrepare`, and the wake/enqueue on
 * `WorkflowSignalOrStartWake`. All DML/SOQL runs in system mode.
 */
public inherited sharing class WorkflowSignalOrStartService {
  /**
   * @description Mutable accumulator threaded through the signalOrStart phase
   * classes. Public (with public fields) so the extracted cancel, prepare and
   * wake phase classes can read and populate it as the batch advances; carries no
   * static members.
   */
  public class SignalOrStartRun {
    public List<WorkflowEngine.SignalOrStartRequest> requests;
    public System.Savepoint sp;
    public List<WorkflowEngine.StartResult> startResults;
    public Map<Id, Workflow_Instance__c> existingInstances = new Map<Id, Workflow_Instance__c>();
    public Set<Id> cancelledInstanceIds = new Set<Id>();
    public Set<Id> activeInstIdsToWake = new Set<Id>();
    public List<Workflow_Signal__c> signalsToInsert = new List<Workflow_Signal__c>();
    public List<Id> signalsInstIds = new List<Id>();
    public Set<Id> instancesWithFreshSignal = new Set<Id>();
    public Set<Id> gatedNonReadyParents = new Set<Id>();
    public List<Workflow_Instance__c> instancesToUpdate = new List<Workflow_Instance__c>();
    public List<Workflow_Instance__c> instancesToWake = new List<Workflow_Instance__c>();
  }

  /**
   * @description Bulk signal-or-start. For each request, resolves the target
   * instance by the embedded start request's correlation key and delivers the
   * signal, starting a new instance when none exists. Runs under a savepoint so a
   * mid-batch failure rolls back cleanly.
   * @param requests the signal-or-start requests to process
   * @return StartResults index-aligned with requests
   */
  public static List<WorkflowEngine.StartResult> signalOrStartBulk(
    List<WorkflowEngine.SignalOrStartRequest> requests
  ) {
    if (requests == null || requests.isEmpty()) {
      return new List<WorkflowEngine.StartResult>();
    }

    System.Savepoint sp = Database.setSavepoint();
    SignalOrStartRun run = new SignalOrStartRun();
    run.requests = requests;
    run.sp = sp;

    try {
      // 1. Gather all start requests and call startOrGet bulk
      run.startResults = WorkflowStartService.startOrGetBulk(
        buildSignalOrStartRequests(requests)
      );

      // 2. Query details of existing instances to determine active vs terminal
      run.existingInstances = querySignalOrStartExisting(run);

      // 3. Prepare keyed cancel claims and run cancellations
      WorkflowSignalOrStartCancel.processSignalOrStartCancels(run);

      // 4. Prepare ordinary signal records to insert and identify active instances to wake
      WorkflowSignalOrStartPrepare.prepareSignalOrStartRecords(run);

      // 5. Insert signals
      WorkflowSignalOrStartPrepare.insertSignalOrStartSignals(run);

      // 6. Wake active instances that received a fresh signal
      WorkflowSignalOrStartWake.wakeSignalOrStartInstances(run);

      return run.startResults;
    } catch (Exception e) {
      Database.rollback(sp);
      WorkflowResumeEnqueue.clearEnqueueGuards(run.activeInstIdsToWake);
      throw e;
    }
  }

  // §1: map each signal-or-start request to its embedded StartRequest (null
  // preserved for a null request), rejecting a null embedded start.
  private static List<WorkflowEngine.StartRequest> buildSignalOrStartRequests(
    List<WorkflowEngine.SignalOrStartRequest> requests
  ) {
    List<WorkflowEngine.StartRequest> startReqs = new List<WorkflowEngine.StartRequest>();
    for (WorkflowEngine.SignalOrStartRequest req : requests) {
      if (req == null) {
        startReqs.add(null);
        continue;
      }
      if (req.start == null) {
        throw new WorkflowEngine.WorkflowException(
          'StartRequest cannot be null in SignalOrStartRequest'
        );
      }
      startReqs.add(req.start);
    }
    return startReqs;
  }

  // §2: FOR UPDATE-lock the existing (deduped, non-new) instances so their live
  // status can be inspected for cancel/wake decisions.
  private static Map<Id, Workflow_Instance__c> querySignalOrStartExisting(
    SignalOrStartRun run
  ) {
    List<WorkflowEngine.SignalOrStartRequest> requests = run.requests;
    List<WorkflowEngine.StartResult> startResults = run.startResults;
    Set<Id> existingIds = new Set<Id>();
    for (Integer i = 0; i < requests.size(); i++) {
      WorkflowEngine.SignalOrStartRequest req = requests[i];
      if (req == null) {
        continue;
      }
      WorkflowEngine.StartResult res = startResults[i];
      if (res != null && !res.isNew) {
        existingIds.add(res.instanceId);
      }
    }

    Map<Id, Workflow_Instance__c> existingInstances = new Map<Id, Workflow_Instance__c>();
    if (!existingIds.isEmpty()) {
      existingInstances = new Map<Id, Workflow_Instance__c>(
        [
          SELECT
            Id,
            Status__c,
            Current_Step__c,
            Concurrency_Parked__c,
            Concurrency_Slot_Held__c,
            Sleep_Until__c
          FROM Workflow_Instance__c
          WHERE Id IN :existingIds
          WITH SYSTEM_MODE
          FOR UPDATE
        ]
      );
    }
    return existingInstances;
  }
}
