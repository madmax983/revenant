/**
 * @description Step-execution persistence surface for the Revenant engine. Flushes
 * a `Workflow_Step_Execution__c` row (insert when transient, otherwise update) in
 * system mode after stamping its governor telemetry, distinguishing the normal
 * outcome from a crash-recorded outcome. Extracted from `WorkflowEngine`; the
 * internal Boolean crash flag stays private here and is never exposed on the
 * public surface. All DML executes in system mode.
 */
public inherited sharing class WorkflowStepExecStore {
  private static void populateTelemetry(
    Workflow_Step_Execution__c stepExec,
    Boolean isCrash
  ) {
    if (stepExec != null) {
      if (isCrash) {
        stepExec.CPU_Time_Ms__c = null;
        stepExec.SOQL_Query_Count__c = null;
        stepExec.Heap_Size_Bytes__c = null;
      } else {
        stepExec.CPU_Time_Ms__c = Limits.getCpuTime();
        stepExec.SOQL_Query_Count__c = Limits.getQueries();
        stepExec.Heap_Size_Bytes__c = Limits.getHeapSize();
      }
    }
  }

  /**
   * @description Persists a step execution (insert when transient, otherwise
   * update) in system mode after populating its telemetry, for the non-crash
   * case. Public so the extracted breadcrumb persistence can flush a transient
   * step execution before correlating its logs.
   * @param stepExec the step execution to persist
   */
  public static void saveStepExec(Workflow_Step_Execution__c stepExec) {
    saveStepExec(stepExec, false);
  }

  /**
   * @description Persists a step execution recorded by the crash handler, marking
   * its telemetry as a crash outcome. Public entry so the extracted
   * `WorkflowCrashHandler` can flush a crashed step execution without exposing the
   * internal Boolean crash flag.
   * @param stepExec the crashed step execution to persist
   */
  public static void saveStepExecAsCrash(Workflow_Step_Execution__c stepExec) {
    saveStepExec(stepExec, true);
  }

  private static void saveStepExec(
    Workflow_Step_Execution__c stepExec,
    Boolean isCrash
  ) {
    populateTelemetry(stepExec, isCrash);
    if (stepExec.Id == null) {
      Database.insert(stepExec, true, AccessLevel.SYSTEM_MODE);
    } else {
      Database.update(stepExec, true, AccessLevel.SYSTEM_MODE);
    }
  }
}
