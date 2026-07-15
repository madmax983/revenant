/**
 * @description Pure (DML-free) planning helpers for the orphan-instance reclaim
 * phase. Derives, per orphaned `Workflow_Instance__c`, the target step names to
 * reset and the orchestrator re-drive requests, writing into the shared
 * {@link WorkflowReclaim.ReclaimState}. Split out from {@link WorkflowReclaim}
 * so the planning and DML-execution phases are each scored independently and
 * stay within their complexity budgets. The only SOQL-free type resolution here
 * defers to `WorkflowTypeResolver`; no DML is performed.
 */
public inherited sharing class WorkflowReclaimPlanner {
  /**
   * @description Derive, per orphaned instance, the target step names to reset
   * and whether the instance carries pending compensations, populating the
   * shared state.
   * @param orphanedInstances the orphaned instances to plan
   * @param state the shared reclaim accumulator to populate
   */
  public static void buildReclaimPlan(
    List<Workflow_Instance__c> orphanedInstances,
    WorkflowReclaim.ReclaimState state
  ) {
    Map<String, String> initialStepByWorkflowName = new Map<String, String>();
    for (Workflow_Instance__c inst : orphanedInstances) {
      planReclaimForInstance(inst, state, initialStepByWorkflowName);
    }
  }

  /**
   * @description Compute the target steps and compensation flag for a single
   * orphaned instance, updating the shared state in place.
   * @param inst the orphaned instance to plan
   * @param state the shared reclaim accumulator to populate
   * @param initialStepByWorkflowName memoized initial step per workflow name
   */
  private static void planReclaimForInstance(
    Workflow_Instance__c inst,
    WorkflowReclaim.ReclaimState state,
    Map<String, String> initialStepByWorkflowName
  ) {
    state.instanceIds.add(inst.Id);
    Boolean isCompensatingOrCancelling = (inst.Status__c == 'Compensating' ||
    inst.Status__c == 'Cancelling');
    List<String> stack = new List<String>();
    if (
      isCompensatingOrCancelling &&
      String.isNotBlank(inst.Compensation_Stack__c)
    ) {
      stack = parseReclaimCompensationStack(inst);
    }
    Boolean hasCompensations = (stack != null && !stack.isEmpty());
    state.hasCompensationsByInstanceId.put(inst.Id, hasCompensations);

    List<String> targetStepNames = computeReclaimTargetSteps(
      inst,
      stack,
      hasCompensations
    );

    if (String.isBlank(inst.Current_Step__c) && !hasCompensations) {
      String initialStep = resolveReclaimInitialStep(
        inst.Workflow_Name__c,
        initialStepByWorkflowName
      );
      if (initialStep != null) {
        inst.Current_Step__c = initialStep;
        targetStepNames.add(initialStep);
      }
    }

    state.targetStepsByInstanceId.put(inst.Id, targetStepNames);
    state.allTargetStepNames.addAll(targetStepNames);
  }

  /**
   * @description Derive the target step names for reclaim from the instance
   * status, its compensation stack, and any comma-separated parallel current
   * steps.
   * @param inst the orphaned instance
   * @param stack the parsed compensation stack (may be empty)
   * @param hasCompensations whether the instance has pending compensations
   * @return the target step names to reset for the instance
   */
  private static List<String> computeReclaimTargetSteps(
    Workflow_Instance__c inst,
    List<String> stack,
    Boolean hasCompensations
  ) {
    Boolean isCompensatingOrCancelling = (inst.Status__c == 'Compensating' ||
    inst.Status__c == 'Cancelling');
    List<String> targetStepNames = new List<String>();
    if (isCompensatingOrCancelling && hasCompensations) {
      targetStepNames.add(stack[stack.size() - 1] + '_Compensate');
    } else if (String.isNotBlank(inst.Current_Step__c)) {
      if (inst.Current_Step__c.contains(',')) {
        for (String pStep : inst.Current_Step__c.split(',')) {
          targetStepNames.add(pStep.trim());
        }
      } else {
        targetStepNames.add(inst.Current_Step__c);
      }
    }
    return targetStepNames;
  }

  /**
   * @description Deserialize the compensation stack; malformed JSON yields an
   * empty stack.
   * @param inst the instance whose compensation stack to parse
   * @return the parsed stack, or an empty list on malformed JSON
   */
  private static List<String> parseReclaimCompensationStack(
    Workflow_Instance__c inst
  ) {
    try {
      return (List<String>) JSON.deserialize(
        inst.Compensation_Stack__c,
        List<String>.class
      );
    } catch (Exception ignored) {
      // Malformed Compensation_Stack__c; treat as having no compensations.
      return new List<String>();
    }
  }

  /**
   * @description Resolve (and memoize) a workflow's initial step name for
   * reclaim routing.
   * @param wflowName the workflow name to resolve
   * @param initialStepByWorkflowName memoized initial step per workflow name
   * @return the resolved initial step name, or null when unresolvable
   */
  private static String resolveReclaimInitialStep(
    String wflowName,
    Map<String, String> initialStepByWorkflowName
  ) {
    if (initialStepByWorkflowName.containsKey(wflowName)) {
      return initialStepByWorkflowName.get(wflowName);
    }
    String initialStep = null;
    Type wflowType = WorkflowTypeResolver.resolve(
      wflowName,
      WorkflowTypeResolver.extractNamespace(wflowName)
    );
    if (wflowType != null) {
      try {
        Object defObj = wflowType.newInstance();
        if (defObj instanceof WorkflowDefinition) {
          initialStep = ((WorkflowDefinition) defObj).getInitialStep();
        }
      } catch (Exception ignored) {
        // Workflow type not instantiable here; leave initialStep null.
      }
    }
    initialStepByWorkflowName.put(wflowName, initialStep);
    return initialStep;
  }

  /**
   * @description Build the orchestrator re-drive requests for a single reclaimed
   * instance.
   * @param inst the reclaimed instance
   * @param state the shared reclaim accumulator
   * @return the orchestrator requests to enqueue for the instance
   */
  public static List<WorkflowEngine.OrchestratorRequest> buildReclaimOrchestratorRequests(
    Workflow_Instance__c inst,
    WorkflowReclaim.ReclaimState state
  ) {
    List<WorkflowEngine.OrchestratorRequest> requests = new List<WorkflowEngine.OrchestratorRequest>();
    List<String> targetStepNames = state.targetStepsByInstanceId.get(inst.Id);
    Boolean hasCompensations = state.hasCompensationsByInstanceId.get(inst.Id);

    if (
      hasCompensations ||
      String.isBlank(inst.Current_Step__c) ||
      !inst.Current_Step__c.contains(',')
    ) {
      requests.add(new WorkflowEngine.OrchestratorRequest(inst.Id, null));
    } else {
      for (String targetStepName : targetStepNames) {
        String key = inst.Id + ':' + targetStepName;
        Workflow_Step_Execution__c stepExec = state.latestStepByName.get(key);
        if (
          stepExec == null ||
          (stepExec.Status__c != 'Completed' &&
          stepExec.Status__c != 'OperatorSkipped')
        ) {
          requests.add(
            new WorkflowEngine.OrchestratorRequest(inst.Id, targetStepName)
          );
        }
      }
    }
    return requests;
  }
}
