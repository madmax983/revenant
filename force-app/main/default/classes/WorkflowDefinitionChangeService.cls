/**
 * @description Operator side of the DefinitionChanged park (issue #89).
 * `release` accepts the live definition shape for one parked instance and
 * resumes it. `describe` builds the stored-versus-live diagnosis for the
 * dashboard. Step names compare without case, the same as the fingerprint.
 * All DML and SOQL run in system mode. Callers own the permission checks.
 */
public inherited sharing class WorkflowDefinitionChangeService {
  /**
   * @description Releases one DefinitionChanged instance. It re-stamps the live
   * fingerprint and shape, sets Running, re-arms step timeouts, and enqueues the
   * current step (or each open parallel branch). A timer from a wait that ended
   * in the park gives Suspended and no enqueue.
   * @param instanceId The parked instance.
   * @throws WorkflowEngine.WorkflowException When the instance is not parked,
   * the live definition does not resolve, or a current step is not in the live
   * step list.
   */
  public static void release(Id instanceId) {
    List<Workflow_Instance__c> rows = [
      SELECT Id, Status__c, Workflow_Name__c, Current_Step__c, Sleep_Until__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
      WITH SYSTEM_MODE
      FOR UPDATE
    ];
    if (
      rows.isEmpty() || rows[0].Status__c != WorkflowDefinitionChangeGate.STATUS
    ) {
      throw new WorkflowEngine.WorkflowException(
        'Instance ' +
          instanceId +
          ' is not in ' +
          WorkflowDefinitionChangeGate.STATUS +
          ' status.'
      );
    }
    Workflow_Instance__c inst = rows[0];
    List<String> liveSteps = WorkflowDefinitionFingerprint.liveSteps(
      WorkflowDefinitionFingerprint.resolve(inst.Workflow_Name__c)
    );
    if (liveSteps == null) {
      throw new WorkflowEngine.WorkflowException(
        'Cannot read the live definition ' + inst.Workflow_Name__c + '.'
      );
    }
    List<String> missing = missingCurrentSteps(
      inst.Id,
      inst.Current_Step__c,
      liveSteps
    );
    if (!missing.isEmpty()) {
      throw new WorkflowEngine.WorkflowException(
        'Current step ' +
          String.join(missing, ', ') +
          ' is not in the live definition. Restore the step or cancel the instance.'
      );
    }

    inst.Definition_Fingerprint__c = WorkflowDefinitionFingerprint.compute(
      liveSteps
    );
    inst.Definition_Shape__c = WorkflowDefinitionFingerprint.shapeJson(
      liveSteps
    );
    Boolean waiting = WorkflowParkedTimer.settle(inst);
    inst.Error_Message__c = null;
    Database.update(inst, true, AccessLevel.SYSTEM_MODE);
    // Strict determinism (issue #102): the live code can make a new decision.
    WorkflowDeterminismGuard.clearRecords(inst.Id, inst.Current_Step__c);

    WorkflowLog.warn(
      'DefinitionChanged',
      'Released onto the live definition by user ' + UserInfo.getUserId(),
      inst.Id
    );
    if (waiting) {
      return; // A wait ended in the park. The sweep wakes it.
    }
    // Re-arm before enqueue so a delayed worker still has a deadline.
    WorkflowTimeoutReArm.reArmTimeoutsForResume(
      new List<Workflow_Instance__c>{ inst }
    );
    enqueue(inst);
  }

  // Serial: one orchestrator for the current step. Parallel: one per open branch.
  private static void enqueue(Workflow_Instance__c inst) {
    if (
      String.isNotBlank(inst.Current_Step__c) &&
      inst.Current_Step__c.contains(',')
    ) {
      WorkflowBranchResume.enqueueResumeBulk(
        new List<Workflow_Instance__c>{ inst }
      );
      return;
    }
    if (!(Test.isRunningTest() && WorkflowEngine.disableQueueableInTest)) {
      WorkflowOrchestratorEnqueue.enqueueOrchestrators(new List<Id>{ inst.Id });
    }
  }

  /**
   * @description Builds the dashboard diagnosis for a DefinitionChanged
   * instance. The instance must carry Status__c, Current_Step__c,
   * Workflow_Name__c, Definition_Fingerprint__c and Definition_Shape__c.
   * @param instance The instance record.
   * @return The diagnosis map, or null when the instance is not parked.
   */
  public static Map<String, Object> describe(Workflow_Instance__c instance) {
    if (
      instance == null ||
      instance.Status__c != WorkflowDefinitionChangeGate.STATUS
    ) {
      return null;
    }
    List<String> stored = WorkflowDefinitionFingerprint.parseShape(
      instance.Definition_Shape__c
    );
    List<String> live = WorkflowDefinitionFingerprint.liveSteps(
      WorkflowDefinitionFingerprint.resolve(instance.Workflow_Name__c)
    );
    List<String> storedList = stored == null ? new List<String>() : stored;
    List<String> liveList = live == null ? new List<String>() : live;
    // A diff needs both lists. Without one, report no added or removed steps.
    Boolean canDiff = stored != null && live != null;
    return new Map<String, Object>{
      'storedSteps' => storedList,
      'liveSteps' => liveList,
      'storedAvailable' => stored != null,
      'liveAvailable' => live != null,
      'addedSteps' => canDiff
        ? difference(liveList, storedList)
        : new List<String>(),
      'removedSteps' => canDiff
        ? difference(storedList, liveList)
        : new List<String>(),
      'storedFingerprint' => instance.Definition_Fingerprint__c,
      'liveFingerprint' => live == null
        ? null
        : WorkflowDefinitionFingerprint.compute(live),
      'currentStep' => instance.Current_Step__c,
      'currentStepInLive' => live != null &&
      missingCurrentSteps(instance.Id, instance.Current_Step__c, live).isEmpty()
    };
  }

  // Open current steps (one, or the unfinished parallel branches) that are not
  // in liveSteps. A finished branch is not checked: release does not run it.
  private static List<String> missingCurrentSteps(
    Id instanceId,
    String currentStep,
    List<String> liveSteps
  ) {
    List<String> missing = new List<String>();
    Set<String> liveKeys = keys(liveSteps);
    for (String step : openCurrentSteps(instanceId, currentStep)) {
      if (!liveKeys.contains(key(step))) {
        missing.add(step);
      }
    }
    return missing;
  }

  // The current step, or for a parallel list the branches whose latest row is
  // not Completed or OperatorSkipped. A serial step needs no query.
  private static List<String> openCurrentSteps(
    Id instanceId,
    String currentStep
  ) {
    List<String> steps = new List<String>();
    if (String.isBlank(currentStep)) {
      return steps;
    }
    for (String step : currentStep.split(',')) {
      steps.add(step.trim());
    }
    if (steps.size() < 2 || instanceId == null) {
      return steps;
    }
    Map<String, String> latestStatus = new Map<String, String>();
    for (Workflow_Step_Execution__c exec : [
      SELECT Step_Name__c, Status__c
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c = :instanceId AND Step_Name__c IN :steps
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC, Id DESC
    ]) {
      if (!latestStatus.containsKey(exec.Step_Name__c)) {
        latestStatus.put(exec.Step_Name__c, exec.Status__c);
      }
    }
    List<String> open = new List<String>();
    for (String step : steps) {
      String status = latestStatus.get(step);
      if (status != 'Completed' && status != 'OperatorSkipped') {
        open.add(step);
      }
    }
    return open;
  }

  // Names in left that are not in right, in left order.
  private static List<String> difference(
    List<String> left,
    List<String> right
  ) {
    Set<String> rightKeys = keys(right);
    List<String> result = new List<String>();
    for (String step : left) {
      if (!rightKeys.contains(key(step))) {
        result.add(step);
      }
    }
    return result;
  }

  private static Set<String> keys(List<String> steps) {
    Set<String> result = new Set<String>();
    for (String step : steps) {
      result.add(key(step));
    }
    return result;
  }

  private static String key(String step) {
    return step == null ? '' : step.trim().toLowerCase();
  }
}
