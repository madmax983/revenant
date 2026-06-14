public inherited sharing class WorkflowEngine {
  public static Boolean disableQueueableInTest = false;
  @TestVisible
  private static Set<Id> enqueuedInstanceIds = new Set<Id>();
  public class WorkflowException extends Exception {
  }

  /**
   * Starts a new durable workflow instance.
   */
  public static Id start(
    String workflowName,
    String correlationKey,
    Object input
  ) {
    validateCorrelationKey(correlationKey);
    // Enforce uniqueness of active correlation keys if provided
    if (String.isNotBlank(correlationKey)) {
      List<Workflow_Instance__c> existing = [
        SELECT Id
        FROM Workflow_Instance__c
        WHERE
          Correlation_Key__c = :correlationKey
          AND Status__c IN ('Pending', 'Running', 'Suspended')
        WITH SYSTEM_MODE
        LIMIT 1
      ];
      if (!existing.isEmpty()) {
        throw new WorkflowException(
          'An active workflow already exists with correlation key: ' +
          correlationKey
        );
      }
    }

    Workflow_Instance__c instance = new Workflow_Instance__c();
    instance.Workflow_Name__c = workflowName;
    instance.Status__c = 'Pending';
    instance.Correlation_Key__c = correlationKey;

    // Resolve version and initial step
    Type wflowType = Type.forName(workflowName);
    if (wflowType != null) {
      Object defObj = wflowType.newInstance();
      if (defObj instanceof VersionedWorkflow) {
        instance.Definition_Version__c = ((VersionedWorkflow) defObj)
          .getLatestVersion();
      } else {
        instance.Definition_Version__c = 1;
      }
      if (defObj instanceof WorkflowDefinition) {
        instance.Current_Step__c = ((WorkflowDefinition) defObj)
          .getInitialStep();
      }
    } else {
      instance.Definition_Version__c = 1;
    }

    try {
      insert as system instance;
    } catch (DmlException ex) {
      if (ex.getDmlStatusCode(0) == 'DUPLICATE_VALUE') {
        throw new WorkflowException(
          'An active workflow already exists with correlation key: ' +
          correlationKey
        );
      }
      throw ex;
    }

    instance.Input__c = savePayloadIfNeeded(
      instance.Id,
      (input != null) ? JSON.serialize(input) : null,
      'Input_' + instance.Id
    );
    update as system instance;

    if (String.isNotBlank(instance.Current_Step__c)) {
      Workflow_Step_Execution__c stepExec = new Workflow_Step_Execution__c();
      stepExec.Workflow_Instance__c = instance.Id;
      stepExec.Step_Name__c = instance.Current_Step__c;
      stepExec.Status__c = 'Pending';
      stepExec.Input__c = instance.Input__c;
      stepExec.Retry_Count__c = 0;
      insert as system stepExec;
    }

    // Schedule watchdog for the initial step before executing it
    scheduleTimeoutJobForInstance(instance.Id);

    // Enqueue the first step execution
    if (Test.isRunningTest()) {
      System.enqueueJob(new WorkflowOrchestrator(instance.Id));
    } else {
      enqueueOrchestrator(instance.Id, null);
    }
    return instance.Id;
  }

  /**
   * Starts a new durable workflow instance with a parent workflow reference.
   */
  public static Id start(
    String workflowName,
    String correlationKey,
    Object input,
    Id parentInstanceId
  ) {
    validateCorrelationKey(correlationKey);
    if (String.isNotBlank(correlationKey)) {
      List<Workflow_Instance__c> existing = [
        SELECT Id
        FROM Workflow_Instance__c
        WHERE
          Correlation_Key__c = :correlationKey
          AND Status__c IN ('Pending', 'Running', 'Suspended')
        WITH SYSTEM_MODE
        LIMIT 1
      ];
      if (!existing.isEmpty()) {
        throw new WorkflowException(
          'An active workflow already exists with correlation key: ' +
          correlationKey
        );
      }
    }

    Workflow_Instance__c instance = new Workflow_Instance__c();
    instance.Workflow_Name__c = workflowName;
    instance.Status__c = 'Pending';
    instance.Correlation_Key__c = correlationKey;
    instance.Parent_Instance__c = parentInstanceId;

    // Resolve version and initial step
    Type wflowType = Type.forName(workflowName);
    if (wflowType != null) {
      Object defObj = wflowType.newInstance();
      if (defObj instanceof VersionedWorkflow) {
        instance.Definition_Version__c = ((VersionedWorkflow) defObj)
          .getLatestVersion();
      } else {
        instance.Definition_Version__c = 1;
      }
      if (defObj instanceof WorkflowDefinition) {
        instance.Current_Step__c = ((WorkflowDefinition) defObj)
          .getInitialStep();
      }
    } else {
      instance.Definition_Version__c = 1;
    }

    try {
      insert as system instance;
    } catch (DmlException ex) {
      if (ex.getDmlStatusCode(0) == 'DUPLICATE_VALUE') {
        throw new WorkflowException(
          'An active workflow already exists with correlation key: ' +
          correlationKey
        );
      }
      throw ex;
    }

    instance.Input__c = savePayloadIfNeeded(
      instance.Id,
      (input != null) ? JSON.serialize(input) : null,
      'Input_' + instance.Id
    );
    update as system instance;

    if (String.isNotBlank(instance.Current_Step__c)) {
      Workflow_Step_Execution__c stepExec = new Workflow_Step_Execution__c();
      stepExec.Workflow_Instance__c = instance.Id;
      stepExec.Step_Name__c = instance.Current_Step__c;
      stepExec.Status__c = 'Pending';
      stepExec.Input__c = instance.Input__c;
      stepExec.Retry_Count__c = 0;
      insert as system stepExec;
    }

    // Schedule watchdog for the initial step before executing it
    scheduleTimeoutJobForInstance(instance.Id);

    if (Test.isRunningTest()) {
      System.enqueueJob(new WorkflowOrchestrator(instance.Id));
    } else {
      enqueueOrchestrator(instance.Id, null);
    }
    return instance.Id;
  }

  /**
   * Resumes a suspended workflow matching the correlation key.
   */
  public static void resume(String correlationKey, String payload) {
    List<Workflow_Instance__c> instances = [
      SELECT Id, Workflow_Name__c, Current_Step__c
      FROM Workflow_Instance__c
      WHERE Correlation_Key__c = :correlationKey AND Status__c = 'Suspended'
      WITH SYSTEM_MODE
      LIMIT 1
      FOR UPDATE
    ];

    if (instances.isEmpty()) {
      throw new WorkflowException(
        'No suspended workflow found with correlation key: ' + correlationKey
      );
    }

    Workflow_Instance__c instance = instances[0];
    instance.Status__c = 'Running';
    update as system instance;

    // If there is an active step, we can store the resume payload in its step execution record
    if (String.isNotBlank(instance.Current_Step__c)) {
      List<Workflow_Step_Execution__c> activeSteps = [
        SELECT Id, Output__c
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :instance.Id
          AND Step_Name__c = :instance.Current_Step__c
        WITH SYSTEM_MODE
        ORDER BY CreatedDate DESC, Id DESC
        LIMIT 1
      ];
      if (!activeSteps.isEmpty()) {
        Workflow_Step_Execution__c stepExec = activeSteps[0];
        stepExec.Status__c = 'Running';
        stepExec.Output__c = savePayloadIfNeeded(
          instance.Id,
          payload,
          'Resume_' + stepExec.Id
        );
        update as system stepExec;
      }
    }

    scheduleTimeoutJobForInstance(instance.Id);

    if (Test.isRunningTest()) {
      System.enqueueJob(new WorkflowOrchestrator(instance.Id));
    } else {
      enqueueOrchestrator(instance.Id, null);
    }
  }

  /**
   * Resumes a suspended workflow instance directly by its database ID.
   */
  public static void resumeInstance(Id instanceId, String payload) {
    List<Workflow_Instance__c> instances = [
      SELECT Id, Workflow_Name__c, Current_Step__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId AND Status__c = 'Suspended'
      WITH SYSTEM_MODE
      LIMIT 1
      FOR UPDATE
    ];

    if (instances.isEmpty()) {
      throw new WorkflowException(
        'No suspended workflow found with ID: ' + instanceId
      );
    }

    Workflow_Instance__c instance = instances[0];
    instance.Status__c = 'Running';
    update as system instance;

    // If there is an active step, we can store the resume payload in its step execution record
    if (String.isNotBlank(instance.Current_Step__c)) {
      List<Workflow_Step_Execution__c> activeSteps = [
        SELECT Id, Output__c
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :instance.Id
          AND Step_Name__c = :instance.Current_Step__c
        WITH SYSTEM_MODE
        ORDER BY CreatedDate DESC, Id DESC
        LIMIT 1
      ];
      if (!activeSteps.isEmpty()) {
        Workflow_Step_Execution__c stepExec = activeSteps[0];
        stepExec.Status__c = 'Running';
        stepExec.Output__c = savePayloadIfNeeded(
          instance.Id,
          payload,
          'Resume_' + stepExec.Id
        );
        update as system stepExec;
      }
    }

    scheduleTimeoutJobForInstance(instance.Id);

    if (Test.isRunningTest()) {
      System.enqueueJob(new WorkflowOrchestrator(instance.Id));
    } else {
      enqueueOrchestrator(instance.Id, null);
    }
  }

  /**
   * Executes the active step for a workflow instance. Designed to run in a Queueable context.
   */
  public static void runStep(Id instanceId) {
    runStep(instanceId, null);
  }

  public static void runStep(Id instanceId, String stepName) {
    // 1. Fetch instance state (NO FOR UPDATE lock to allow parallel execution and direct callouts)
    List<Workflow_Instance__c> instances = [
      SELECT
        Id,
        Name,
        Workflow_Name__c,
        Status__c,
        Current_Step__c,
        Input__c,
        Correlation_Key__c,
        Parent_Instance__c,
        Compensation_Stack__c,
        Definition_Version__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
      WITH SYSTEM_MODE
      LIMIT 1
    ];

    if (instances.isEmpty()) {
      throw new WorkflowException('Workflow instance not found: ' + instanceId);
    }

    Workflow_Instance__c instance = instances[0];
    if (
      instance.Status__c == 'Completed' ||
      instance.Status__c == 'Failed' ||
      instance.Status__c == 'Compensated' ||
      instance.Status__c == 'Cancelled' ||
      instance.Status__c == 'ContinuedAsNew'
    ) {
      return; // Already finished
    }

    if (
      instance.Status__c == 'Compensating' ||
      instance.Status__c == 'Cancelling'
    ) {
      runCompensationStep(instance);
      return;
    }

    // 2. Initialize initial step in memory if this is the start (DML deferred to outcome handler)
    if (String.isBlank(instance.Current_Step__c)) {
      Type wflowType = Type.forName(instance.Workflow_Name__c);
      if (wflowType == null) {
        throw new WorkflowException(
          'Could not resolve workflow definition class: ' +
          instance.Workflow_Name__c
        );
      }
      WorkflowDefinition def = (WorkflowDefinition) wflowType.newInstance();
      instance.Current_Step__c = def.getInitialStep();
      instance.Status__c = 'Running';
    } else if (
      instance.Status__c == 'Suspended' ||
      instance.Status__c == 'Pending'
    ) {
      instance.Status__c = 'Running';
    }

    // If stepName is blank but Current_Step__c is a parallel list, this is a stale/duplicate orchestrator run. Return early.
    if (
      String.isBlank(stepName) &&
      String.isNotBlank(instance.Current_Step__c) &&
      instance.Current_Step__c.contains(',')
    ) {
      return;
    }

    // Validate explicit stepName only when Current_Step__c is a parallel list and the requested step is in that list
    if (String.isNotBlank(stepName) && instance.Current_Step__c != stepName) {
      if (String.isBlank(instance.Current_Step__c) || !instance.Current_Step__c.contains(',')) {
        throw new WorkflowException(
          'Step ' +
            stepName +
            ' is not the active/expected step for this instance: ' +
            instance.Current_Step__c
        );
      }
      Boolean isValid = false;
      for (String pStep : instance.Current_Step__c.split(',')) {
        if (pStep.trim() == stepName) {
          isValid = true;
          break;
        }
      }
      if (!isValid) {
        throw new WorkflowException(
          'Step ' +
            stepName +
            ' is not the active/expected step for this instance: ' +
            instance.Current_Step__c
        );
      }
    }

    // Determine step name to execute
    String activeStepName = String.isNotBlank(stepName)
      ? stepName
      : instance.Current_Step__c;

    // 3. Retrieve or create Step Execution log with FOR UPDATE lock
    List<Workflow_Step_Execution__c> stepExecs = [
      SELECT Id, Step_Name__c, Status__c, Input__c, Output__c, Retry_Count__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :instanceId
        AND Step_Name__c = :activeStepName
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC, Id DESC
      LIMIT 1
    ];

    if (!stepExecs.isEmpty()) {
      stepExecs = [
        SELECT Id, Step_Name__c, Status__c, Input__c, Output__c, Retry_Count__c
        FROM Workflow_Step_Execution__c
        WHERE Id = :stepExecs[0].Id
        WITH SYSTEM_MODE
        FOR UPDATE
      ];
    }

    // Re-query the instance after acquiring the lock on the step execution to get the most up-to-date committed state
    instances = [
      SELECT
        Id,
        Name,
        Workflow_Name__c,
        Status__c,
        Current_Step__c,
        Input__c,
        Correlation_Key__c,
        Parent_Instance__c,
        Compensation_Stack__c,
        Definition_Version__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
      WITH SYSTEM_MODE
      LIMIT 1
    ];
    if (instances.isEmpty()) {
      throw new WorkflowException('Workflow instance not found: ' + instanceId);
    }
    instance = instances[0];

    // Check early exit conditions for instance status
    if (
      instance.Status__c == 'Completed' ||
      instance.Status__c == 'Failed' ||
      instance.Status__c == 'Compensated' ||
      instance.Status__c == 'Cancelled' ||
      instance.Status__c == 'ContinuedAsNew'
    ) {
      return; // Already finished
    }

    Workflow_Step_Execution__c stepExec;
    if (stepExecs.isEmpty()) {
      stepExec = new Workflow_Step_Execution__c();
      stepExec.Workflow_Instance__c = instanceId;
      stepExec.Step_Name__c = activeStepName;
      stepExec.Status__c = 'Running';
      stepExec.Retry_Count__c = 0;

      // Get previous step's output to feed as input
      List<Workflow_Step_Execution__c> completedSteps = [
        SELECT Output__c
        FROM Workflow_Step_Execution__c
        WHERE Workflow_Instance__c = :instanceId AND Status__c = 'Completed'
        WITH SYSTEM_MODE
        ORDER BY CreatedDate DESC, Id DESC
        LIMIT 1
      ];
      stepExec.Input__c = !completedSteps.isEmpty()
        ? completedSteps[0].Output__c
        : instance.Input__c;
    } else {
      stepExec = stepExecs[0];
      if (
        stepExec.Status__c == 'Completed' ||
        stepExec.Status__c == 'Failed' ||
        stepExec.Status__c == 'Cancelled' ||
        stepExec.Status__c == 'Compensated'
      ) {
        return; // Already completed or terminated by concurrent thread
      }
      stepExec.Status__c = 'Running';
    }

    // 4. Resolve previous step output & step state (for yielded/resumed executions)
    String prevOutput = null;
    List<Workflow_Step_Execution__c> lastCompleted;
    if (
      String.isNotBlank(stepName) &&
      String.isNotBlank(instance.Current_Step__c) &&
      instance.Current_Step__c.contains(',')
    ) {
      List<String> activeParallelSteps = instance.Current_Step__c.split(',');
      lastCompleted = [
        SELECT Output__c
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Status__c = 'Completed'
          AND Step_Name__c NOT IN :activeParallelSteps
        WITH SYSTEM_MODE
        ORDER BY CreatedDate DESC, Id DESC
        LIMIT 1
      ];
    } else {
      lastCompleted = [
        SELECT Output__c
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Status__c = 'Completed'
          AND Step_Name__c != :activeStepName
        WITH SYSTEM_MODE
        ORDER BY CreatedDate DESC, Id DESC
        LIMIT 1
      ];
    }
    if (!lastCompleted.isEmpty()) {
      prevOutput = lastCompleted[0].Output__c;
    }

    // 5. Invoke Step Execution
    Type stepType = Type.forName(activeStepName);
    if (stepType == null) {
      throw new WorkflowException(
        'Could not resolve class for step: ' + activeStepName
      );
    }
    WorkflowStep stepInstance = (WorkflowStep) stepType.newInstance();

    StepContext context = new StepContext(
      instanceId,
      instance.Workflow_Name__c,
      activeStepName,
      resolvePayload(stepExec.Input__c),
      resolvePayload(prevOutput),
      resolvePayload(stepExec.Output__c),
      resolvePayload(instance.Input__c),
      instance.Definition_Version__c != null
        ? (Integer) instance.Definition_Version__c
        : 1
    );

    // Determine step timeout if configured
    Integer timeoutSeconds = null;
    if (stepInstance instanceof TimeoutConfigurable) {
      timeoutSeconds = ((TimeoutConfigurable) stepInstance).getTimeoutSeconds();
    }

    StepResult result;
    try {
      result = stepInstance.execute(context);
    } finally {
      // Cancel timeout watch job if it hasn't run yet
      if (timeoutSeconds != null && timeoutSeconds > 0) {
        cancelTimeoutJob(instanceId, activeStepName);
      }
    }

    // 6. Handle Step Outcome
    handleStepResult(instance, stepExec, result);
  }

  private static void saveStepExec(Workflow_Step_Execution__c stepExec) {
    if (stepExec.Id == null) {
      insert as system stepExec;
    } else {
      update as system stepExec;
    }
  }

  private static void handleStepResult(
    Workflow_Instance__c instance,
    Workflow_Step_Execution__c stepExec,
    StepResult result
  ) {
    // Re-query to avoid overwriting a timeout or finalizer crash status and race conditions
    Workflow_Instance__c freshInstance = [
      SELECT
        Id,
        Status__c,
        Current_Step__c,
        Compensation_Stack__c,
        Output__c,
        Parent_Instance__c,
        Workflow_Name__c,
        Correlation_Key__c,
        Input__c,
        Definition_Version__c
      FROM Workflow_Instance__c
      WHERE Id = :instance.Id
      WITH SYSTEM_MODE
      FOR UPDATE
    ];
    if (
      String.isBlank(freshInstance.Current_Step__c) &&
      String.isNotBlank(instance.Current_Step__c)
    ) {
      freshInstance.Current_Step__c = instance.Current_Step__c;
    }
    if (
      freshInstance.Status__c == 'Failed' ||
      freshInstance.Status__c == 'Compensating' ||
      freshInstance.Status__c == 'Compensated' ||
      freshInstance.Status__c == 'Cancelled' ||
      freshInstance.Status__c == 'Cancelling' ||
      freshInstance.Status__c == 'ContinuedAsNew'
    ) {
      throw new WorkflowException(
        'Workflow execution was terminated, cancelled, is compensating, or was continued as new.'
      );
    }
    if (
      freshInstance.Status__c == 'Pending' ||
      freshInstance.Status__c == 'Suspended'
    ) {
      freshInstance.Status__c = 'Running';
    }
    instance = freshInstance;

    if (result.action == StepResult.ActionType.COMPLETE) {
      // Step is complete. Store output.
      stepExec.Status__c = 'Completed';
      stepExec.Output__c = savePayloadIfNeeded(
        instance.Id,
        result.outputJson,
        'Output_' + stepExec.Step_Name__c.replaceAll('[^a-zA-Z0-9]', '_')
      );
      saveStepExec(stepExec);

      // Update compensation stack if step is CompensatableStep
      Type stepType = Type.forName(stepExec.Step_Name__c);
      if (stepType != null) {
        Object stepInstanceObj = stepType.newInstance();
        if (stepInstanceObj instanceof CompensatableStep) {
          List<String> stack = new List<String>();
          if (String.isNotBlank(instance.Compensation_Stack__c)) {
            stack = (List<String>) JSON.deserialize(
              instance.Compensation_Stack__c,
              List<String>.class
            );
          }
          stack.add(stepExec.Step_Name__c);
          instance.Compensation_Stack__c = JSON.serialize(stack);
          // If not parallel or if parallel and not all done, update here so stack is saved.
          // (Parallel allDone paths will update instance later, but doing a single update here is safe).
          update as system instance;
        }
      }

      Boolean isParallel =
        String.isNotBlank(instance.Current_Step__c) &&
        instance.Current_Step__c.contains(',');
      if (!isParallel) {
        // Determine next step
        Type wflowType = Type.forName(instance.Workflow_Name__c);
        WorkflowDefinition def = (WorkflowDefinition) wflowType.newInstance();
        String nextStepName;
        if (def instanceof VersionedWorkflow) {
          nextStepName = ((VersionedWorkflow) def)
            .getNextStep(
              instance.Current_Step__c,
              result,
              instance.Definition_Version__c != null
                ? (Integer) instance.Definition_Version__c
                : 1
            );
        } else {
          nextStepName = def.getNextStep(instance.Current_Step__c, result);
        }

        if (String.isBlank(nextStepName)) {
          // Workflow is finished
          instance.Status__c = 'Completed';
          instance.Output__c = savePayloadIfNeeded(
            instance.Id,
            result.outputJson,
            'Output_Final'
          );
          instance.Current_Step__c = null;
          update as system instance;

          // Notify parent completion if this is a child workflow
          notifyParentCompletion(instance);
          return;
        }

        // Advance to next step
        instance.Current_Step__c = nextStepName;
        update as system instance;

        Workflow_Step_Execution__c nextStepExec = new Workflow_Step_Execution__c();
        nextStepExec.Workflow_Instance__c = instance.Id;
        nextStepExec.Step_Name__c = nextStepName;
        nextStepExec.Status__c = 'Pending';
        nextStepExec.Input__c = stepExec.Output__c;
        nextStepExec.Retry_Count__c = 0;
        insert as system nextStepExec;

        scheduleTimeoutJobForInstance(instance.Id);
        enqueueOrchestrator(instance.Id, null);
        return;
      }

      // Parallel logic (which was under if (isParallel))
      List<String> activeParallelSteps = instance.Current_Step__c.split(',');
      List<Workflow_Step_Execution__c> parallelExecs = [
        SELECT Step_Name__c, Status__c, Output__c
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :instance.Id
          AND Step_Name__c IN :activeParallelSteps
        WITH SYSTEM_MODE
      ];

      Boolean allDone = true;
      for (String ps : activeParallelSteps) {
        Boolean found = false;
        for (Workflow_Step_Execution__c pe : parallelExecs) {
          if (pe.Step_Name__c == ps && pe.Status__c == 'Completed') {
            found = true;
            break;
          }
        }
        if (!found) {
          allDone = false;
          break;
        }
      }

      if (!allDone) {
        return;
      }

      // All parallel steps completed. Proceed to Join step.
      List<Workflow_Step_Execution__c> spawningSteps = [
        SELECT Step_Name__c, Output__c
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :instance.Id
          AND Status__c = 'Completed'
          AND Step_Name__c NOT IN :activeParallelSteps
        WITH SYSTEM_MODE
        ORDER BY CreatedDate DESC, Id DESC
        LIMIT 1
      ];

      Type wflowType = Type.forName(instance.Workflow_Name__c);
      WorkflowDefinition def = (WorkflowDefinition) wflowType.newInstance();

      String spawningStepName = !spawningSteps.isEmpty()
        ? spawningSteps[0].Step_Name__c
        : '';
      StepResult mockResult = StepResult.complete(
        null,
        !spawningSteps.isEmpty() ? spawningSteps[0].Output__c : null
      );

      String nextStepName;
      if (def instanceof VersionedWorkflow) {
        nextStepName = ((VersionedWorkflow) def)
          .getNextStep(
            spawningStepName,
            mockResult,
            instance.Definition_Version__c != null
              ? (Integer) instance.Definition_Version__c
              : 1
          );
      } else {
        nextStepName = def.getNextStep(spawningStepName, mockResult);
      }

      Map<String, Object> joinInput = new Map<String, Object>();
      for (Workflow_Step_Execution__c pe : parallelExecs) {
        Object outputVal = null;
        String resolvedOutput = resolvePayload(pe.Output__c);
        if (String.isNotBlank(resolvedOutput)) {
          try {
            outputVal = JSON.deserializeUntyped(resolvedOutput);
          } catch (Exception ex) {
            outputVal = resolvedOutput;
          }
        }
        joinInput.put(pe.Step_Name__c, outputVal);
      }
      String joinInputJson = JSON.serialize(joinInput);

      if (String.isBlank(nextStepName)) {
        instance.Status__c = 'Completed';
        instance.Output__c = savePayloadIfNeeded(
          instance.Id,
          joinInputJson,
          'Output_Join'
        );
        instance.Current_Step__c = null;
        update as system instance;

        notifyParentCompletion(instance);
        return;
      }

      Workflow_Step_Execution__c joinStepExec = new Workflow_Step_Execution__c();
      joinStepExec.Workflow_Instance__c = instance.Id;
      joinStepExec.Step_Name__c = nextStepName;
      joinStepExec.Status__c = 'Pending';
      joinStepExec.Input__c = savePayloadIfNeeded(
        instance.Id,
        joinInputJson,
        'Input_' + nextStepName.replaceAll('[^a-zA-Z0-9]', '_')
      );
      joinStepExec.Retry_Count__c = 0;
      insert as system joinStepExec;

      instance.Current_Step__c = nextStepName;
      update as system instance;

      scheduleTimeoutJobForInstance(instance.Id);
      enqueueOrchestrator(instance.Id, null);
    } else if (result.action == StepResult.ActionType.YIELD) {
      // Step yielded (e.g. Apex Cursor chunk). Save state to Output and run again in a new transaction.
      stepExec.Status__c = 'Running';
      stepExec.Output__c = savePayloadIfNeeded(
        instance.Id,
        result.stepStateJson,
        'State_' + stepExec.Step_Name__c.replaceAll('[^a-zA-Z0-9]', '_')
      );
      saveStepExec(stepExec);

      update as system instance;

      scheduleTimeoutJobForInstance(instance.Id);
      enqueueOrchestrator(instance.Id, null);
    } else if (result.action == StepResult.ActionType.SUSPEND) {
      // Step suspended (waiting for external signal). Save state and mark instance.
      stepExec.Status__c = 'Pending';
      saveStepExec(stepExec);

      instance.Status__c = 'Suspended';
      update as system instance;
    } else if (result.action == StepResult.ActionType.SLEEP) {
      // Step requested sleep
      stepExec.Status__c = 'Pending';
      stepExec.Output__c = savePayloadIfNeeded(
        instance.Id,
        result.stepStateJson,
        'State_' + stepExec.Step_Name__c.replaceAll('[^a-zA-Z0-9]', '_')
      );
      saveStepExec(stepExec);

      instance.Status__c = 'Suspended';
      update as system instance;

      scheduleSleepResume(instance.Id, result.sleepDurationSeconds);
    } else if (result.action == StepResult.ActionType.START_CHILD) {
      // Step requested child workflow
      stepExec.Status__c = 'Pending';
      Map<String, Object> childInfo = new Map<String, Object>{
        'childWorkflowName' => result.childWorkflowName,
        'childCorrelationKey' => result.childCorrelationKey
      };
      stepExec.Output__c = savePayloadIfNeeded(
        instance.Id,
        JSON.serialize(childInfo),
        'State_ChildInfo_' +
        stepExec.Step_Name__c.replaceAll('[^a-zA-Z0-9]', '_')
      );
      saveStepExec(stepExec);

      instance.Status__c = 'Suspended';
      update as system instance;

      startChildWorkflow(
        instance.Id,
        result.childWorkflowName,
        result.childCorrelationKey,
        result.childInputJson
      );
    } else if (result.action == StepResult.ActionType.WAIT_FOR_APPROVAL) {
      stepExec.Status__c = 'Pending';
      Map<String, Object> state = new Map<String, Object>{
        'waitingForApproval' => true,
        'approvalKey' => result.approvalKey,
        'approvalRole' => result.approvalRole
      };
      stepExec.Output__c = savePayloadIfNeeded(
        instance.Id,
        JSON.serialize(state),
        'State_Approval_' +
        stepExec.Step_Name__c.replaceAll('[^a-zA-Z0-9]', '_')
      );
      saveStepExec(stepExec);

      instance.Status__c = 'Suspended';
      update as system instance;
    } else if (result.action == StepResult.ActionType.SPLIT) {
      stepExec.Status__c = 'Completed';
      stepExec.Output__c = savePayloadIfNeeded(
        instance.Id,
        result.parallelInputJson != null
          ? result.parallelInputJson
          : result.outputJson,
        'Output_Split_' + stepExec.Step_Name__c.replaceAll('[^a-zA-Z0-9]', '_')
      );
      saveStepExec(stepExec);

      String parallelStepsStr = String.join(result.parallelStepNames, ',');
      instance.Current_Step__c = parallelStepsStr;
      instance.Status__c = 'Running';
      update as system instance;

      List<Workflow_Step_Execution__c> parallelExecs = new List<Workflow_Step_Execution__c>();
      for (String ps : result.parallelStepNames) {
        Workflow_Step_Execution__c pe = new Workflow_Step_Execution__c();
        pe.Workflow_Instance__c = instance.Id;
        pe.Step_Name__c = ps;
        pe.Status__c = 'Pending';
        pe.Input__c = savePayloadIfNeeded(
          instance.Id,
          result.parallelInputJson != null
            ? result.parallelInputJson
            : stepExec.Output__c,
          'Input_Parallel_' + ps.replaceAll('[^a-zA-Z0-9]', '_')
        );
        pe.Retry_Count__c = 0;
        parallelExecs.add(pe);
      }
      insert as system parallelExecs;

      scheduleTimeoutJobForInstance(instance.Id);
      for (String ps : result.parallelStepNames) {
        enqueueOrchestrator(instance.Id, ps);
      }
    } else if (result.action == StepResult.ActionType.RETRY) {
      // Step requested retry
      stepExec.Retry_Count__c += 1;

      // Get or default retry policy
      RetryPolicy policy = (result.retryPolicy != null)
        ? result.retryPolicy
        : new RetryPolicy();

      if (stepExec.Retry_Count__c >= policy.maximumAttempts) {
        stepExec.Status__c = 'Failed';
        stepExec.Error_Details__c =
          'Max retries (' +
          policy.maximumAttempts +
          ') exceeded.';
        saveStepExec(stepExec);

        failWorkflowInstance(
          instance.Id,
          instance.Current_Step__c,
          'Max retries exceeded.'
        );
      } else {
        stepExec.Status__c = 'Retrying';
        stepExec.Output__c = null;
        saveStepExec(stepExec);

        // Calculate exponential backoff
        Double backoff = Math.pow(
          (Double) policy.backoffCoefficient,
          (Double) (stepExec.Retry_Count__c - 1)
        );
        Integer delay = (Integer) (policy.initialIntervalSeconds * backoff);
        delay = Math.min(delay, 86400);

        scheduleRetry(instance.Id, stepExec.Step_Name__c, delay);
      }
    } else if (result.action == StepResult.ActionType.CONTINUE_AS_NEW) {
      stepExec.Status__c = 'ContinuedAsNew';
      stepExec.Output__c = savePayloadIfNeeded(
        instance.Id,
        result.nextInputJson,
        'ContinueInput_' + stepExec.Step_Name__c.replaceAll('[^a-zA-Z0-9]', '_')
      );
      saveStepExec(stepExec);

      // Resolve the new correlation key
      String newKey = resolveContinueAsNewKey(
        instance.Correlation_Key__c,
        result.newCorrelationKey
      );

      // Mark current instance as ContinuedAsNew
      instance.Status__c = 'ContinuedAsNew';
      instance.Current_Step__c = null;
      update as system instance;

      // Resolve initial step for successor instance
      String initialStep = null;
      Type wflowType = Type.forName(instance.Workflow_Name__c);
      if (wflowType != null) {
        Object defObj = wflowType.newInstance();
        if (defObj instanceof WorkflowDefinition) {
          initialStep = ((WorkflowDefinition) defObj).getInitialStep();
        }
      }

      // Spawn successor instance
      Workflow_Instance__c nextInstance = new Workflow_Instance__c(
        Workflow_Name__c = instance.Workflow_Name__c,
        Correlation_Key__c = newKey,
        Previous_Instance__c = instance.Id,
        Definition_Version__c = instance.Definition_Version__c,
        Current_Step__c = initialStep
      );
      try {
        insert as system nextInstance;
      } catch (DmlException ex) {
        if (ex.getDmlStatusCode(0) == 'DUPLICATE_VALUE') {
          throw new WorkflowException(
            'An active workflow already exists with correlation key: ' +
            newKey
          );
        }
        throw ex;
      }

      // Set input and save payload
      nextInstance.Input__c = savePayloadIfNeeded(
        nextInstance.Id,
        result.nextInputJson,
        'Input_' + nextInstance.Id
      );
      update as system nextInstance;

      // Pre-create the successor's first step execution log
      if (String.isNotBlank(initialStep)) {
        Workflow_Step_Execution__c nextStepExec = new Workflow_Step_Execution__c();
        nextStepExec.Workflow_Instance__c = nextInstance.Id;
        nextStepExec.Step_Name__c = initialStep;
        nextStepExec.Status__c = 'Pending';
        nextStepExec.Input__c = nextInstance.Input__c;
        nextStepExec.Retry_Count__c = 0;
        insert as system nextStepExec;
      }

      // Enqueue the successor run
      scheduleTimeoutJobForInstance(nextInstance.Id);
      if (Test.isRunningTest()) {
        if (!disableQueueableInTest) {
          System.enqueueJob(new WorkflowOrchestrator(nextInstance.Id));
        }
      } else {
        enqueueOrchestrator(nextInstance.Id, null);
      }
    }
  }

  /**
   * Rescues a workflow when the host transaction fails or hits governor limits.
   * Invoked from a System.Finalizer.
   */
  public static void handleCrash(Id instanceId, Exception ex) {
    handleCrash(instanceId, null, ex);
  }

  public static void handleCrash(Id instanceId, String stepName, Exception ex) {
    // Run as separate DML transaction to ensure it's written even if parent rolled back
    List<Workflow_Instance__c> instances = [
      SELECT Id, Current_Step__c, Input__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
      WITH SYSTEM_MODE
      LIMIT 1
      FOR UPDATE
    ];

    if (instances.isEmpty()) {
      return;
    }

    Workflow_Instance__c instance = instances[0];

    // Resolve target step name: if stepName is passed, use it; otherwise fallback to Current_Step__c
    String targetStepName = String.isNotBlank(stepName)
      ? stepName
      : instance.Current_Step__c;

    // Mark step failed first
    if (String.isNotBlank(targetStepName)) {
      List<Workflow_Step_Execution__c> stepExecs = [
        SELECT Id
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Step_Name__c = :targetStepName
        WITH SYSTEM_MODE
        ORDER BY CreatedDate DESC, Id DESC
        LIMIT 1
      ];
      if (!stepExecs.isEmpty()) {
        Workflow_Step_Execution__c stepExec = stepExecs[0];
        stepExec.Status__c = 'Failed';
        stepExec.Error_Details__c = (ex != null
          ? ex.getMessage() + '\n' + ex.getStackTraceString()
          : 'Unknown governor limit / crash');
        update as system stepExec;
      } else {
        // Construct and insert the step execution log with failed status
        Workflow_Step_Execution__c stepExec = new Workflow_Step_Execution__c();
        stepExec.Workflow_Instance__c = instanceId;
        stepExec.Step_Name__c = targetStepName;
        stepExec.Status__c = 'Failed';
        stepExec.Error_Details__c = (ex != null
          ? ex.getMessage() + '\n' + ex.getStackTraceString()
          : 'Unknown governor limit / crash');

        // Get previous step's output to feed as input
        List<Workflow_Step_Execution__c> completedSteps = [
          SELECT Output__c
          FROM Workflow_Step_Execution__c
          WHERE Workflow_Instance__c = :instanceId AND Status__c = 'Completed'
          WITH SYSTEM_MODE
          ORDER BY CreatedDate DESC, Id DESC
          LIMIT 1
        ];
        stepExec.Input__c = !completedSteps.isEmpty()
          ? completedSteps[0].Output__c
          : instance.Input__c;
        insert as system stepExec;
      }
    }

    // Use fail helper
    String errorMsg =
      'Transaction crashed: ' +
      (ex != null ? ex.getMessage() : 'Unknown governor limit');
    failWorkflowInstance(instanceId, targetStepName, errorMsg);
  }

  /**
   * Transitions a workflow instance to Failed or Compensating state.
   */
  public static void failWorkflowInstance(
    Id instanceId,
    String stepName,
    String errorMessage
  ) {
    List<Workflow_Instance__c> instances = [
      SELECT
        Id,
        Name,
        Status__c,
        Error_Message__c,
        Compensation_Stack__c,
        Workflow_Name__c,
        Correlation_Key__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
      WITH SYSTEM_MODE
      LIMIT 1
      FOR UPDATE
    ];
    if (instances.isEmpty()) {
      return;
    }
    Workflow_Instance__c instance = instances[0];

    // Check if there are compensations to run
    Boolean hasCompensations = false;
    if (String.isNotBlank(instance.Compensation_Stack__c)) {
      List<String> stack = (List<String>) JSON.deserialize(
        instance.Compensation_Stack__c,
        List<String>.class
      );
      hasCompensations = !stack.isEmpty();
    }

    if (!hasCompensations) {
      instance.Status__c = 'Failed';
      instance.Error_Message__c =
        'Failed at step ' +
        stepName +
        ': ' +
        errorMessage;
      update as system instance;
      WorkflowAlertManager.sendAlert(instance, instance.Error_Message__c);
      return;
    }

    Boolean isCompensationFailure = (instance.Status__c == 'Compensating' ||
                                     instance.Status__c == 'Cancelling' ||
                                     (String.isNotBlank(stepName) && stepName.endsWith('_Compensate')));

    if (isCompensationFailure) {
      instance.Status__c = 'Failed';
      instance.Error_Message__c =
        'Failed at step ' +
        stepName +
        ': ' +
        errorMessage;
      update as system instance;
      WorkflowAlertManager.sendAlert(instance, instance.Error_Message__c);
      return;
    }

    instance.Status__c = 'Compensating';
    instance.Error_Message__c =
      'Failed at step ' +
      stepName +
      ': ' +
      errorMessage;
    preCreateFirstCompensationStep(instance);
    update as system instance;

    scheduleTimeoutJobForInstance(instance.Id);

    // Kick off rollback loop
    if (Test.isRunningTest()) {
      if (!disableQueueableInTest) {
        System.enqueueJob(new WorkflowOrchestrator(instance.Id));
      }
    } else {
      enqueueOrchestrator(instance.Id, null);
    }
  }

  private static void scheduleRetry(
    Id instanceId,
    String stepName,
    Integer delaySeconds
  ) {
    // Enqueue delayed execution via Scheduled Apex
    WorkflowRetryJob job = new WorkflowRetryJob(instanceId, stepName);
    Datetime runTime = Datetime.now()
      .addSeconds(Test.isRunningTest() ? delaySeconds + 60 : delaySeconds);
    String cronStr =
      runTime.second() +
      ' ' +
      runTime.minute() +
      ' ' +
      runTime.hour() +
      ' ' +
      runTime.day() +
      ' ' +
      runTime.month() +
      ' ? ' +
      runTime.year();
    System.schedule(
      'WorkflowRetry_' + instanceId + '_' + runTime.getTime(),
      cronStr,
      job
    );
  }

  private static void scheduleSleepResume(Id instanceId, Integer delaySeconds) {
    // Enqueue sleep resumption via Scheduled Apex using WorkflowSleepJob
    WorkflowSleepJob job = new WorkflowSleepJob(instanceId);
    Datetime runTime = Datetime.now()
      .addSeconds(Test.isRunningTest() ? delaySeconds + 60 : delaySeconds);
    String cronStr =
      runTime.second() +
      ' ' +
      runTime.minute() +
      ' ' +
      runTime.hour() +
      ' ' +
      runTime.day() +
      ' ' +
      runTime.month() +
      ' ? ' +
      runTime.year();
    System.schedule(
      'WorkflowSleep_' + instanceId + '_' + runTime.getTime(),
      cronStr,
      job
    );
  }

  private static void startChildWorkflow(
    Id parentId,
    String workflowName,
    String correlationKey,
    String inputJson
  ) {
    validateCorrelationKey(correlationKey);
    if (String.isNotBlank(correlationKey)) {
      List<Workflow_Instance__c> existing = [
        SELECT Id
        FROM Workflow_Instance__c
        WHERE
          Correlation_Key__c = :correlationKey
          AND Status__c IN ('Pending', 'Running', 'Suspended')
        WITH SYSTEM_MODE
        LIMIT 1
      ];
      if (!existing.isEmpty()) {
        throw new WorkflowException(
          'An active workflow already exists with correlation key: ' +
          correlationKey
        );
      }
    }

    Workflow_Instance__c instance = new Workflow_Instance__c();
    instance.Workflow_Name__c = workflowName;
    instance.Status__c = 'Pending';
    instance.Correlation_Key__c = correlationKey;
    instance.Parent_Instance__c = parentId;

    // Resolve child version
    Type wflowType = Type.forName(workflowName);
    if (wflowType != null) {
      Object defObj = wflowType.newInstance();
      if (defObj instanceof VersionedWorkflow) {
        instance.Definition_Version__c = ((VersionedWorkflow) defObj)
          .getLatestVersion();
      } else {
        instance.Definition_Version__c = 1;
      }
      if (defObj instanceof WorkflowDefinition) {
        instance.Current_Step__c = ((WorkflowDefinition) defObj)
          .getInitialStep();
      }
    } else {
      instance.Definition_Version__c = 1;
    }

    try {
      insert as system instance;
    } catch (DmlException ex) {
      if (ex.getDmlStatusCode(0) == 'DUPLICATE_VALUE') {
        throw new WorkflowException(
          'An active workflow already exists with correlation key: ' +
          correlationKey
        );
      }
      throw ex;
    }

    instance.Input__c = savePayloadIfNeeded(
      instance.Id,
      inputJson,
      'Input_Child_' + instance.Id
    );
    update as system instance;

    if (String.isNotBlank(instance.Current_Step__c)) {
      Workflow_Step_Execution__c stepExec = new Workflow_Step_Execution__c();
      stepExec.Workflow_Instance__c = instance.Id;
      stepExec.Step_Name__c = instance.Current_Step__c;
      stepExec.Status__c = 'Pending';
      stepExec.Input__c = instance.Input__c;
      stepExec.Retry_Count__c = 0;
      insert as system stepExec;
    }

    scheduleTimeoutJobForInstance(instance.Id);

    if (!Test.isRunningTest()) {
      enqueueOrchestrator(instance.Id, null);
    }
  }

  private static void notifyParentCompletion(
    Workflow_Instance__c childInstance
  ) {
    if (childInstance.Parent_Instance__c != null) {
      Workflow_Instance__c parent = [
        SELECT Correlation_Key__c
        FROM Workflow_Instance__c
        WHERE Id = :childInstance.Parent_Instance__c
        WITH SYSTEM_MODE
      ];

      String targetKey = String.isNotBlank(parent.Correlation_Key__c)
        ? parent.Correlation_Key__c
        : parent.Id;

      String signalName = 'ChildCompleted';
      if (String.isNotBlank(childInstance.Correlation_Key__c)) {
        signalName += ':' + childInstance.Correlation_Key__c;
      } else {
        signalName += ':' + childInstance.Id;
      }

      Workflow_Event__e event = new Workflow_Event__e(
        Workflow_Instance_Id__c = targetKey,
        Event_Type__c = 'SIGNAL:' + signalName,
        Payload__c = childInstance.Output__c
      );
      Database.SaveResult sr = EventBus.publish(event);
      if (!sr.isSuccess()) {
        List<String> errMsgs = new List<String>();
        for (Database.Error err : sr.getErrors()) {
          errMsgs.add(err.getStatusCode() + ': ' + err.getMessage());
        }
        throw new WorkflowException(
          'Failed to publish child completion event: ' +
          String.join(errMsgs, ', ')
        );
      }
    }
  }

  /**
   * Sends an external signal to a workflow instance by correlation key or instance ID.
   */
  public static void signal(String keyOrId, String signalName, String payload) {
    Boolean isId = false;
    Id targetId;
    try {
      targetId = (Id) keyOrId;
      isId = true;
    } catch (Exception ex) {
      // Not a valid ID
    }

    List<Workflow_Instance__c> instances = new List<Workflow_Instance__c>();
    if (isId) {
      // Query by ID first to prevent matching a correlation key that equals this ID string
      instances = [
        SELECT Id, Status__c
        FROM Workflow_Instance__c
        WHERE Id = :targetId AND Status__c IN ('Pending', 'Running', 'Suspended')
        WITH SYSTEM_MODE
        LIMIT 1
        FOR UPDATE
      ];
    }

    if (instances.isEmpty()) {
      instances = [
        SELECT Id, Status__c
        FROM Workflow_Instance__c
        WHERE
          Correlation_Key__c = :keyOrId
          AND Status__c IN ('Pending', 'Running', 'Suspended')
        WITH SYSTEM_MODE
        LIMIT 1
        FOR UPDATE
      ];
    }

    if (instances.isEmpty()) {
      throw new WorkflowException(
        'No active workflow found with key or ID: ' + keyOrId
      );
    }

    Workflow_Instance__c instance = instances[0];

    if (
      signalName.equalsIgnoreCase('Cancel') ||
      signalName.equalsIgnoreCase('CancelWorkflow')
    ) {
      Boolean runCompensations = true;
      if (String.isNotBlank(payload)) {
        try {
          Map<String, Object> params = (Map<String, Object>) JSON.deserializeUntyped(
            payload
          );
          if (params.containsKey('runCompensations')) {
            runCompensations = (Boolean) params.get('runCompensations');
          }
        } catch (Exception e) {
          // Ignore and use default
        }
      }
      cancel(instance.Id, runCompensations);
      return;
    }

    // Insert the signal record
    Workflow_Signal__c sig = new Workflow_Signal__c();
    sig.Workflow_Instance__c = instance.Id;
    sig.Signal_Name__c = signalName;
    sig.Payload__c = payload;
    sig.Status__c = 'Received';
    insert as system sig;

    // If the workflow is suspended or running, resume/orchestrate it
    if (instance.Status__c == 'Suspended' || instance.Status__c == 'Running') {
      if (instance.Status__c == 'Suspended') {
        instance.Status__c = 'Running';
        update as system instance;
      }

      scheduleTimeoutJobForInstance(instance.Id);

      if (Test.isRunningTest()) {
        if (!enqueuedInstanceIds.contains(instance.Id)) {
          enqueuedInstanceIds.add(instance.Id);
          System.enqueueJob(new WorkflowOrchestrator(instance.Id));
        }
      } else {
        if (!enqueuedInstanceIds.contains(instance.Id)) {
          enqueuedInstanceIds.add(instance.Id);
          try {
            if (Limits.getQueueableJobs() < Limits.getLimitQueueableJobs()) {
              System.enqueueJob(new WorkflowOrchestrator(instance.Id));
            } else {
              enqueueOrchestrator(instance.Id, null);
            }
          } catch (Exception ex) {
            // Fallback to asynchronous Platform Event if enqueue fails due to transient platform limit errors
            enqueueOrchestrator(instance.Id, null);
          }
        }
      }
    }
  }

  /**
   * Resumes a failed workflow instance from the step where it failed, resetting its state and retry counter.
   */
  public static void retryWorkflow(Id instanceId) {
    List<Workflow_Instance__c> instances = [
      SELECT
        Id,
        Status__c,
        Current_Step__c,
        Error_Message__c,
        Compensation_Stack__c,
        Workflow_Name__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
      WITH SYSTEM_MODE
      LIMIT 1
      FOR UPDATE
    ];
    if (instances.isEmpty()) {
      throw new WorkflowException('Workflow instance not found: ' + instanceId);
    }
    Workflow_Instance__c instance = instances[0];
    if (instance.Status__c != 'Failed') {
      throw new WorkflowException(
        'Workflow instance is not in Failed status. Current status: ' +
        instance.Status__c
      );
    }

    Boolean hasCompensations = false;
    List<String> stack = new List<String>();
    if (String.isNotBlank(instance.Compensation_Stack__c)) {
      stack = (List<String>) JSON.deserialize(
        instance.Compensation_Stack__c,
        List<String>.class
      );
      hasCompensations = !stack.isEmpty();
    }

    List<String> targetStepNames = new List<String>();
    if (hasCompensations) {
      targetStepNames.add(stack[stack.size() - 1] + '_Compensate');
    } else if (String.isNotBlank(instance.Current_Step__c)) {
      if (instance.Current_Step__c.contains(',')) {
        for (String pStep : instance.Current_Step__c.split(',')) {
          targetStepNames.add(pStep.trim());
        }
      } else {
        targetStepNames.add(instance.Current_Step__c);
      }
    }

    if (String.isBlank(instance.Current_Step__c) && !hasCompensations) {
      Type wflowType = Type.forName(instance.Workflow_Name__c);
      if (wflowType != null) {
        Object defObj = wflowType.newInstance();
        if (defObj instanceof WorkflowDefinition) {
          instance.Current_Step__c = ((WorkflowDefinition) defObj)
            .getInitialStep();
          targetStepNames.add(instance.Current_Step__c);
        }
      }
    }

    // Reset the failed step's execution status to let it execute again
    for (String targetStepName : targetStepNames) {
      List<Workflow_Step_Execution__c> stepExecs = [
        SELECT Id, Status__c, Retry_Count__c, Error_Details__c
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Step_Name__c = :targetStepName
        WITH SYSTEM_MODE
        ORDER BY CreatedDate DESC, Id DESC
        LIMIT 1
      ];
      if (!stepExecs.isEmpty()) {
        Workflow_Step_Execution__c stepExec = stepExecs[0];
        if (stepExec.Status__c != 'Completed') {
          stepExec.Status__c = 'Pending';
          stepExec.Retry_Count__c = 0; // reset retry counter
          stepExec.Error_Details__c = null;
          update as system stepExec;
        }
      }
    }

    if (hasCompensations) {
      instance.Status__c = 'Compensating';
    } else {
      instance.Status__c = 'Running';
    }
    instance.Error_Message__c = null;
    update as system instance;

    scheduleTimeoutJobForInstance(instanceId);

    // Enqueue the orchestrator to resume execution
    if (
      hasCompensations ||
      String.isBlank(instance.Current_Step__c) ||
      !instance.Current_Step__c.contains(',')
    ) {
      if (Test.isRunningTest()) {
        if (!disableQueueableInTest) {
          System.enqueueJob(new WorkflowOrchestrator(instanceId));
        }
      } else {
        enqueueOrchestrator(instanceId, null);
      }
      return;
    }

    // Parallel forward execution retry: enqueue only incomplete branches
    for (String targetStepName : targetStepNames) {
      List<Workflow_Step_Execution__c> stepExecs = [
        SELECT Status__c
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Step_Name__c = :targetStepName
        WITH SYSTEM_MODE
        ORDER BY CreatedDate DESC, Id DESC
        LIMIT 1
      ];
      if (stepExecs.isEmpty() || stepExecs[0].Status__c != 'Completed') {
        if (Test.isRunningTest()) {
          if (!disableQueueableInTest) {
            System.enqueueJob(
              new WorkflowOrchestrator(instanceId, targetStepName)
            );
          }
        } else {
          enqueueOrchestrator(instanceId, targetStepName);
        }
      }
    }
  }

  private static void runCompensationStep(Workflow_Instance__c instance) {
    // 1. Read the compensation stack
    if (String.isBlank(instance.Compensation_Stack__c)) {
      instance.Status__c = (instance.Status__c == 'Cancelling')
        ? 'Cancelled'
        : 'Compensated';
      instance.Current_Step__c = null;
      update as system instance;
      return;
    }

    List<String> stack = (List<String>) JSON.deserialize(
      instance.Compensation_Stack__c,
      List<String>.class
    );
    if (stack.isEmpty()) {
      instance.Status__c = (instance.Status__c == 'Cancelling')
        ? 'Cancelled'
        : 'Compensated';
      instance.Current_Step__c = null;
      update as system instance;
      return;
    }

    // 2. Get the top step to compensate (do not pop yet, only pop on success)
    String activeStepName = stack[stack.size() - 1];

    // 3. Create or retrieve the compensation step execution log with FOR UPDATE lock
    String compensationStepLogName = activeStepName + '_Compensate';
    List<Workflow_Step_Execution__c> stepExecs = [
      SELECT Id, Status__c, Input__c, Output__c, Retry_Count__c, Step_Name__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :instance.Id
        AND Step_Name__c = :compensationStepLogName
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC, Id DESC
      LIMIT 1
    ];

    if (!stepExecs.isEmpty()) {
      stepExecs = [
        SELECT Id, Status__c, Input__c, Output__c, Retry_Count__c, Step_Name__c
        FROM Workflow_Step_Execution__c
        WHERE Id = :stepExecs[0].Id
        WITH SYSTEM_MODE
        FOR UPDATE
      ];
    }

    // Re-query the instance after acquiring the lock on the step execution to get the most up-to-date committed state
    List<Workflow_Instance__c> freshInstances = [
      SELECT Id, Status__c, Compensation_Stack__c, Definition_Version__c, Workflow_Name__c, Input__c
      FROM Workflow_Instance__c
      WHERE Id = :instance.Id
      WITH SYSTEM_MODE
      LIMIT 1
    ];
    if (freshInstances.isEmpty()) {
      throw new WorkflowException('Workflow instance not found: ' + instance.Id);
    }
    instance = freshInstances[0];

    // Check early exit conditions for instance status
    if (instance.Status__c != 'Compensating' && instance.Status__c != 'Cancelling') {
      return; // Already completed compensation or aborted
    }

    Workflow_Step_Execution__c stepExec;
    if (stepExecs.isEmpty()) {
      stepExec = new Workflow_Step_Execution__c();
      stepExec.Workflow_Instance__c = instance.Id;
      stepExec.Step_Name__c = compensationStepLogName;
      stepExec.Status__c = 'Running';
      stepExec.Retry_Count__c = 0;

      // Retrieve the original step execution to get inputs/outputs
      List<Workflow_Step_Execution__c> originalExecs = [
        SELECT Input__c, Output__c
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :instance.Id
          AND Step_Name__c = :activeStepName
        WITH SYSTEM_MODE
        ORDER BY CreatedDate DESC, Id DESC
        LIMIT 1
      ];

      stepExec.Input__c = !originalExecs.isEmpty()
        ? originalExecs[0].Input__c
        : null;
      stepExec.Output__c = !originalExecs.isEmpty()
        ? originalExecs[0].Output__c
        : null;
    } else {
      stepExec = stepExecs[0];
      if (
        stepExec.Status__c == 'Completed' ||
        stepExec.Status__c == 'Compensated' ||
        stepExec.Status__c == 'Failed' ||
        stepExec.Status__c == 'Cancelled'
      ) {
        stack.remove(stack.size() - 1);
        instance.Compensation_Stack__c = JSON.serialize(stack);
        update as system instance;

        if (!stack.isEmpty()) {
          preCreateFirstCompensationStep(instance);
          scheduleTimeoutJobForInstance(instance.Id);
        }

        if (Test.isRunningTest()) {
          if (!disableQueueableInTest) {
            System.enqueueJob(new WorkflowOrchestrator(instance.Id));
          }
        } else {
          enqueueOrchestrator(instance.Id, null);
        }
        return;
      }
      stepExec.Status__c = 'Running';
    }

    // 4. Instantiate the step and execute compensate
    Type stepType = Type.forName(activeStepName);
    if (stepType == null) {
      throw new WorkflowException(
        'Could not resolve class for step compensation: ' + activeStepName
      );
    }

    Object stepInstanceObj = stepType.newInstance();
    if (!(stepInstanceObj instanceof CompensatableStep)) {
      stepExec.Status__c = 'Compensated';
      saveStepExec(stepExec);

      stack.remove(stack.size() - 1);
      instance.Compensation_Stack__c = JSON.serialize(stack);
      update as system instance;

      if (!stack.isEmpty()) {
        scheduleTimeoutJobForInstance(instance.Id);
      }

      if (Test.isRunningTest()) {
        if (!disableQueueableInTest) {
          System.enqueueJob(new WorkflowOrchestrator(instance.Id));
        }
      } else {
        enqueueOrchestrator(instance.Id, null);
      }
      return;
    }

    CompensatableStep compensatableStepInstance = (CompensatableStep) stepInstanceObj;

    // Build context for compensate
    String prevOutput = null;
    List<Workflow_Step_Execution__c> completedBefore = [
      SELECT Output__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :instance.Id
        AND Status__c = 'Completed'
        AND Step_Name__c != :activeStepName
        AND Step_Name__c != :compensationStepLogName
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC, Id DESC
      LIMIT 1
    ];
    if (!completedBefore.isEmpty()) {
      prevOutput = completedBefore[0].Output__c;
    }

    StepContext context = new StepContext(
      instance.Id,
      instance.Workflow_Name__c,
      compensationStepLogName,
      resolvePayload(stepExec.Input__c),
      resolvePayload(prevOutput),
      resolvePayload(stepExec.Output__c),
      resolvePayload(instance.Input__c),
      instance.Definition_Version__c != null
        ? (Integer) instance.Definition_Version__c
        : 1
    );

    Integer timeoutSeconds = null;
    if (compensatableStepInstance instanceof TimeoutConfigurable) {
      timeoutSeconds = ((TimeoutConfigurable) compensatableStepInstance)
        .getTimeoutSeconds();
    }

    StepResult result;
    try {
      result = compensatableStepInstance.compensate(context);
    } catch (Exception ex) {
      stepExec.Status__c = 'Failed';
      stepExec.Error_Details__c = ex.getMessage() + '\n' + ex.getStackTraceString();
      saveStepExec(stepExec);
      failWorkflowInstance(instance.Id, compensationStepLogName, ex.getMessage());
      return;
    } finally {
      if (timeoutSeconds != null && timeoutSeconds > 0) {
        cancelTimeoutJob(instance.Id, compensationStepLogName);
      }
    }

    handleCompensationStepResult(instance, stepExec, result, stack);
  }

  private static void handleCompensationStepResult(
    Workflow_Instance__c instance,
    Workflow_Step_Execution__c stepExec,
    StepResult result,
    List<String> stack
  ) {
    Workflow_Instance__c freshInstance = [
      SELECT Status__c
      FROM Workflow_Instance__c
      WHERE Id = :instance.Id
      WITH SYSTEM_MODE
      FOR UPDATE
    ];
    if (
      freshInstance.Status__c == 'Failed' ||
      freshInstance.Status__c == 'Cancelled'
    ) {
      throw new WorkflowException(
        'Workflow execution was terminated or cancelled.'
      );
    }

    if (result.action == StepResult.ActionType.COMPLETE) {
      stepExec.Status__c = 'Compensated';
      stepExec.Output__c = savePayloadIfNeeded(
        instance.Id,
        result.outputJson,
        'Output_' + stepExec.Step_Name__c.replaceAll('[^a-zA-Z0-9]', '_')
      );
      saveStepExec(stepExec);

      stack.remove(stack.size() - 1);
      instance.Compensation_Stack__c = JSON.serialize(stack);

      if (stack.isEmpty()) {
        instance.Status__c = (instance.Status__c == 'Cancelling')
          ? 'Cancelled'
          : 'Compensated';
        instance.Current_Step__c = null;
      } else {
        scheduleTimeoutJobForInstance(instance.Id);
      }
      update as system instance;

      if (Test.isRunningTest()) {
        if (!disableQueueableInTest) {
          System.enqueueJob(new WorkflowOrchestrator(instance.Id));
        }
      } else {
        enqueueOrchestrator(instance.Id, null);
      }
    } else if (result.action == StepResult.ActionType.YIELD) {
      stepExec.Status__c = 'Running';
      stepExec.Output__c = savePayloadIfNeeded(
        instance.Id,
        result.stepStateJson,
        'State_' + stepExec.Step_Name__c.replaceAll('[^a-zA-Z0-9]', '_')
      );
      saveStepExec(stepExec);

      update as system instance;

      scheduleTimeoutJobForInstance(instance.Id);
      enqueueOrchestrator(instance.Id, null);
    } else if (result.action == StepResult.ActionType.SUSPEND) {
      stepExec.Status__c = 'Pending';
      saveStepExec(stepExec);
      instance.Status__c = 'Suspended';
      update as system instance;
    } else if (result.action == StepResult.ActionType.SLEEP) {
      stepExec.Status__c = 'Pending';
      stepExec.Output__c = savePayloadIfNeeded(
        instance.Id,
        result.stepStateJson,
        'State_' + stepExec.Step_Name__c.replaceAll('[^a-zA-Z0-9]', '_')
      );
      saveStepExec(stepExec);
      instance.Status__c = 'Suspended';
      update as system instance;
      scheduleSleepResume(instance.Id, result.sleepDurationSeconds);
    } else if (result.action == StepResult.ActionType.WAIT_FOR_APPROVAL) {
      stepExec.Status__c = 'Pending';
      Map<String, Object> state = new Map<String, Object>{
        'waitingForApproval' => true,
        'approvalKey' => result.approvalKey,
        'approvalRole' => result.approvalRole
      };
      stepExec.Output__c = savePayloadIfNeeded(
        instance.Id,
        JSON.serialize(state),
        'State_Approval_' +
        stepExec.Step_Name__c.replaceAll('[^a-zA-Z0-9]', '_')
      );
      saveStepExec(stepExec);
      instance.Status__c = 'Suspended';
      update as system instance;
    } else if (result.action == StepResult.ActionType.RETRY) {
      stepExec.Retry_Count__c += 1;
      RetryPolicy policy = (result.retryPolicy != null)
        ? result.retryPolicy
        : new RetryPolicy();

      if (stepExec.Retry_Count__c >= policy.maximumAttempts) {
        stepExec.Status__c = 'Failed';
        stepExec.Error_Details__c =
          'Compensation max retries (' +
          policy.maximumAttempts +
          ') exceeded.';
        saveStepExec(stepExec);

        instance.Status__c = 'Failed';
        instance.Error_Message__c =
          'Compensation step ' +
          stepExec.Step_Name__c +
          ' failed after max retries.';
        update as system instance;
        WorkflowAlertManager.sendAlert(instance, instance.Error_Message__c);
      } else {
        stepExec.Status__c = 'Retrying';
        stepExec.Output__c = null;
        saveStepExec(stepExec);

        Double backoff = Math.pow(
          (Double) policy.backoffCoefficient,
          (Double) (stepExec.Retry_Count__c - 1)
        );
        Integer delay = (Integer) (policy.initialIntervalSeconds * backoff);
        delay = Math.min(delay, 86400);
        scheduleRetry(instance.Id, stepExec.Step_Name__c, delay);
      }
    } else {
      stepExec.Status__c = 'Failed';
      stepExec.Error_Details__c = 'Unsupported compensation action: ' + (result != null ? result.action : null);
      saveStepExec(stepExec);

      instance.Status__c = 'Failed';
      instance.Error_Message__c =
        'Compensation step ' +
        stepExec.Step_Name__c +
        ' failed: Unsupported action.';
      update as system instance;
      WorkflowAlertManager.sendAlert(instance, instance.Error_Message__c);
    }
  }

  private static void cancelTimeoutJob(Id instanceId, String stepName) {
    String cleanStepName = stepName.replaceAll('[^a-zA-Z0-9]', '_');
    String jobName = 'Timeout_' + instanceId + '_' + cleanStepName;
    List<CronTrigger> triggers = [
      SELECT Id
      FROM CronTrigger
      WHERE CronJobDetail.Name = :jobName
      WITH SYSTEM_MODE
    ];
    for (CronTrigger triggerJob : triggers) {
      try {
        System.abortJob(triggerJob.Id);
      } catch (Exception e) {
        // ignore if already executed/aborted
      }
    }
  }

  private static void preCreateFirstCompensationStep(Workflow_Instance__c instance) {
    if (String.isBlank(instance.Compensation_Stack__c)) {
      return;
    }
    List<String> stack = (List<String>) JSON.deserialize(
      instance.Compensation_Stack__c,
      List<String>.class
    );
    if (stack.isEmpty()) {
      return;
    }
    String activeStepName = stack[stack.size() - 1];
    String compensationStepLogName = activeStepName + '_Compensate';

    // Check if it already exists to avoid duplicates
    List<Workflow_Step_Execution__c> existing = [
      SELECT Id
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c = :instance.Id
        AND Step_Name__c = :compensationStepLogName
      WITH SYSTEM_MODE
      LIMIT 1
    ];
    if (!existing.isEmpty()) {
      return;
    }

    List<Workflow_Step_Execution__c> originalExecs = [
      SELECT Input__c, Output__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :instance.Id
        AND Step_Name__c = :activeStepName
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC, Id DESC
      LIMIT 1
    ];

    Workflow_Step_Execution__c compStepExec = new Workflow_Step_Execution__c();
    compStepExec.Workflow_Instance__c = instance.Id;
    compStepExec.Step_Name__c = compensationStepLogName;
    compStepExec.Status__c = 'Pending';
    compStepExec.Input__c = !originalExecs.isEmpty()
      ? originalExecs[0].Input__c
      : null;
    compStepExec.Output__c = !originalExecs.isEmpty()
      ? originalExecs[0].Output__c
      : null;
    compStepExec.Retry_Count__c = 0;
    insert as system compStepExec;
  }

  /**
   * Cancels a workflow instance, aborts scheduled jobs, and optionally runs saga compensations.
   */
  public static void cancel(Id instanceId, Boolean runCompensations) {
    List<Workflow_Instance__c> instances = [
      SELECT Id, Status__c, Current_Step__c, Compensation_Stack__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
      WITH SYSTEM_MODE
      LIMIT 1
    ];
    if (instances.isEmpty()) {
      throw new WorkflowException('Workflow instance not found: ' + instanceId);
    }

    Workflow_Instance__c instance = instances[0];
    if (
      instance.Status__c == 'Completed' ||
      instance.Status__c == 'Failed' ||
      instance.Status__c == 'Compensated' ||
      instance.Status__c == 'Cancelled' ||
      instance.Status__c == 'ContinuedAsNew'
    ) {
      return; // Already in terminal state
    }

    // 1. Lock active step executions FOR UPDATE first
    List<Workflow_Step_Execution__c> stepExecs = new List<Workflow_Step_Execution__c>();
    if (String.isNotBlank(instance.Current_Step__c)) {
      List<String> activeStepNames = new List<String>();
      if (instance.Current_Step__c.contains(',')) {
        activeStepNames = instance.Current_Step__c.split(',');
      } else {
        activeStepNames.add(instance.Current_Step__c);
      }

      stepExecs = [
        SELECT Id, Status__c
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Step_Name__c IN :activeStepNames
          AND Status__c IN ('Running', 'Pending', 'Retrying')
        WITH SYSTEM_MODE
        FOR UPDATE
      ];
    }

    // 2. Lock the instance FOR UPDATE second
    instances = [
      SELECT Id, Status__c, Current_Step__c, Compensation_Stack__c, Error_Message__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
      WITH SYSTEM_MODE
      LIMIT 1
      FOR UPDATE
    ];
    if (instances.isEmpty()) {
      throw new WorkflowException('Workflow instance not found: ' + instanceId);
    }
    instance = instances[0];

    // Recheck status under lock
    if (
      instance.Status__c == 'Completed' ||
      instance.Status__c == 'Failed' ||
      instance.Status__c == 'Compensated' ||
      instance.Status__c == 'Cancelled' ||
      instance.Status__c == 'ContinuedAsNew'
    ) {
      return;
    }

    // Abort all scheduled jobs for this instance (sleeps, retries, timeouts)
    abortScheduledJobs(instanceId);

    // Update step executions to Cancelled
    for (Workflow_Step_Execution__c stepExec : stepExecs) {
      stepExec.Status__c = 'Cancelled';
    }
    if (!stepExecs.isEmpty()) {
      update as system stepExecs;
    }

    // Check for compensations
    Boolean hasCompensations = false;
    if (runCompensations && String.isNotBlank(instance.Compensation_Stack__c)) {
      List<String> stack = (List<String>) JSON.deserialize(
        instance.Compensation_Stack__c,
        List<String>.class
      );
      hasCompensations = !stack.isEmpty();
    }

    if (hasCompensations) {
      instance.Status__c = 'Cancelling';
      instance.Error_Message__c = 'Cancelled by user. Compensating.';
      preCreateFirstCompensationStep(instance);
      update as system instance;

      scheduleTimeoutJobForInstance(instance.Id);

      // Kick off rollback loop
      if (Test.isRunningTest()) {
        if (!disableQueueableInTest) {
          System.enqueueJob(new WorkflowOrchestrator(instance.Id));
        }
      } else {
        enqueueOrchestrator(instance.Id, null);
      }
    } else {
      instance.Status__c = 'Cancelled';
      instance.Error_Message__c = 'Cancelled by user.';
      update as system instance;
    }

    // Recursively cancel active child workflows
    List<Workflow_Instance__c> childInstances = [
      SELECT Id
      FROM Workflow_Instance__c
      WHERE
        Parent_Instance__c = :instance.Id
        AND Status__c IN ('Pending', 'Running', 'Suspended', 'Cancelling')
      WITH SYSTEM_MODE
    ];
    for (Workflow_Instance__c child : childInstances) {
      cancel(child.Id, runCompensations);
    }
  }

  /**
   * Aborts all Scheduled Apex cron jobs associated with the workflow instance.
   */
  public static void abortScheduledJobs(Id instanceId) {
    String sleepPrefix = 'WorkflowSleep_' + instanceId + '_%';
    String retryPrefix = 'WorkflowRetry_' + instanceId + '_%';
    String timeoutPrefix = 'Timeout_' + instanceId + '_%';
    List<CronTrigger> triggers = [
      SELECT Id
      FROM CronTrigger
      WHERE
        CronJobDetail.Name LIKE :sleepPrefix
        OR CronJobDetail.Name LIKE :retryPrefix
        OR CronJobDetail.Name LIKE :timeoutPrefix
      WITH SYSTEM_MODE
    ];
    for (CronTrigger triggerJob : triggers) {
      try {
        System.abortJob(triggerJob.Id);
      } catch (Exception e) {
        // ignore
      }
    }
  }

  public static void enqueueOrchestrator(Id instanceId, String stepName) {
    if (Test.isRunningTest()) {
      return;
    }
    Workflow_Event__e event = new Workflow_Event__e(
      Workflow_Instance_Id__c = instanceId,
      Event_Type__c = 'RUN_STEP',
      Payload__c = stepName
    );
    Database.SaveResult sr = EventBus.publish(event);
    if (!sr.isSuccess()) {
      List<String> errMsgs = new List<String>();
      for (Database.Error err : sr.getErrors()) {
        errMsgs.add(err.getStatusCode() + ': ' + err.getMessage());
      }
      throw new WorkflowException(
        'Failed to publish orchestrator event: ' + String.join(errMsgs, ', ')
      );
    }
  }

  private static void validateCorrelationKey(String correlationKey) {
    if (String.isBlank(correlationKey)) {
      throw new WorkflowException('Correlation key is required.');
    }
    if (correlationKey.length() > 200) {
      throw new WorkflowException(
        'Correlation key length cannot exceed 200 characters.'
      );
    }
  }

  public static String resolvePayload(String textValue) {
    if (
      String.isNotBlank(textValue) && textValue.startsWith('{"$attachmentId":')
    ) {
      try {
        Map<String, Object> marker = (Map<String, Object>) JSON.deserializeUntyped(
          textValue
        );
        Id attachmentId = (Id) marker.get('$attachmentId');
        List<ContentVersion> cvs = [
          SELECT VersionData
          FROM ContentVersion
          WHERE ContentDocumentId = :attachmentId AND IsLatest = TRUE
          WITH SYSTEM_MODE
        ];
        if (!cvs.isEmpty()) {
          return cvs[0].VersionData.toString();
        }
      } catch (Exception ex) {
        // fallback to original value
      }
    }
    return textValue;
  }

  public static String savePayloadIfNeeded(
    Id instanceId,
    String textValue,
    String title
  ) {
    if (String.isNotBlank(textValue) && textValue.length() > 100000) {
      ContentVersion cv = new ContentVersion();
      cv.Title = title;
      cv.PathOnClient = title + '.json';
      cv.VersionData = Blob.valueOf(textValue);
      insert as system cv;

      Id docId = [
        SELECT ContentDocumentId
        FROM ContentVersion
        WHERE Id = :cv.Id
        WITH SYSTEM_MODE
      ]
      .ContentDocumentId;

      ContentDocumentLink cdl = new ContentDocumentLink();
      cdl.ContentDocumentId = docId;
      cdl.LinkedEntityId = instanceId;
      cdl.ShareType = 'V';
      cdl.Visibility = 'InternalUsers';
      try {
        insert as system cdl;
      } catch (DmlException ex) {
        cdl.Visibility = 'AllUsers';
        insert as system cdl;
      }

      return JSON.serialize(
        new Map<String, String>{ '$attachmentId' => docId }
      );
    }
    return textValue;
  }

  public static void scheduleTimeoutJobForInstance(Id instanceId) {
    List<Workflow_Instance__c> instances = [
      SELECT Status__c, Current_Step__c, Compensation_Stack__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
      WITH SYSTEM_MODE
      LIMIT 1
    ];
    if (instances.isEmpty()) {
      return;
    }
    Workflow_Instance__c instance = instances[0];
    if (
      instance.Status__c == 'Compensating' ||
      instance.Status__c == 'Cancelling'
    ) {
      if (String.isNotBlank(instance.Compensation_Stack__c)) {
        List<String> stack = (List<String>) JSON.deserialize(
          instance.Compensation_Stack__c,
          List<String>.class
        );
        if (!stack.isEmpty()) {
          scheduleTimeoutJobIfNeeded(
            instanceId,
            stack[stack.size() - 1] + '_Compensate'
          );
        }
      }
    } else if (String.isNotBlank(instance.Current_Step__c)) {
      if (instance.Current_Step__c.contains(',')) {
        for (String pStep : instance.Current_Step__c.split(',')) {
          scheduleTimeoutJobIfNeeded(instanceId, pStep.trim());
        }
      } else {
        scheduleTimeoutJobIfNeeded(instanceId, instance.Current_Step__c);
      }
    }
  }

  public static void scheduleTimeoutJobIfNeeded(
    Id instanceId,
    String stepName
  ) {
    if (String.isBlank(stepName)) {
      return;
    }
    String className = stepName.endsWith('_Compensate')
      ? stepName.substring(0, stepName.lastIndexOf('_Compensate'))
      : stepName;
    try {
      Type stepType = Type.forName(className);
      if (stepType != null) {
        Object stepObj = stepType.newInstance();
        if (stepObj instanceof TimeoutConfigurable) {
          Integer timeoutSeconds = ((TimeoutConfigurable) stepObj)
            .getTimeoutSeconds();
          if (timeoutSeconds != null && timeoutSeconds > 0) {
            WorkflowTimeoutJob job = new WorkflowTimeoutJob(
              instanceId,
              stepName
            );
            Datetime runTime = Datetime.now()
              .addSeconds(
                Test.isRunningTest() ? timeoutSeconds + 60 : timeoutSeconds
              );
            String cronStr =
              runTime.second() +
              ' ' +
              runTime.minute() +
              ' ' +
              runTime.hour() +
              ' ' +
              runTime.day() +
              ' ' +
              runTime.month() +
              ' ? ' +
              runTime.year();
            String cleanStepName = stepName.replaceAll('[^a-zA-Z0-9]', '_');
            String jobName = 'Timeout_' + instanceId + '_' + cleanStepName;
            System.schedule(jobName, cronStr, job);
          }
        }
      }
    } catch (Exception ex) {
      // Ignore/log
    }
  }

  private static String resolveContinueAsNewKey(
    String currentKey,
    String customKey
  ) {
    if (String.isNotBlank(customKey)) {
      return customKey;
    }
    if (String.isBlank(currentKey)) {
      return 'Run_' + System.currentTimeMillis();
    }

    Pattern p = Pattern.compile('^(.*)_run(\\d+)$');
    Matcher m = p.matcher(currentKey);
    if (m.matches()) {
      String base = m.group(1);
      Integer nextNum = Integer.valueOf(m.group(2)) + 1;
      return base + '_run' + nextNum;
    }
    return currentKey + '_run2';
  }
}
