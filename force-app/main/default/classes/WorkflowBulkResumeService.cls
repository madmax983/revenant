/**
 * @description Bulk manual-resume surface for the Revenant engine. Resumes many
 * suspended workflow instances in a single bulk-friendly transaction from a batch
 * of `WorkflowEngine.ResumeRequest`s (each targeting an instance by Id or by
 * correlation key): every matched instance is flipped to Running with its
 * timed-wait deadline disarmed (issue #35), its matched active step execution (if
 * any) resumed with the request payload, and its step timeout re-armed before the
 * orchestrators are enqueued. Split from {@link WorkflowResumeService} to keep each
 * class within its own complexity budget. The resident
 * `WorkflowEngine.WorkflowException` and `WorkflowEngine.ResumeRequest` types are
 * referenced fully qualified. All SOQL/DML executes in system mode and the
 * instance/step locking (FOR UPDATE) and statement order are preserved from the
 * pre-extraction engine.
 */
public inherited sharing class WorkflowBulkResumeService {
  /**
   * @description Lookup index of the suspended instances found for a batch of
   * resume requests, keyed by both Id and correlation key.
   */
  private class ResumeInstanceIndex {
    Map<Id, Workflow_Instance__c> instById = new Map<Id, Workflow_Instance__c>();
    Map<String, Workflow_Instance__c> instByKey = new Map<String, Workflow_Instance__c>();
  }

  /**
   * @description Accumulated instance and step-execution records to persist for a
   * batch of resume requests.
   */
  private class ResumeUpdates {
    List<Workflow_Instance__c> instancesToUpdate = new List<Workflow_Instance__c>();
    List<Workflow_Step_Execution__c> stepsToUpdate = new List<Workflow_Step_Execution__c>();
  }

  /**
   * @description The instance ids and correlation keys to look up for a batch of
   * resume requests. A request contributes its explicit instance id, or (when it
   * carries none) its correlation key.
   */
  private class ResumeLookup {
    Set<Id> ids = new Set<Id>();
    Set<String> keys = new Set<String>();
  }

  /**
   * @description Collects, in a single pass, the explicit instance ids referenced
   * by the resume requests and the correlation keys of the requests that do not
   * carry an explicit instance id.
   * @param requests the resume requests
   * @return the ids and correlation keys used for lookup
   */
  private static ResumeLookup collectResumeLookup(
    List<WorkflowEngine.ResumeRequest> requests
  ) {
    ResumeLookup lookup = new ResumeLookup();
    for (WorkflowEngine.ResumeRequest req : requests) {
      if (req.instanceId != null) {
        lookup.ids.add(req.instanceId);
      } else if (String.isNotBlank(req.correlationKey)) {
        lookup.keys.add(req.correlationKey);
      }
    }
    return lookup;
  }

  /**
   * @description Builds the by-Id and by-correlation-key lookup index over the
   * queried suspended instances.
   * @param instances the suspended instances found for the batch
   * @return the populated lookup index
   */
  private static ResumeInstanceIndex buildResumeInstanceIndex(
    List<Workflow_Instance__c> instances
  ) {
    ResumeInstanceIndex index = new ResumeInstanceIndex();
    for (Workflow_Instance__c inst : instances) {
      index.instById.put(inst.Id, inst);
      if (String.isNotBlank(inst.Correlation_Key__c)) {
        index.instByKey.put(inst.Correlation_Key__c, inst);
      }
    }
    return index;
  }

  /**
   * @description Resolves the suspended instance targeted by a resume request,
   * preferring an explicit instance id and falling back to the correlation key.
   * @param req the resume request
   * @param index the instance lookup index
   * @return the matching instance, or null when none was found
   */
  private static Workflow_Instance__c resolveResumeInstance(
    WorkflowEngine.ResumeRequest req,
    ResumeInstanceIndex index
  ) {
    if (req.instanceId != null) {
      return index.instById.get(req.instanceId);
    }
    if (String.isNotBlank(req.correlationKey)) {
      return index.instByKey.get(req.correlationKey);
    }
    return null;
  }

  /**
   * @description Verifies that a suspended instance was found for every resume
   * request, throwing if any request cannot be satisfied.
   * @param requests the resume requests
   * @param index the instance lookup index
   */
  private static void verifyAllResumeTargetsFound(
    List<WorkflowEngine.ResumeRequest> requests,
    ResumeInstanceIndex index
  ) {
    for (WorkflowEngine.ResumeRequest req : requests) {
      Workflow_Instance__c inst = resolveResumeInstance(req, index);
      if (inst == null) {
        throw new WorkflowEngine.WorkflowException(
          'No suspended workflow found with key or ID: ' +
          (req.instanceId != null
            ? (String) req.instanceId
            : req.correlationKey)
        );
      }
    }
  }

  /**
   * @description Tests whether a step name is (one of) the instance's current
   * active step(s), supporting comma-separated parallel branch step names.
   * @param inst the instance whose Current_Step__c is inspected
   * @param stepName the step execution's step name to test
   * @return true when the step name matches the instance's current step
   */
  private static Boolean stepMatchesCurrentStep(
    Workflow_Instance__c inst,
    String stepName
  ) {
    if (inst == null || String.isBlank(inst.Current_Step__c)) {
      return false;
    }
    if (inst.Current_Step__c.contains(',')) {
      for (String pStep : inst.Current_Step__c.split(',')) {
        if (pStep.trim() == stepName) {
          return true;
        }
      }
      return false;
    }
    return inst.Current_Step__c == stepName;
  }

  /**
   * @description Picks the latest active step execution per instance that matches
   * the instance's current step, from a list ordered newest-first.
   * @param allActiveSteps the instances' step executions, newest first
   * @param instById the instance lookup by id
   * @return the matching latest step execution per instance id
   */
  private static Map<Id, Workflow_Step_Execution__c> buildLatestStepByInstanceId(
    List<Workflow_Step_Execution__c> allActiveSteps,
    Map<Id, Workflow_Instance__c> instById
  ) {
    Map<Id, Workflow_Step_Execution__c> latestStepByInstanceId = new Map<Id, Workflow_Step_Execution__c>();
    for (Workflow_Step_Execution__c step : allActiveSteps) {
      if (!latestStepByInstanceId.containsKey(step.Workflow_Instance__c)) {
        Workflow_Instance__c inst = instById.get(step.Workflow_Instance__c);
        if (stepMatchesCurrentStep(inst, step.Step_Name__c)) {
          latestStepByInstanceId.put(step.Workflow_Instance__c, step);
        }
      }
    }
    return latestStepByInstanceId;
  }

  /**
   * @description Applies the resume mutation to a matched step execution: marks it
   * Running, persists the resume payload as its output, and (re)arms its step
   * timeout.
   * @param stepExec the step execution to mutate
   * @param inst the owning instance (for id, current step and namespace)
   * @param payload the resume payload to persist
   */
  private static void applyResumeToStep(
    Workflow_Step_Execution__c stepExec,
    Workflow_Instance__c inst,
    String payload
  ) {
    stepExec.Status__c = 'Running';
    stepExec.Output__c = WorkflowPayloadOffload.savePayloadIfNeeded(
      inst.Id,
      payload,
      'Resume_' + stepExec.Id
    );
    Integer timeout = WorkflowStepTimeoutConfig.getStepTimeoutSeconds(
      inst.Current_Step__c,
      WorkflowTypeResolver.extractNamespace(inst.Workflow_Name__c)
    );
    if (timeout != null && timeout > 0) {
      stepExec.Timeout_At__c = DateTime.now().addSeconds(timeout);
    } else {
      stepExec.Timeout_At__c = null;
    }
  }

  /**
   * @description Builds the pending instance/step-execution mutations for a batch
   * of resume requests: each matched instance is flipped to Running with its
   * timed-wait disarmed, and its matched step execution (if any) is resumed.
   * @param requests the resume requests
   * @param index the instance lookup index
   * @param latestStepByInstanceId the matched latest step execution per instance
   * @return the accumulated records to update
   */
  private static ResumeUpdates buildResumeUpdates(
    List<WorkflowEngine.ResumeRequest> requests,
    ResumeInstanceIndex index,
    Map<Id, Workflow_Step_Execution__c> latestStepByInstanceId
  ) {
    ResumeUpdates updates = new ResumeUpdates();
    for (WorkflowEngine.ResumeRequest req : requests) {
      Workflow_Instance__c inst = resolveResumeInstance(req, index);
      if (inst == null) {
        continue;
      }
      inst.Status__c = 'Running';
      // Disarm any armed timed-wait timeout so the watchdog does not mis-route
      // to the fallback step after a manual resume wins the race (issue #35).
      inst.Sleep_Until__c = null;
      updates.instancesToUpdate.add(inst);

      Workflow_Step_Execution__c stepExec = latestStepByInstanceId.get(inst.Id);
      if (stepExec != null) {
        applyResumeToStep(stepExec, inst, req.payload);
        updates.stepsToUpdate.add(stepExec);
      }
    }
    return updates;
  }

  /**
   * @description Resumes multiple suspended workflows in a bulk-friendly
   * transaction.
   * @param requests the resume requests to process
   */
  public static void resume(List<WorkflowEngine.ResumeRequest> requests) {
    if (requests == null || requests.isEmpty()) {
      return;
    }

    ResumeLookup lookup = collectResumeLookup(requests);

    List<Workflow_Instance__c> instances = [
      SELECT Id, Workflow_Name__c, Current_Step__c, Correlation_Key__c
      FROM Workflow_Instance__c
      WHERE
        (Id IN :lookup.ids
        OR Correlation_Key__c IN :lookup.keys)
        AND Status__c = 'Suspended'
      WITH SYSTEM_MODE
      FOR UPDATE
    ];

    ResumeInstanceIndex index = buildResumeInstanceIndex(instances);

    // Verify that we found a suspended instance for every request
    verifyAllResumeTargetsFound(requests, index);

    // Gathers active step execution logs for the instances in bulk
    Set<Id> activeInstIds = index.instById.keySet();
    List<Workflow_Step_Execution__c> allActiveSteps = [
      SELECT Id, Workflow_Instance__c, Step_Name__c, Status__c, Output__c
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c IN :activeInstIds
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC, Id DESC
    ];

    Map<Id, Workflow_Step_Execution__c> latestStepByInstanceId = buildLatestStepByInstanceId(
      allActiveSteps,
      index.instById
    );

    ResumeUpdates updates = buildResumeUpdates(
      requests,
      index,
      latestStepByInstanceId
    );

    Database.update(updates.instancesToUpdate, true, AccessLevel.SYSTEM_MODE);
    if (!updates.stepsToUpdate.isEmpty()) {
      Database.update(updates.stepsToUpdate, true, AccessLevel.SYSTEM_MODE);
    }

    WorkflowTimeoutArming.scheduleTimeoutJobsForInstances(
      updates.instancesToUpdate
    );

    List<Id> instanceIds = new List<Id>();
    for (Workflow_Instance__c inst : updates.instancesToUpdate) {
      instanceIds.add(inst.Id);
    }
    WorkflowOrchestratorEnqueue.enqueueOrchestrators(instanceIds);
  }
}
