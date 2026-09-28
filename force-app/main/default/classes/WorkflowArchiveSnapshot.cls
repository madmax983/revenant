/**
 * @description Copies primary rows into {@link WorkflowArchiveRecord}s for the
 * archive sweep. SOQL only: it never changes a row. Step facts come from
 * {@link WorkflowEngine.StepHistoryEntry}, so the archive matches
 * `getHistory`.
 */
public inherited sharing class WorkflowArchiveSnapshot {
  /**
   * @description Builds one record for each instance Id.
   * @param instanceIds the instances to copy
   * @return the records. Unknown Ids are absent.
   */
  public static List<WorkflowArchiveRecord> build(Set<Id> instanceIds) {
    List<WorkflowArchiveRecord> out = new List<WorkflowArchiveRecord>();
    if (instanceIds == null || instanceIds.isEmpty()) {
      return out;
    }
    Datetime archivedAt = Datetime.now();
    Map<Id, WorkflowArchiveRecord> byId = new Map<Id, WorkflowArchiveRecord>();
    for (Workflow_Instance__c inst : [
      SELECT
        Id,
        Workflow_Name__c,
        Correlation_Key__c,
        Status__c,
        Error_Message__c,
        Failure_Category__c,
        Parent_Instance__c,
        CreatedDate,
        Terminal_At__c,
        Input__c,
        Output__c
      FROM Workflow_Instance__c
      WHERE Id IN :instanceIds
      WITH SYSTEM_MODE
    ]) {
      WorkflowArchiveRecord r = toRecord(inst);
      r.archivedAt = archivedAt;
      byId.put(inst.Id, r);
      out.add(r);
    }
    addSteps(byId);
    return out;
  }

  /**
   * @description Counts the step rows of one instance, up to a cap. The cap
   * bounds the query rows.
   * @param instanceId the instance
   * @param cap the maximum count
   * @return the step row count, at most `cap`
   */
  public static Integer countSteps(Id instanceId, Integer cap) {
    return [
      SELECT COUNT()
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c = :instanceId
      WITH SYSTEM_MODE
      LIMIT :cap
    ];
  }

  private static WorkflowArchiveRecord toRecord(Workflow_Instance__c inst) {
    WorkflowArchiveRecord r = new WorkflowArchiveRecord();
    r.instanceId = inst.Id;
    r.workflowName = inst.Workflow_Name__c;
    r.correlationKey = inst.Correlation_Key__c;
    r.status = inst.Status__c;
    r.errorMessage = inst.Error_Message__c;
    r.failureCategory = inst.Failure_Category__c;
    r.parentInstanceId = inst.Parent_Instance__c;
    r.createdAt = inst.CreatedDate;
    r.terminalAt = inst.Terminal_At__c;
    r.input = keepOrDrop(inst.Input__c, r);
    r.output = keepOrDrop(inst.Output__c, r);
    return r;
  }

  // Same order as WorkflowHistoryRead, so the sequence matches getHistory.
  private static void addSteps(Map<Id, WorkflowArchiveRecord> byId) {
    if (byId.isEmpty()) {
      return;
    }
    Set<Id> ids = byId.keySet();
    for (Workflow_Step_Execution__c row : [
      SELECT
        Id,
        Workflow_Instance__c,
        Step_Name__c,
        Status__c,
        Retry_Count__c,
        Error_Details__c,
        CreatedDate,
        LastModifiedDate
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c IN :ids
      WITH SYSTEM_MODE
      ORDER BY Workflow_Instance__c ASC, CreatedDate ASC, Id ASC
    ]) {
      WorkflowArchiveRecord r = byId.get(row.Workflow_Instance__c);
      WorkflowEngine.StepHistoryEntry e = new WorkflowEngine.StepHistoryEntry(
        row
      );
      WorkflowArchiveRecord.Step s = new WorkflowArchiveRecord.Step();
      s.sequence = r.steps.size() + 1;
      s.executionId = e.executionId;
      s.stepName = e.stepName;
      s.status = e.status;
      s.attempt = e.attempt;
      s.startedAt = e.startedAt;
      s.endedAt = e.endedAt;
      s.errorDetails = keepOrDropError(row.Error_Details__c, r);
      r.steps.add(s);
      r.stepCount = r.steps.size();
    }
  }

  // Offloaded payloads are not copied. See WorkflowArchiveRecord.
  private static String keepOrDrop(String stored, WorkflowArchiveRecord r) {
    if (
      stored != null && stored.startsWith(WorkflowPayloadCodecs.OFFLOAD_PREFIX)
    ) {
      r.droppedPayloadCount++;
      return WorkflowArchiveRecord.DROPPED_MARKER;
    }
    return stored;
  }

  // Error details can hold an offloaded failureData after the reason.
  private static String keepOrDropError(
    String stored,
    WorkflowArchiveRecord r
  ) {
    String replaced = WorkflowFailureDetails.replaceOffloadedData(
      stored,
      WorkflowArchiveRecord.DROPPED_MARKER
    );
    if (replaced == null) {
      return keepOrDrop(stored, r);
    }
    r.droppedPayloadCount++;
    return replaced;
  }
}
