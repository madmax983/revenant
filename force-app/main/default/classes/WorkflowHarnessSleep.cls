/**
 * Test-only sleep/retry marker maintenance for the WorkflowTestHarness. Clears the
 * wake markers (Sleep_Until__c / Async_Job_Id__c, and Status__c only while still
 * Suspended) exactly as the engine's watchdog / WorkflowSleepJob does, and — for
 * callout steps whose async job may already be gone — inspects the active step
 * executions to decide whether the instance is genuinely still waiting. CronTrigger
 * job existence is resolved via a single up-front lookup matched in memory.
 */
@IsTest
public inherited sharing class WorkflowHarnessSleep {
  /**
   * @description Clears the sleep/retry wake markers on an instance (never Status__c
   * or Current_Step__c unless the instance is still Suspended). This is the same field
   * reset the engine performs when its watchdog or WorkflowSleepJob wakes a sleeping
   * instance.
   * @param instanceId The workflow instance whose wake markers should be cleared.
   */
  public static void clearSleepMarkers(Id instanceId) {
    List<Workflow_Instance__c> insts = [
      SELECT Status__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
      WITH SYSTEM_MODE
    ];
    if (insts.isEmpty()) {
      return;
    }
    Workflow_Instance__c inst = insts[0];
    Workflow_Instance__c toUpdate = new Workflow_Instance__c(
      Id = instanceId,
      Sleep_Until__c = null,
      Async_Job_Id__c = null
    );
    if (inst.Status__c == 'Suspended') {
      toUpdate.Status__c = 'Running';
    }
    update as system toUpdate;
  }

  /**
   * @description Clears wake markers only when a Suspended instance is genuinely no
   * longer waiting, inspecting its active step executions (and any dynamic sleep jobs)
   * to distinguish a still-sleeping/retrying step from a normally pending one.
   * @param instanceId The workflow instance to inspect and conditionally clear.
   */
  public static void clearStaleSleepMarkers(Id instanceId) {
    List<Workflow_Instance__c> insts = [
      SELECT Status__c, Current_Step__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
      WITH SYSTEM_MODE
    ];
    if (insts.isEmpty()) {
      return;
    }
    Workflow_Instance__c inst = insts[0];
    if (inst.Status__c != 'Suspended') {
      clearSleepMarkers(instanceId);
      return;
    }

    MarkerScan scan = scanActiveSteps(instanceId, inst.Current_Step__c);
    if (scan.sleepOrRetry) {
      return;
    }

    Workflow_Instance__c toUpdate = new Workflow_Instance__c(
      Id = instanceId,
      Sleep_Until__c = null,
      Async_Job_Id__c = null
    );
    if (scan.normalPending && !scan.wait) {
      toUpdate.Status__c = 'Running';
    }
    update as system toUpdate;
  }

  private static MarkerScan scanActiveSteps(Id instanceId, String currentStep) {
    MarkerScan scan = new MarkerScan();
    if (String.isBlank(currentStep)) {
      return scan;
    }
    List<String> activeSteps = currentStep.split(',');
    Map<String, Workflow_Step_Execution__c> latest = latestStaleExecs(
      instanceId,
      activeSteps
    );
    // Hoisted out of the loop: fetch all sleep jobs for this instance once, then
    // match each per-step prefix in memory (no SOQL inside the loop).
    StepClassifier classifier = new StepClassifier(
      instanceId,
      dynamicSleepJobNames(instanceId)
    );
    for (String stepName : activeSteps) {
      classifier.classify(scan, latest.get(stepName.trim()), stepName.trim());
    }
    return scan;
  }

  private static Map<String, Workflow_Step_Execution__c> latestStaleExecs(
    Id instanceId,
    List<String> activeSteps
  ) {
    List<Workflow_Step_Execution__c> execs = [
      SELECT Step_Name__c, Status__c, SOQL_Query_Count__c, Output__c
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c = :instanceId AND Step_Name__c IN :activeSteps
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC, Id DESC
    ];
    Map<String, Workflow_Step_Execution__c> latest = new Map<String, Workflow_Step_Execution__c>();
    for (Workflow_Step_Execution__c se : execs) {
      if (!latest.containsKey(se.Step_Name__c)) {
        latest.put(se.Step_Name__c, se);
      }
    }
    return latest;
  }

  private static List<String> dynamicSleepJobNames(Id instanceId) {
    if (!WorkflowEngine.useDynamicScheduling) {
      return new List<String>();
    }
    return WorkflowHarnessCron.namesLike('WorkflowSleep_' + instanceId + '%');
  }

  /**
   * @description Detects whether a step output represents an engine-managed wait
   * state (timeout, child workflow, or approval) rather than a genuine sleep, by
   * probing the serialized output for the framework's reserved marker keys.
   * @param output The serialized step output JSON to inspect.
   * @return True if the output encodes a framework wait state; false otherwise.
   */
  public static Boolean isFrameworkWaitState(String output) {
    if (String.isBlank(output) || !output.trim().startsWith('{')) {
      return false;
    }
    try {
      Map<String, Object> data = (Map<String, Object>) JSON.deserializeUntyped(
        output
      );
      if (
        data != null &&
        (data.containsKey('$timeoutStep') ||
        data.containsKey('childWorkflowName') ||
        data.containsKey('childCorrelationKeys') ||
        data.containsKey('waitingForApproval'))
      ) {
        return true;
      }
    } catch (Exception ex) {
      return false;
    }
    return false;
  }

  private class MarkerScan {
    Boolean sleepOrRetry = false;
    Boolean wait = false;
    Boolean normalPending = false;
  }

  /**
   * Classifies each active step of a stale-marker candidate into one of three
   * buckets (still sleeping/retrying, framework wait, or normal pending), holding
   * the per-instance job lookup so the classification stays a two-argument call.
   */
  private class StepClassifier {
    private final Id instanceId;
    private final List<String> sleepJobNames;

    StepClassifier(Id instanceId, List<String> sleepJobNames) {
      this.instanceId = instanceId;
      this.sleepJobNames = sleepJobNames;
    }

    void classify(
      MarkerScan scan,
      Workflow_Step_Execution__c se,
      String stepName
    ) {
      if (
        se == null ||
        (se.Status__c == 'Pending' &&
        se.SOQL_Query_Count__c == null)
      ) {
        scan.normalPending = true;
        return;
      }
      if (se.Status__c == 'Retrying') {
        scan.sleepOrRetry = true;
        return;
      }
      if (!(se.Status__c == 'Pending' && se.SOQL_Query_Count__c != null)) {
        return;
      }
      if (isFrameworkWaitState(se.Output__c)) {
        scan.wait = true;
        return;
      }
      if (hasSleepJob(stepName)) {
        scan.sleepOrRetry = true;
      } else {
        scan.normalPending = true;
      }
    }

    private Boolean hasSleepJob(String stepName) {
      if (!WorkflowEngine.useDynamicScheduling) {
        return true;
      }
      return WorkflowHarnessCron.anyStartsWith(
        sleepJobNames,
        WorkflowStepTimeoutConfig.getSleepJobPrefix(instanceId, stepName)
      );
    }
  }
}
