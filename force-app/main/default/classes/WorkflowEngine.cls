public inherited sharing class WorkflowEngine {
  public static Boolean disableQueueableInTest = false;
  public static Integer watchdogDelayMinutes = 10;
  public static Boolean useDynamicScheduling = true;

  // Max number of timed-out steps a single watchdog heartbeat will fail. Each failure
  // triggers failWorkflowInstance() (its own SOQL/DML + optional alert queries), so this
  // bounds the heartbeat's governor usage. Remaining timeouts drain on the next heartbeat.
  @TestVisible
  private static Integer WATCHDOG_TIMEOUT_BATCH_SIZE = 50;
  // Max number of sleeping instances a single heartbeat resumes, for the same reason.
  @TestVisible
  private static Integer WATCHDOG_RESUME_BATCH_SIZE = 200;

  static {
    try {
      List<Revenant_Config__mdt> configs = [
        SELECT Watchdog_Delay_Minutes__c, Use_Dynamic_Scheduling__c
        FROM Revenant_Config__mdt
        WHERE DeveloperName = 'Default'
        WITH SYSTEM_MODE
        LIMIT 1
      ];
      if (!configs.isEmpty()) {
        if (configs[0].Watchdog_Delay_Minutes__c != null) {
          watchdogDelayMinutes = configs[0]
            .Watchdog_Delay_Minutes__c.intValue();
        }
        if (configs[0].Use_Dynamic_Scheduling__c != null) {
          useDynamicScheduling = configs[0].Use_Dynamic_Scheduling__c;
        }
      }
    } catch (Exception ex) {
      System.debug(LoggingLevel.WARN, 'Revenant configuration metadata query failed: ' + ex.getMessage());
    }
  }

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
      Integer timeout = getStepTimeoutSeconds(instance.Current_Step__c);
      if (timeout != null && timeout > 0) {
        stepExec.Timeout_At__c = DateTime.now().addSeconds(timeout);
      }
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
      Integer timeout = getStepTimeoutSeconds(instance.Current_Step__c);
      if (timeout != null && timeout > 0) {
        stepExec.Timeout_At__c = DateTime.now().addSeconds(timeout);
      }
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

  public class StartRequest {
    public String workflowName;
    public String correlationKey;
    public Object input;
    public Id parentInstanceId;

    public StartRequest(
      String workflowName,
      String correlationKey,
      Object input
    ) {
      this.workflowName = workflowName;
      this.correlationKey = correlationKey;
      this.input = input;
    }

    public StartRequest(
      String workflowName,
      String correlationKey,
      Object input,
      Id parentInstanceId
    ) {
      this.workflowName = workflowName;
      this.correlationKey = correlationKey;
      this.input = input;
      this.parentInstanceId = parentInstanceId;
    }
  }

  public class ResumeRequest {
    public String correlationKey;
    public Id instanceId;
    public String payload;

    public ResumeRequest(String correlationKey, String payload) {
      this.correlationKey = correlationKey;
      this.payload = payload;
    }

    public ResumeRequest(Id instanceId, String payload) {
      this.instanceId = instanceId;
      this.payload = payload;
    }
  }

  public class SignalRequest {
    public String keyOrId;
    public String signalName;
    public String payload;

    public SignalRequest(String keyOrId, String signalName, String payload) {
      this.keyOrId = keyOrId;
      this.signalName = signalName;
      this.payload = payload;
    }
  }

  /**
   * Starts multiple durable workflow instances in a bulk-friendly transaction.
   */
  public static List<Id> start(List<StartRequest> requests) {
    if (requests == null || requests.isEmpty()) {
      return new List<Id>();
    }

    // 1. Gather correlation keys and validate
    Set<String> correlationKeys = new Set<String>();
    for (StartRequest req : requests) {
      validateCorrelationKey(req.correlationKey);
      if (String.isNotBlank(req.correlationKey)) {
        correlationKeys.add(req.correlationKey);
      }
    }

    // 2. Enforce uniqueness of active correlation keys in bulk
    if (!correlationKeys.isEmpty()) {
      List<Workflow_Instance__c> existing = [
        SELECT Id, Correlation_Key__c
        FROM Workflow_Instance__c
        WHERE
          Correlation_Key__c IN :correlationKeys
          AND Status__c IN ('Pending', 'Running', 'Suspended')
        WITH SYSTEM_MODE
      ];
      if (!existing.isEmpty()) {
        throw new WorkflowException(
          'An active workflow already exists with correlation key: ' +
          existing[0].Correlation_Key__c
        );
      }
    }

    // 3. Construct Workflow_Instance__c records
    List<Workflow_Instance__c> instances = new List<Workflow_Instance__c>();
    for (StartRequest req : requests) {
      Workflow_Instance__c instance = new Workflow_Instance__c();
      instance.Workflow_Name__c = req.workflowName;
      instance.Status__c = 'Pending';
      instance.Correlation_Key__c = req.correlationKey;
      instance.Parent_Instance__c = req.parentInstanceId;

      // Resolve version and initial step
      Type wflowType = Type.forName(req.workflowName);
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
      instances.add(instance);
    }

    try {
      insert as system instances;
    } catch (DmlException ex) {
      if (ex.getDmlStatusCode(0) == 'DUPLICATE_VALUE') {
        throw new WorkflowException(
          'An active workflow already exists with duplicate correlation key constraint.'
        );
      }
      throw ex;
    }

    // 4. Resolve input payloads and update instances
    for (Integer i = 0; i < requests.size(); i++) {
      StartRequest req = requests[i];
      Workflow_Instance__c instance = instances[i];
      String inputJson = (req.input != null) ? JSON.serialize(req.input) : null;
      instance.Input__c = savePayloadIfNeeded(
        instance.Id,
        inputJson,
        'Input_' + instance.Id
      );
    }
    update as system instances;

    // 5. Construct initial Step Execution logs
    List<Workflow_Step_Execution__c> stepExecs = new List<Workflow_Step_Execution__c>();
    for (Workflow_Instance__c instance : instances) {
      if (String.isNotBlank(instance.Current_Step__c)) {
        Workflow_Step_Execution__c stepExec = new Workflow_Step_Execution__c();
        stepExec.Workflow_Instance__c = instance.Id;
        stepExec.Step_Name__c = instance.Current_Step__c;
        stepExec.Status__c = 'Pending';
        stepExec.Input__c = instance.Input__c;
        stepExec.Retry_Count__c = 0;
        Integer timeout = getStepTimeoutSeconds(instance.Current_Step__c);
        if (timeout != null && timeout > 0) {
          stepExec.Timeout_At__c = DateTime.now().addSeconds(timeout);
        }
        stepExecs.add(stepExec);
      }
    }
    if (!stepExecs.isEmpty()) {
      insert as system stepExecs;
    }

    // 6. Schedule timeout jobs for the instances (bulk-friendly)
    scheduleTimeoutJobsForInstances(instances);

    // 7. Enqueue orchestrator execution in bulk
    List<Id> instanceIds = new List<Id>();
    for (Workflow_Instance__c instance : instances) {
      instanceIds.add(instance.Id);
    }
    enqueueOrchestrators(instanceIds);

    return instanceIds;
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
        Integer timeout = getStepTimeoutSeconds(instance.Current_Step__c);
        if (timeout != null && timeout > 0) {
          stepExec.Timeout_At__c = DateTime.now().addSeconds(timeout);
        } else {
          stepExec.Timeout_At__c = null;
        }
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
        Integer timeout = getStepTimeoutSeconds(instance.Current_Step__c);
        if (timeout != null && timeout > 0) {
          stepExec.Timeout_At__c = DateTime.now().addSeconds(timeout);
        } else {
          stepExec.Timeout_At__c = null;
        }
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
   * Resumes multiple suspended workflows in a bulk-friendly transaction.
   */
  public static void resume(List<ResumeRequest> requests) {
    if (requests == null || requests.isEmpty()) {
      return;
    }

    Set<String> keys = new Set<String>();
    Set<Id> ids = new Set<Id>();
    for (ResumeRequest req : requests) {
      if (req.instanceId != null) {
        ids.add(req.instanceId);
      } else if (String.isNotBlank(req.correlationKey)) {
        keys.add(req.correlationKey);
      }
    }

    List<Workflow_Instance__c> instances = [
      SELECT Id, Workflow_Name__c, Current_Step__c, Correlation_Key__c
      FROM Workflow_Instance__c
      WHERE
        (Id IN :ids
        OR Correlation_Key__c IN :keys)
        AND Status__c = 'Suspended'
      WITH SYSTEM_MODE
      FOR UPDATE
    ];

    Map<Id, Workflow_Instance__c> instById = new Map<Id, Workflow_Instance__c>();
    Map<String, Workflow_Instance__c> instByKey = new Map<String, Workflow_Instance__c>();
    for (Workflow_Instance__c inst : instances) {
      instById.put(inst.Id, inst);
      if (String.isNotBlank(inst.Correlation_Key__c)) {
        instByKey.put(inst.Correlation_Key__c, inst);
      }
    }

    // Verify that we found a suspended instance for every request
    for (ResumeRequest req : requests) {
      Workflow_Instance__c inst = null;
      if (req.instanceId != null) {
        inst = instById.get(req.instanceId);
      } else if (String.isNotBlank(req.correlationKey)) {
        inst = instByKey.get(req.correlationKey);
      }
      if (inst == null) {
        throw new WorkflowException(
          'No suspended workflow found with key or ID: ' +
          (req.instanceId != null
            ? (String) req.instanceId
            : req.correlationKey)
        );
      }
    }

    // Gathers active step execution logs for the instances in bulk
    Set<Id> activeInstIds = instById.keySet();
    List<Workflow_Step_Execution__c> allActiveSteps = [
      SELECT Id, Workflow_Instance__c, Step_Name__c, Status__c, Output__c
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c IN :activeInstIds
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC, Id DESC
    ];

    Map<Id, Workflow_Step_Execution__c> latestStepByInstanceId = new Map<Id, Workflow_Step_Execution__c>();
    for (Workflow_Step_Execution__c step : allActiveSteps) {
      if (!latestStepByInstanceId.containsKey(step.Workflow_Instance__c)) {
        Workflow_Instance__c inst = instById.get(step.Workflow_Instance__c);
        if (inst != null && String.isNotBlank(inst.Current_Step__c)) {
          Boolean stepMatches = false;
          if (inst.Current_Step__c.contains(',')) {
            for (String pStep : inst.Current_Step__c.split(',')) {
              if (pStep.trim() == step.Step_Name__c) {
                stepMatches = true;
                break;
              }
            }
          } else if (inst.Current_Step__c == step.Step_Name__c) {
            stepMatches = true;
          }
          if (stepMatches) {
            latestStepByInstanceId.put(step.Workflow_Instance__c, step);
          }
        }
      }
    }

    List<Workflow_Instance__c> instancesToUpdate = new List<Workflow_Instance__c>();
    List<Workflow_Step_Execution__c> stepsToUpdate = new List<Workflow_Step_Execution__c>();

    for (ResumeRequest req : requests) {
      Workflow_Instance__c inst = null;
      if (req.instanceId != null) {
        inst = instById.get(req.instanceId);
      } else if (String.isNotBlank(req.correlationKey)) {
        inst = instByKey.get(req.correlationKey);
      }

      if (inst != null) {
        inst.Status__c = 'Running';
        instancesToUpdate.add(inst);

        Workflow_Step_Execution__c stepExec = latestStepByInstanceId.get(
          inst.Id
        );
        if (stepExec != null) {
          stepExec.Status__c = 'Running';
          stepExec.Output__c = savePayloadIfNeeded(
            inst.Id,
            req.payload,
            'Resume_' + stepExec.Id
          );
          Integer timeout = getStepTimeoutSeconds(inst.Current_Step__c);
          if (timeout != null && timeout > 0) {
            stepExec.Timeout_At__c = DateTime.now().addSeconds(timeout);
          } else {
            stepExec.Timeout_At__c = null;
          }
          stepsToUpdate.add(stepExec);
        }
      }
    }

    update as system instancesToUpdate;
    if (!stepsToUpdate.isEmpty()) {
      update as system stepsToUpdate;
    }

    scheduleTimeoutJobsForInstances(instancesToUpdate);

    List<Id> instanceIds = new List<Id>();
    for (Workflow_Instance__c inst : instancesToUpdate) {
      instanceIds.add(inst.Id);
    }
    enqueueOrchestrators(instanceIds);
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
        Definition_Version__c,
        Error_Message__c
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

    Boolean isCompensating = (instance.Status__c == 'Compensating' ||
    instance.Status__c == 'Cancelling');
    if (instance.Status__c == 'Suspended') {
      List<Workflow_Step_Execution__c> latestSteps = [
        SELECT Step_Name__c
        FROM Workflow_Step_Execution__c
        WHERE Workflow_Instance__c = :instance.Id
        WITH SYSTEM_MODE
        ORDER BY CreatedDate DESC, Id DESC
        LIMIT 1
      ];
      if (
        !latestSteps.isEmpty() &&
        latestSteps[0].Step_Name__c != null &&
        latestSteps[0].Step_Name__c.endsWith('_Compensate')
      ) {
        isCompensating = true;
      }
    }

    if (isCompensating) {
      if (instance.Status__c == 'Suspended') {
        if (
          instance.Error_Message__c != null &&
          instance.Error_Message__c.contains('Cancelled')
        ) {
          instance.Status__c = 'Cancelling';
        } else {
          instance.Status__c = 'Compensating';
        }
        instance.Async_Job_Id__c = null;
        update as system instance;
      }
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
      instance.Async_Job_Id__c = null;
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
      if (
        String.isBlank(instance.Current_Step__c) ||
        !instance.Current_Step__c.contains(',')
      ) {
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
        Definition_Version__c,
        Error_Message__c
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

    Boolean isParallelBranchStep =
      String.isNotBlank(stepName) &&
      String.isNotBlank(instance.Current_Step__c) &&
      instance.Current_Step__c.contains(',');
    StepContext.SignalSource signalSrc = isParallelBranchStep
      ? (StepContext.SignalSource) new ParallelBranchSignalSource(instanceId)
      : (StepContext.SignalSource) new PendingSignalSource(instanceId);
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
        : 1,
      signalSrc
    );

    // Save/Commit step execution status and set Timeout_At__c before executing the step so watchdog can detect timeouts
    stepExec.Status__c = 'Running';
    Integer timeoutSeconds = null;
    if (stepInstance instanceof TimeoutConfigurable) {
      timeoutSeconds = ((TimeoutConfigurable) stepInstance).getTimeoutSeconds();
    }
    if (timeoutSeconds != null && timeoutSeconds > 0) {
      stepExec.Timeout_At__c = DateTime.now().addSeconds(timeoutSeconds);
      saveStepExec(stepExec);
    } else {
      stepExec.Timeout_At__c = null;
      if (stepExec.Id == null) {
        saveStepExec(stepExec);
      }
    }

    StepResult result;
    try {
      result = stepInstance.execute(context);
    } finally {
      if (timeoutSeconds != null && timeoutSeconds > 0) {
        stepExec.Timeout_At__c = null;
        saveStepExec(stepExec);
        cancelTimeoutJob(instanceId, activeStepName);
      }
    }

    // 6. Handle Step Outcome
    handleStepResult(instance, stepExec, result, context);
  }

  /**
   * Lazily supplies the pending (unconsumed) signals targeting an instance so a
   * step that never reads signals pays no query/heap cost for unrelated
   * unconsumed signals on the instance.
   */
  private class PendingSignalSource implements StepContext.SignalSource {
    private final Id instanceId;

    private PendingSignalSource(Id instanceId) {
      this.instanceId = instanceId;
    }

    public List<StepContext.Signal> getPendingSignals(String signalName) {
      return loadPendingSignals(this.instanceId, signalName);
    }

    public StepContext.Signal getLatestSignal(String signalName) {
      return loadLatestSignal(this.instanceId, signalName);
    }
  }

  // Caps how many signals a single parallel-branch accessor call claims at read
  // time. A claim writes Processing now and the matching COMPLETE writes
  // Consumed later in the SAME transaction, so claim + consume both draw on the
  // 10 000 DML-row governor limit; 4 000 leaves headroom for the consume pass
  // and the engine's other DML. Bounding the claim keeps a branch facing a huge
  // redelivery backlog from blowing the limit on every attempt and stalling
  // forever; any rows beyond the cap stay Received for a later read.
  private static final Integer PARALLEL_CLAIM_ROW_CAP = 4000;

  /**
   * Signal source for parallel branch steps. Atomically claims each signal at
   * read time (Received → Processing) so two concurrent branches cannot both
   * process the same payload. The claim is held for the lifetime of the current
   * execution attempt: COMPLETE promotes Processing → Consumed; any other
   * outcome (YIELD, SUSPEND, SLEEP, RETRY, …) rolls the claim back to Received
   * so the branch can re-observe the signal on its next run. Each call claims at
   * most PARALLEL_CLAIM_ROW_CAP rows so the read can never exceed the DML-row
   * limit before the step returns.
   *
   * Two-step pattern: ORDER BY query to find the target ID, then a FOR UPDATE
   * lock on that ID alone to atomically claim it without holding a broad table
   * lock.  FOR UPDATE prevents callouts after the first signal access in the
   * same transaction; steps that need both callouts and signal reads should
   * perform the callout before the first ctx.getSignal / ctx.hasSignal call.
   */
  private class ParallelBranchSignalSource implements StepContext.SignalSource {
    private final Id instanceId;

    private ParallelBranchSignalSource(Id instanceId) {
      this.instanceId = instanceId;
    }

    public List<StepContext.Signal> getPendingSignals(String signalName) {
      // Step 1: find candidates in arrival order (ORDER BY, no FOR UPDATE),
      // bounded so a huge backlog cannot be claimed (and DML'd) all at once.
      List<Workflow_Signal__c> candidates;
      if (String.isBlank(signalName)) {
        candidates = [
          SELECT Id, Signal_Name__c, Payload__c
          FROM Workflow_Signal__c
          WHERE Workflow_Instance__c = :instanceId AND Status__c = 'Received'
          WITH SYSTEM_MODE
          ORDER BY CreatedDate ASC, Id ASC
          LIMIT :PARALLEL_CLAIM_ROW_CAP
        ];
      } else {
        candidates = [
          SELECT Id, Signal_Name__c, Payload__c
          FROM Workflow_Signal__c
          WHERE
            Workflow_Instance__c = :instanceId
            AND Status__c = 'Received'
            AND Signal_Name__c = :signalName
          WITH SYSTEM_MODE
          ORDER BY CreatedDate ASC, Id ASC
          LIMIT :PARALLEL_CLAIM_ROW_CAP
        ];
      }
      if (candidates.isEmpty()) {
        return new List<StepContext.Signal>();
      }

      // Preserve ordering and payload data keyed by Id before the lock query
      // (which cannot carry ORDER BY or extra fields alongside FOR UPDATE).
      Map<Id, Workflow_Signal__c> ordered = new Map<Id, Workflow_Signal__c>();
      for (Workflow_Signal__c c : candidates) {
        ordered.put(c.Id, c);
      }
      Set<Id> candidateIds = ordered.keySet();

      // Step 2: atomic claim — lock all candidates still in Received status
      List<Workflow_Signal__c> locked = [
        SELECT Id
        FROM Workflow_Signal__c
        WHERE Id IN :candidateIds AND Status__c = 'Received'
        WITH SYSTEM_MODE
        FOR UPDATE
      ];
      if (locked.isEmpty()) {
        return new List<StepContext.Signal>();
      }

      Set<Id> claimedIds = new Set<Id>();
      for (Workflow_Signal__c sig : locked) {
        sig.Status__c = 'Processing';
        claimedIds.add(sig.Id);
      }
      update as system locked;

      // Return only claimed signals, in original arrival order
      List<StepContext.Signal> result = new List<StepContext.Signal>();
      for (Workflow_Signal__c c : candidates) {
        if (claimedIds.contains(c.Id)) {
          result.add(
            new StepContext.Signal(c.Id, c.Signal_Name__c, c.Payload__c)
          );
        }
      }
      return result;
    }

    public StepContext.Signal getLatestSignal(String signalName) {
      if (String.isBlank(signalName)) {
        return null;
      }
      // Step 1: find the most-recent candidate (ORDER BY, no FOR UPDATE)
      List<Workflow_Signal__c> candidates = [
        SELECT Id, Signal_Name__c, Payload__c
        FROM Workflow_Signal__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Status__c = 'Received'
          AND Signal_Name__c = :signalName
        WITH SYSTEM_MODE
        ORDER BY CreatedDate DESC, Id DESC
        LIMIT 1
      ];
      if (candidates.isEmpty()) {
        return null;
      }
      Id targetId = candidates[0].Id;

      // Step 2: atomic claim — lock the specific row, check it is still Received
      List<Workflow_Signal__c> locked = [
        SELECT Id, Signal_Name__c, Payload__c
        FROM Workflow_Signal__c
        WHERE Id = :targetId AND Status__c = 'Received'
        WITH SYSTEM_MODE
        FOR UPDATE
      ];
      if (locked.isEmpty()) {
        // Another branch claimed it between step 1 and step 2
        return null;
      }
      locked[0].Status__c = 'Processing';
      update as system locked[0];

      return new StepContext.Signal(
        locked[0].Id,
        locked[0].Signal_Name__c,
        locked[0].Payload__c
      );
    }
  }

  /**
   * Loads only the single most-recent pending signal matching a name, so a step
   * reading one decision via getSignal/hasSignal does not pull every duplicate
   * payload (consumption still re-queries by name, without payloads). Returns
   * null when no matching Received signal exists.
   */
  private static StepContext.Signal loadLatestSignal(
    Id instanceId,
    String signalName
  ) {
    if (String.isBlank(signalName)) {
      return null;
    }
    List<Workflow_Signal__c> records = [
      SELECT Id, Signal_Name__c, Payload__c
      FROM Workflow_Signal__c
      WHERE
        Workflow_Instance__c = :instanceId
        AND Status__c = 'Received'
        AND Signal_Name__c = :signalName
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC, Id DESC
      LIMIT 1
    ];
    if (records.isEmpty()) {
      return null;
    }
    return new StepContext.Signal(
      records[0].Id,
      records[0].Signal_Name__c,
      records[0].Payload__c
    );
  }

  /**
   * Loads the pending (unconsumed) signals targeting an instance as read-only
   * StepContext.Signal views, in deterministic arrival order. A non-blank
   * signalName scopes the query (and its payload heap cost) to that one name so
   * a single named accessor never pulls every pending payload on the instance;
   * a blank name loads them all. Cancel control signals are handled inline by
   * signal() and never persist a Workflow_Signal__c record, so they are
   * structurally excluded here.
   */
  private static List<StepContext.Signal> loadPendingSignals(
    Id instanceId,
    String signalName
  ) {
    List<Workflow_Signal__c> records;
    if (String.isBlank(signalName)) {
      records = [
        SELECT Id, Signal_Name__c, Payload__c
        FROM Workflow_Signal__c
        WHERE Workflow_Instance__c = :instanceId AND Status__c = 'Received'
        WITH SYSTEM_MODE
        ORDER BY CreatedDate ASC, Id ASC
      ];
    } else {
      records = [
        SELECT Id, Signal_Name__c, Payload__c
        FROM Workflow_Signal__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Status__c = 'Received'
          AND Signal_Name__c = :signalName
        WITH SYSTEM_MODE
        ORDER BY CreatedDate ASC, Id ASC
      ];
    }

    List<StepContext.Signal> signals = new List<StepContext.Signal>();
    for (Workflow_Signal__c sig : records) {
      signals.add(
        new StepContext.Signal(sig.Id, sig.Signal_Name__c, sig.Payload__c)
      );
    }
    return signals;
  }

  /**
   * Rolls back any Processing claims made by a parallel branch step that did
   * not reach a durable COMPLETE transition (e.g. YIELD, SUSPEND, SLEEP,
   * WAIT_FOR_APPROVAL, START_CHILD, RETRY). Restoring to Received allows the
   * same branch (on its next run) or another branch to re-observe the signal.
   * No-op for serial steps (which never claim; they use PendingSignalSource).
   */
  private static void rollbackClaimedSignals(StepContext context) {
    if (context == null) {
      return;
    }
    Set<Id> claimedIds = context.getConsumedSignalIds();
    if (claimedIds == null || claimedIds.isEmpty()) {
      return;
    }
    List<Workflow_Signal__c> toRollback = [
      SELECT Id
      FROM Workflow_Signal__c
      WHERE Id IN :claimedIds AND Status__c = 'Processing'
      WITH SYSTEM_MODE
    ];
    if (toRollback.isEmpty()) {
      return;
    }
    for (Workflow_Signal__c sig : toRollback) {
      sig.Status__c = 'Received';
    }
    update as system toRollback;
  }

  /**
   * Marks the signals a step matched consumed at its successful transition.
   * The exact rows the step observed/claimed (context.getConsumedSignalIds())
   * are consumed FIRST so they can never be starved by the row cap when a name
   * has a large backlog of duplicates; only then is any remaining budget spent
   * cleaning up same-name at-least-once duplicates (including one delivered
   * mid-execution after the snapshot was taken). A name only probed absent never
   * consumes a signal that arrives afterwards (it contributes no matched id and
   * no matched name).
   *
   * Scoping by transition kind:
   *  - A parallel branch consumes ONLY its own claimed ids. Those rows are its
   *    exclusively-held Processing claims (locked + flipped atomically at read),
   *    so promoting them to Consumed cannot race a sibling. Name-based duplicate
   *    cleanup is deliberately skipped here: a concurrent sibling may legitimately
   *    hold (or be about to claim) another row of the same name, and consuming it
   *    would strip a signal from a branch that has not durably finished.
   *  - A serial step additionally cleans up same-name duplicates (no sibling can
   *    be racing them), catching an at-least-once redelivery that arrived after
   *    the snapshot was taken.
   *
   * Matched ids are always consumed first so the exact row the step read is never
   * left behind in favor of unrelated duplicates when a name has a large backlog.
   * The combined update is capped at 9 000 rows to stay below the 10 000 DML-row
   * governor limit; any excess duplicate rows are consumed on the next COMPLETE
   * that observes them (which cannot re-process them since the step no longer
   * matches once it has completed).
   */
  private static void markSignalsConsumed(
    Id instanceId,
    StepContext context,
    Boolean parallelBranch
  ) {
    if (context == null) {
      return;
    }
    Set<Id> matchedIds = context.getConsumedSignalIds();
    if (matchedIds == null) {
      matchedIds = new Set<Id>();
    }
    Set<String> matchedNames = context.getConsumedSignalNames();
    if (matchedNames == null) {
      matchedNames = new Set<String>();
    }
    // A step that matched nothing triggers no query, keeping non-signal steps cheap.
    if (matchedIds.isEmpty() && matchedNames.isEmpty()) {
      return;
    }

    final Integer ROW_CAP = 9000;
    Map<Id, Workflow_Signal__c> toConsume = new Map<Id, Workflow_Signal__c>();

    // 1. Consume the exact rows the step observed/claimed first. For a parallel
    //    branch these claimed ids are the ONLY safe set (see scoping note above).
    if (!matchedIds.isEmpty()) {
      for (Workflow_Signal__c sig : [
        SELECT Id
        FROM Workflow_Signal__c
        WHERE Id IN :matchedIds AND Status__c IN ('Received', 'Processing')
        WITH SYSTEM_MODE
        LIMIT 9000
      ]) {
        toConsume.put(sig.Id, sig);
      }
    }

    // 2. Serial steps only: spend remaining budget cleaning up same-name
    //    duplicates that were not part of the snapshot (an at-least-once
    //    redelivery that landed mid-execution), so they cannot reappear later.
    Integer remaining = ROW_CAP - toConsume.size();
    if (!parallelBranch && !matchedNames.isEmpty() && remaining > 0) {
      for (Workflow_Signal__c sig : [
        SELECT Id
        FROM Workflow_Signal__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Status__c IN ('Received', 'Processing')
          AND Signal_Name__c IN :matchedNames
          AND Id NOT IN :matchedIds
        WITH SYSTEM_MODE
        LIMIT :remaining
      ]) {
        toConsume.put(sig.Id, sig);
      }
    }

    if (toConsume.isEmpty()) {
      return;
    }
    for (Workflow_Signal__c sig : toConsume.values()) {
      sig.Status__c = 'Consumed';
    }
    update as system toConsume.values();
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
    StepResult result,
    StepContext context
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
    Boolean isParallel =
      String.isNotBlank(instance.Current_Step__c) &&
      instance.Current_Step__c.contains(',');

    if (result.action == StepResult.ActionType.COMPLETE) {
      // Step is complete. Store output.
      stepExec.Status__c = 'Completed';
      stepExec.Output__c = savePayloadIfNeeded(
        instance.Id,
        result.outputJson,
        'Output_' + stepExec.Step_Name__c.replaceAll('[^a-zA-Z0-9]', '_')
      );
      saveStepExec(stepExec);

      // Tie signal consumption to the step's durable COMPLETE transition: only
      // now (not on yield/retry/suspend) are the signals this step observed
      // marked consumed, so an at-least-once redelivered duplicate cannot be
      // reprocessed by a later step. A parallel branch consumes only its own
      // claimed ids so it cannot strip a sibling branch's signal.
      markSignalsConsumed(instance.Id, context, isParallel);

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
            System.debug(LoggingLevel.FINE, 'Parallel step output was not JSON, falling back to raw string: ' + ex.getMessage());
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
      if (isParallel) {
        rollbackClaimedSignals(context);
      }
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
      if (isParallel) {
        rollbackClaimedSignals(context);
      }
      stepExec.Status__c = 'Pending';
      saveStepExec(stepExec);

      instance.Status__c = 'Suspended';
      update as system instance;
    } else if (result.action == StepResult.ActionType.SLEEP) {
      // Step requested sleep
      if (isParallel) {
        rollbackClaimedSignals(context);
      }
      stepExec.Status__c = 'Pending';
      stepExec.Output__c = savePayloadIfNeeded(
        instance.Id,
        result.stepStateJson,
        'State_' + stepExec.Step_Name__c.replaceAll('[^a-zA-Z0-9]', '_')
      );
      saveStepExec(stepExec);

      instance.Status__c = 'Suspended';
      instance.Sleep_Until__c = DateTime.now()
        .addSeconds(result.sleepDurationSeconds);
      instance.Async_Job_Id__c = scheduleSleepResume(instance.Id, result.sleepDurationSeconds);
      update as system instance;
    } else if (result.action == StepResult.ActionType.START_CHILD) {
      // Step requested child workflow.
      //
      // Observed signals are intentionally NOT consumed here. START_CHILD
      // suspends and re-runs the SAME step when the child completes (like
      // SUSPEND/WAIT_FOR_APPROVAL), rather than transitioning forward like
      // COMPLETE/SPLIT. Consuming on this path would break a step that re-reads
      // its kickoff signal on resume to confirm it is still in the active flow.
      // A START_CHILD step should therefore check the child-completion signal
      // before re-acting on a kickoff signal (or stash needed data in step state).
      if (isParallel) {
        rollbackClaimedSignals(context);
      }
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
      if (isParallel) {
        rollbackClaimedSignals(context);
      }
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

      // The spawning step durably completed; consume the signals it observed so
      // they are not re-loaded into the parallel branches it fans out to. The
      // spawning step runs serially (it is the fan-out point, not a branch), so
      // same-name duplicate cleanup is safe here.
      markSignalsConsumed(instance.Id, context, false);

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
        Integer timeout = getStepTimeoutSeconds(ps);
        if (timeout != null && timeout > 0) {
          pe.Timeout_At__c = DateTime.now().addSeconds(timeout);
        }
        parallelExecs.add(pe);
      }
      insert as system parallelExecs;

      scheduleTimeoutJobForInstance(instance.Id);
      for (String ps : result.parallelStepNames) {
        enqueueOrchestrator(instance.Id, ps);
      }
    } else if (result.action == StepResult.ActionType.RETRY) {
      // Step requested retry
      if (isParallel) {
        rollbackClaimedSignals(context);
      }
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

        instance.Status__c = 'Suspended';
        instance.Sleep_Until__c = DateTime.now().addSeconds(delay);
        instance.Async_Job_Id__c = scheduleRetry(instance.Id, stepExec.Step_Name__c, delay);
        update as system instance;
      }
    } else if (result.action == StepResult.ActionType.CONTINUE_AS_NEW) {
      if (isParallel) {
        rollbackClaimedSignals(context);
      }
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
            'An active workflow already exists with correlation key: ' + newKey
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
        Integer timeout = getStepTimeoutSeconds(initialStep);
        if (timeout != null && timeout > 0) {
          nextStepExec.Timeout_At__c = DateTime.now().addSeconds(timeout);
        }
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

    // Kick off rollback loop
    if (Test.isRunningTest()) {
      if (!disableQueueableInTest) {
        System.enqueueJob(new WorkflowOrchestrator(instance.Id));
      }
    } else {
      enqueueOrchestrator(instance.Id, null);
    }
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

    // Schedule the watchdog for the child's initial step before executing it, matching
    // the start() overloads. Without this a TimeoutConfigurable first step of a child
    // workflow would never get a scheduled timeout job.
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
    String wflowPrefix = Workflow_Instance__c.SObjectType.getDescribe().getKeyPrefix();
    Pattern idPattern = Pattern.compile('^[a-zA-Z0-9]{15}([a-zA-Z0-9]{3})?$');
    Boolean isId = String.isNotBlank(keyOrId) &&
                   idPattern.matcher(keyOrId).matches() &&
                   keyOrId.startsWith(wflowPrefix);
    Id targetId = isId ? (Id) keyOrId : null;

    List<Workflow_Instance__c> instances = new List<Workflow_Instance__c>();
    if (isId) {
      // Query by ID first to prevent matching a correlation key that equals this ID string
      instances = [
        SELECT Id, Status__c
        FROM Workflow_Instance__c
        WHERE
          Id = :targetId
          AND Status__c IN ('Pending', 'Running', 'Suspended')
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
          System.debug(LoggingLevel.WARN, 'Failed to parse cancel payload, using default runCompensations: ' + e.getMessage());
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
            System.debug(LoggingLevel.WARN, 'Queueable enqueue failed, falling back to Platform Event: ' + ex.getMessage());
            enqueueOrchestrator(instance.Id, null);
          }
        }
      }
    }
  }

  /**
   * Sends external signals to multiple workflow instances in bulk.
   */
  public static void signal(List<SignalRequest> requests) {
    if (requests == null || requests.isEmpty()) {
      return;
    }

    String wflowPrefix = Workflow_Instance__c.SObjectType.getDescribe().getKeyPrefix();
    Pattern idPattern = Pattern.compile('^[a-zA-Z0-9]{15}([a-zA-Z0-9]{3})?$');
    Set<Id> ids = new Set<Id>();
    Set<String> keys = new Set<String>();

    for (SignalRequest req : requests) {
      if (String.isNotBlank(req.keyOrId)) {
        if (idPattern.matcher(req.keyOrId).matches() && req.keyOrId.startsWith(wflowPrefix)) {
          ids.add((Id) req.keyOrId);
        } else {
          keys.add(req.keyOrId);
        }
      }
    }

    List<Workflow_Instance__c> instances = [
      SELECT
        Id,
        Status__c,
        Correlation_Key__c,
        Current_Step__c,
        Compensation_Stack__c
      FROM Workflow_Instance__c
      WHERE
        (Id IN :ids
        OR Correlation_Key__c IN :keys)
        AND Status__c IN ('Pending', 'Running', 'Suspended')
      WITH SYSTEM_MODE
      FOR UPDATE
    ];

    Map<String, Workflow_Instance__c> instById = new Map<String, Workflow_Instance__c>();
    Map<String, Workflow_Instance__c> instByKey = new Map<String, Workflow_Instance__c>();
    for (Workflow_Instance__c inst : instances) {
      instById.put(inst.Id, inst);
      String idStr = String.valueOf(inst.Id);
      if (idStr.length() == 18) {
        instById.put(idStr.substring(0, 15), inst);
      }
      if (String.isNotBlank(inst.Correlation_Key__c)) {
        instByKey.put(inst.Correlation_Key__c, inst);
      }
    }

    // Verify that we found an active instance for every request, or throw
    for (SignalRequest req : requests) {
      Workflow_Instance__c inst = instById.get(req.keyOrId);
      if (inst == null) {
        inst = instByKey.get(req.keyOrId);
      }
      if (inst == null) {
        throw new WorkflowException(
          'No active workflow found with key or ID: ' + req.keyOrId
        );
      }
    }

    List<Workflow_Signal__c> signalsToInsert = new List<Workflow_Signal__c>();
    List<Workflow_Instance__c> instancesToUpdate = new List<Workflow_Instance__c>();
    List<Workflow_Instance__c> activeInstances = new List<Workflow_Instance__c>();

    for (SignalRequest req : requests) {
      Workflow_Instance__c inst = instById.get(req.keyOrId);
      if (inst == null) {
        inst = instByKey.get(req.keyOrId);
      }

      if (inst != null) {
        if (
          req.signalName.equalsIgnoreCase('Cancel') ||
          req.signalName.equalsIgnoreCase('CancelWorkflow')
        ) {
          Boolean runCompensations = true;
          if (String.isNotBlank(req.payload)) {
            try {
              Map<String, Object> params = (Map<String, Object>) JSON.deserializeUntyped(
                req.payload
              );
              if (params.containsKey('runCompensations')) {
                runCompensations = (Boolean) params.get('runCompensations');
              }
            } catch (Exception e) {
              System.debug(LoggingLevel.WARN, 'Failed to deserialize signal cancel payload: ' + e.getMessage());
            }
          }
          cancel(inst.Id, runCompensations);
          continue;
        }

        // Insert the signal record
        Workflow_Signal__c sig = new Workflow_Signal__c();
        sig.Workflow_Instance__c = inst.Id;
        sig.Signal_Name__c = req.signalName;
        sig.Payload__c = req.payload;
        sig.Status__c = 'Received';
        signalsToInsert.add(sig);

        // If the workflow is suspended or running, resume/orchestrate it
        if (inst.Status__c == 'Suspended' || inst.Status__c == 'Running') {
          if (inst.Status__c == 'Suspended') {
            inst.Status__c = 'Running';
            instancesToUpdate.add(inst);
          }
          activeInstances.add(inst);
        }
      }
    }

    if (!signalsToInsert.isEmpty()) {
      insert as system signalsToInsert;
    }
    if (!instancesToUpdate.isEmpty()) {
      update as system instancesToUpdate;
    }

    List<Id> instanceIdsToEnqueue = new List<Id>();
    for (Workflow_Instance__c inst : activeInstances) {
      if (!enqueuedInstanceIds.contains(inst.Id)) {
        enqueuedInstanceIds.add(inst.Id);
        instanceIdsToEnqueue.add(inst.Id);
      }
    }
    enqueueOrchestrators(instanceIdsToEnqueue);
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

    // Reset the failed step's execution status to let it execute again. Bulk-load the
    // latest execution per target step in ONE query (was one SOQL per step in a loop),
    // build a name->latest map, then update the resettable ones together.
    Map<String, Workflow_Step_Execution__c> latestStepByName = new Map<String, Workflow_Step_Execution__c>();
    if (!targetStepNames.isEmpty()) {
      for (Workflow_Step_Execution__c se : [
        SELECT Id, Step_Name__c, Status__c, Retry_Count__c, Error_Details__c
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Step_Name__c IN :targetStepNames
        WITH SYSTEM_MODE
        ORDER BY CreatedDate DESC, Id DESC
      ]) {
        if (!latestStepByName.containsKey(se.Step_Name__c)) {
          latestStepByName.put(se.Step_Name__c, se);
        }
      }
    }

    List<Workflow_Step_Execution__c> stepsToReset = new List<Workflow_Step_Execution__c>();
    for (String targetStepName : targetStepNames) {
      Workflow_Step_Execution__c stepExec = latestStepByName.get(targetStepName);
      if (stepExec != null && stepExec.Status__c != 'Completed') {
        stepExec.Status__c = 'Pending';
        stepExec.Retry_Count__c = 0; // reset retry counter
        stepExec.Error_Details__c = null;
        stepsToReset.add(stepExec);
      }
    }
    if (!stepsToReset.isEmpty()) {
      update as system stepsToReset;
    }

    if (hasCompensations) {
      instance.Status__c = 'Compensating';
    } else {
      instance.Status__c = 'Running';
    }
    instance.Error_Message__c = null;
    update as system instance;

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

    // Parallel forward execution retry: enqueue only incomplete branches. Reuse the
    // already-loaded step map (reset steps are now 'Pending' in memory) instead of
    // re-querying once per branch.
    for (String targetStepName : targetStepNames) {
      Workflow_Step_Execution__c stepExec = latestStepByName.get(targetStepName);
      if (stepExec == null || stepExec.Status__c != 'Completed') {
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
      SELECT
        Id,
        Status__c,
        Compensation_Stack__c,
        Definition_Version__c,
        Workflow_Name__c,
        Input__c
      FROM Workflow_Instance__c
      WHERE Id = :instance.Id
      WITH SYSTEM_MODE
      LIMIT 1
    ];
    if (freshInstances.isEmpty()) {
      throw new WorkflowException(
        'Workflow instance not found: ' + instance.Id
      );
    }
    instance = freshInstances[0];

    // Check early exit conditions for instance status
    if (
      instance.Status__c != 'Compensating' &&
      instance.Status__c != 'Cancelling'
    ) {
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
        : 1,
      new PendingSignalSource(instance.Id)
    );

    // Save/Commit step execution status and set Timeout_At__c before executing compensation so watchdog can detect timeouts
    stepExec.Status__c = 'Running';
    Integer timeoutSeconds = null;
    if (compensatableStepInstance instanceof TimeoutConfigurable) {
      timeoutSeconds = ((TimeoutConfigurable) compensatableStepInstance)
        .getTimeoutSeconds();
    }
    if (timeoutSeconds != null && timeoutSeconds > 0) {
      stepExec.Timeout_At__c = DateTime.now().addSeconds(timeoutSeconds);
      saveStepExec(stepExec);
    } else {
      stepExec.Timeout_At__c = null;
      if (stepExec.Id == null) {
        saveStepExec(stepExec);
      }
    }

    StepResult result;
    try {
      result = compensatableStepInstance.compensate(context);
    } catch (Exception ex) {
      stepExec.Status__c = 'Failed';
      stepExec.Error_Details__c =
        ex.getMessage() +
        '\n' +
        ex.getStackTraceString();
      saveStepExec(stepExec);
      failWorkflowInstance(
        instance.Id,
        compensationStepLogName,
        ex.getMessage()
      );
      return;
    } finally {
      if (timeoutSeconds != null && timeoutSeconds > 0) {
        stepExec.Timeout_At__c = null;
        saveStepExec(stepExec);
        cancelTimeoutJob(instance.Id, compensationStepLogName);
      }
    }

    handleCompensationStepResult(instance, stepExec, result, stack, context);
  }

  private static void handleCompensationStepResult(
    Workflow_Instance__c instance,
    Workflow_Step_Execution__c stepExec,
    StepResult result,
    List<String> stack,
    StepContext context
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

      // A compensating step that read signals durably completed; consume them on
      // the same contract as a forward step so a later compensation attempt or
      // step does not re-observe them. Compensation runs serially (LIFO), so
      // same-name duplicate cleanup is safe.
      markSignalsConsumed(instance.Id, context, false);

      stack.remove(stack.size() - 1);
      instance.Compensation_Stack__c = JSON.serialize(stack);

      if (stack.isEmpty()) {
        instance.Status__c = (instance.Status__c == 'Cancelling')
          ? 'Cancelled'
          : 'Compensated';
        instance.Current_Step__c = null;
      }
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
      if (result.sleepDurationSeconds != null) {
        instance.Sleep_Until__c = DateTime.now()
          .addSeconds(result.sleepDurationSeconds);
        instance.Async_Job_Id__c = scheduleSleepResume(instance.Id, result.sleepDurationSeconds);
      }
      update as system instance;
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
        instance.Status__c = 'Suspended';
        instance.Sleep_Until__c = DateTime.now().addSeconds(delay);
        instance.Async_Job_Id__c = scheduleRetry(instance.Id, stepExec.Step_Name__c, delay);
        update as system instance;
      }
    } else {
      stepExec.Status__c = 'Failed';
      stepExec.Error_Details__c =
        'Unsupported compensation action: ' +
        (result != null ? result.action : null);
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

  private static void preCreateFirstCompensationStep(
    Workflow_Instance__c instance
  ) {
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
      WHERE
        Workflow_Instance__c = :instance.Id
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
    // Cancel the target instance and its entire active descendant tree. Descendants are
    // gathered iteratively (one set-based query per tree level) rather than via recursive
    // cancel() calls, so deep/wide trees cannot blow the SOQL or stack-depth governor
    // limits through uncontrolled recursion. Parent-before-child ordering is preserved.
    //
    // Note: each node still costs a handful of SOQL/DML in cancelSingleInstance(); a tree
    // with thousands of nodes would need async chunking. That is intentionally out of
    // scope here — the goal is to remove the recursion-driven multiplication.
    // The traversal always yields the target first, so it is cancelled with the original
    // not-found semantics (throwIfMissing = true); descendants are best-effort.
    for (Id targetId : collectInstanceAndActiveDescendants(instanceId)) {
      cancelSingleInstance(targetId, runCompensations, targetId == instanceId);
    }
  }

  /**
   * Breadth-first collection of an instance plus all of its active descendants using one
   * set-based query per tree level. Returns IDs in parent-before-child order. A `seen`
   * guard makes the traversal safe against accidental parent-reference cycles.
   */
  private static List<Id> collectInstanceAndActiveDescendants(Id rootId) {
    List<Id> ordered = new List<Id>{ rootId };
    Set<Id> seen = new Set<Id>{ rootId };
    List<Id> frontier = new List<Id>{ rootId };
    while (!frontier.isEmpty()) {
      List<Workflow_Instance__c> children = [
        SELECT Id
        FROM Workflow_Instance__c
        WHERE
          Parent_Instance__c IN :frontier
          AND Status__c IN ('Pending', 'Running', 'Suspended', 'Cancelling')
        WITH SYSTEM_MODE
      ];
      List<Id> nextFrontier = new List<Id>();
      for (Workflow_Instance__c child : children) {
        if (!seen.contains(child.Id)) {
          seen.add(child.Id);
          ordered.add(child.Id);
          nextFrontier.add(child.Id);
        }
      }
      frontier = nextFrontier;
    }
    return ordered;
  }

  /**
   * Cancels a single workflow instance (no descendant traversal). When throwIfMissing is
   * true the original not-found exception is preserved for the top-level target.
   */
  private static void cancelSingleInstance(
    Id instanceId,
    Boolean runCompensations,
    Boolean throwIfMissing
  ) {
    List<Workflow_Instance__c> instances = [
      SELECT Id, Status__c, Current_Step__c, Compensation_Stack__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
      WITH SYSTEM_MODE
      LIMIT 1
    ];
    if (instances.isEmpty()) {
      if (throwIfMissing) {
        throw new WorkflowException(
          'Workflow instance not found: ' + instanceId
        );
      }
      return;
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
      SELECT
        Id,
        Status__c,
        Current_Step__c,
        Compensation_Stack__c,
        Error_Message__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
      WITH SYSTEM_MODE
      LIMIT 1
      FOR UPDATE
    ];
    if (instances.isEmpty()) {
      if (throwIfMissing) {
        throw new WorkflowException(
          'Workflow instance not found: ' + instanceId
        );
      }
      return;
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
    // Active child workflows are handled by the caller (cancel()) via iterative
    // descendant traversal, so no recursive child cancellation happens here.
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
        System.debug(LoggingLevel.WARN, 'Failed to abort job ' + triggerJob.Id + ': ' + e.getMessage());
      }
    }
  }

  public static void enqueueOrchestrators(List<Id> instanceIds) {
    WorkflowWatchdog.bootstrap();
    if (Test.isRunningTest()) {
      for (Id instId : instanceIds) {
        try {
          if (Limits.getQueueableJobs() < Limits.getLimitQueueableJobs()) {
            System.enqueueJob(new WorkflowOrchestrator(instId));
          }
        } catch (Exception e) {
          System.debug(LoggingLevel.WARN, 'Failed to enqueue WorkflowOrchestrator for ' + instId + ': ' + e.getMessage());
        }
      }
      return;
    }
    List<Workflow_Event__e> events = new List<Workflow_Event__e>();
    for (Id instId : instanceIds) {
      events.add(
        new Workflow_Event__e(
          Workflow_Instance_Id__c = instId,
          Event_Type__c = 'RUN_STEP',
          Payload__c = null
        )
      );
    }
    if (!events.isEmpty()) {
      List<Database.SaveResult> srs = EventBus.publish(events);
      for (Database.SaveResult sr : srs) {
        if (!sr.isSuccess()) {
          List<String> errMsgs = new List<String>();
          for (Database.Error err : sr.getErrors()) {
            errMsgs.add(err.getStatusCode() + ': ' + err.getMessage());
          }
          throw new WorkflowException(
            'Failed to publish orchestrator event: ' +
            String.join(errMsgs, ', ')
          );
        }
      }
    }
  }

  public static void enqueueOrchestrator(Id instanceId, String stepName) {
    WorkflowWatchdog.bootstrap();
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
        System.debug(LoggingLevel.WARN, 'Failed to resolve offloaded payload, falling back to raw value: ' + ex.getMessage());
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
        System.debug(LoggingLevel.FINE, 'ContentDocumentLink insert failed with default visibility, retrying with AllUsers: ' + ex.getMessage());
        cdl.Visibility = 'AllUsers';
        insert as system cdl;
      }

      return JSON.serialize(
        new Map<String, String>{ '$attachmentId' => docId }
      );
    }
    return textValue;
  }

  /**
   * Evaluates and resumes suspended workflows that have exceeded their sleep time,
   * and terminates active steps that have exceeded their timeout limits.
   */
  public static void processWatchdogHeartbeat() {
    Datetime now = System.now();

    // 1. Process Timed-out Steps
    List<Workflow_Step_Execution__c> timedOutSteps = [
      SELECT Id, Workflow_Instance__c, Step_Name__c, Status__c, Error_Details__c
      FROM Workflow_Step_Execution__c
      WHERE Status__c IN ('Running', 'Pending') AND Timeout_At__c <= :now
      WITH SYSTEM_MODE
      ORDER BY CreatedDate ASC, Id ASC
      LIMIT :WATCHDOG_TIMEOUT_BATCH_SIZE
    ];

    if (!timedOutSteps.isEmpty()) {
      Set<Id> stepIds = new Set<Id>();
      Set<Id> instanceIds = new Set<Id>();
      for (Workflow_Step_Execution__c step : timedOutSteps) {
        stepIds.add(step.Id);
        instanceIds.add(step.Workflow_Instance__c);
      }

      // Lock parent instances
      Map<Id, Workflow_Instance__c> parents = new Map<Id, Workflow_Instance__c>([
        SELECT Id, Name, Status__c, Current_Step__c, Compensation_Stack__c, Error_Message__c, Workflow_Name__c, Correlation_Key__c
        FROM Workflow_Instance__c
        WHERE Id IN :instanceIds
        WITH SYSTEM_MODE
        FOR UPDATE
      ]);

      // Lock step executions
      Map<Id, Workflow_Step_Execution__c> lockedSteps = new Map<Id, Workflow_Step_Execution__c>([
        SELECT Id, Status__c, Error_Details__c, Timeout_At__c, Step_Name__c, Workflow_Instance__c
        FROM Workflow_Step_Execution__c
        WHERE Id IN :stepIds
        WITH SYSTEM_MODE
        FOR UPDATE
      ]);

      List<Workflow_Step_Execution__c> stepsToUpdate = new List<Workflow_Step_Execution__c>();
      Map<Id, Workflow_Instance__c> instancesToUpdate = new Map<Id, Workflow_Instance__c>();
      List<Workflow_Step_Execution__c> compensationStepsToInsert = new List<Workflow_Step_Execution__c>();
      List<Id> orchestratorInstanceIds = new List<Id>();

      Set<Id> instancesNeedingCompensationInfo = new Set<Id>();
      Set<String> activeStepNamesForComp = new Set<String>();

      for (Workflow_Step_Execution__c step : timedOutSteps) {
        Workflow_Instance__c parent = parents.get(step.Workflow_Instance__c);
        if (parent == null) {
          continue;
        }
        if (
          parent.Status__c != 'Pending' &&
          parent.Status__c != 'Running' &&
          parent.Status__c != 'Compensating' &&
          parent.Status__c != 'Cancelling'
        ) {
          continue;
        }

        Workflow_Step_Execution__c lockedStep = lockedSteps.get(step.Id);
        if (lockedStep == null) {
          continue;
        }
        if (
          lockedStep.Status__c != 'Running' &&
          lockedStep.Status__c != 'Pending'
        ) {
          continue;
        }

        String errorMsg = (lockedStep.Status__c == 'Running')
          ? 'Step execution timed out.'
          : 'Step execution timed out before starting.';

        lockedStep.Status__c = 'Failed';
        lockedStep.Error_Details__c = errorMsg;
        lockedStep.Timeout_At__c = null;
        stepsToUpdate.add(lockedStep);

        if (!instancesToUpdate.containsKey(parent.Id)) {
          // Check if there are compensations to run
          Boolean hasCompensations = false;
          List<String> stack = new List<String>();
          if (String.isNotBlank(parent.Compensation_Stack__c)) {
            stack = (List<String>) JSON.deserialize(
              parent.Compensation_Stack__c,
              List<String>.class
            );
            hasCompensations = !stack.isEmpty();
          }

          Boolean isCompensationFailure = (parent.Status__c == 'Compensating' ||
            parent.Status__c == 'Cancelling' ||
            (String.isNotBlank(step.Step_Name__c) && step.Step_Name__c.endsWith('_Compensate')));

          if (!hasCompensations || isCompensationFailure) {
            parent.Status__c = 'Failed';
            parent.Error_Message__c = 'Failed at step ' + step.Step_Name__c + ': ' + errorMsg;
            instancesToUpdate.put(parent.Id, parent);
          } else {
            parent.Status__c = 'Compensating';
            parent.Error_Message__c = 'Failed at step ' + step.Step_Name__c + ': ' + errorMsg;
            instancesToUpdate.put(parent.Id, parent);

            instancesNeedingCompensationInfo.add(parent.Id);
            if (!stack.isEmpty()) {
              activeStepNamesForComp.add(stack[stack.size() - 1]);
            }
          }
        }
      }

      Map<String, Workflow_Step_Execution__c> existingCompSteps = new Map<String, Workflow_Step_Execution__c>();
      Map<String, Workflow_Step_Execution__c> originalStepsMap = new Map<String, Workflow_Step_Execution__c>();

      if (!instancesNeedingCompensationInfo.isEmpty()) {
        List<Workflow_Step_Execution__c> existing = [
          SELECT Id, Workflow_Instance__c, Step_Name__c
          FROM Workflow_Step_Execution__c
          WHERE Workflow_Instance__c IN :instancesNeedingCompensationInfo
            AND Step_Name__c LIKE '%\_Compensate'
          WITH SYSTEM_MODE
        ];
        for (Workflow_Step_Execution__c e : existing) {
          existingCompSteps.put(e.Workflow_Instance__c + ':' + e.Step_Name__c, e);
        }

        List<Workflow_Step_Execution__c> originalExecs = [
          SELECT Workflow_Instance__c, Step_Name__c, Input__c, Output__c
          FROM Workflow_Step_Execution__c
          WHERE Workflow_Instance__c IN :instancesNeedingCompensationInfo
            AND Step_Name__c IN :activeStepNamesForComp
          WITH SYSTEM_MODE
          ORDER BY CreatedDate DESC, Id DESC
        ];
        for (Workflow_Step_Execution__c o : originalExecs) {
          String key = o.Workflow_Instance__c + ':' + o.Step_Name__c;
          if (!originalStepsMap.containsKey(key)) {
            originalStepsMap.put(key, o);
          }
        }
      }

      for (Id instId : instancesNeedingCompensationInfo) {
        Workflow_Instance__c parent = parents.get(instId);
        List<String> stack = (List<String>) JSON.deserialize(
          parent.Compensation_Stack__c,
          List<String>.class
        );
        String activeStepName = stack[stack.size() - 1];
        String compensationStepLogName = activeStepName + '_Compensate';

        if (existingCompSteps.containsKey(parent.Id + ':' + compensationStepLogName)) {
          continue;
        }

        Workflow_Step_Execution__c orig = originalStepsMap.get(parent.Id + ':' + activeStepName);

        Workflow_Step_Execution__c compStepExec = new Workflow_Step_Execution__c();
        compStepExec.Workflow_Instance__c = parent.Id;
        compStepExec.Step_Name__c = compensationStepLogName;
        compStepExec.Status__c = 'Pending';
        compStepExec.Input__c = (orig != null) ? orig.Input__c : null;
        compStepExec.Output__c = (orig != null) ? orig.Output__c : null;
        compStepExec.Retry_Count__c = 0;
        compensationStepsToInsert.add(compStepExec);
        orchestratorInstanceIds.add(parent.Id);
      }

      if (!stepsToUpdate.isEmpty()) {
        update as system stepsToUpdate;
      }
      if (!compensationStepsToInsert.isEmpty()) {
        insert as system compensationStepsToInsert;
      }
      if (!instancesToUpdate.isEmpty()) {
        update as system instancesToUpdate.values();
      }

      for (Workflow_Instance__c parent : instancesToUpdate.values()) {
        WorkflowAlertManager.sendAlert(parent, parent.Error_Message__c);
      }

      if (!orchestratorInstanceIds.isEmpty()) {
        if (Test.isRunningTest() && disableQueueableInTest) {
          // Do nothing
        } else {
          enqueueOrchestrators(orchestratorInstanceIds);
        }
      }
    }

    // 2. Process Sleep Resumptions (bounded per heartbeat; backlog drains on subsequent
    // heartbeats so an unbounded suspended-instance backlog cannot blow row/heap limits).
    List<Workflow_Instance__c> readyToResume = [
      SELECT Id, Status__c, Sleep_Until__c, Async_Job_Id__c, Error_Message__c
      FROM Workflow_Instance__c
      WHERE Status__c = 'Suspended' AND Sleep_Until__c <= :now
      WITH SYSTEM_MODE
      LIMIT :WATCHDOG_RESUME_BATCH_SIZE
      FOR UPDATE
    ];

    if (!readyToResume.isEmpty()) {
      Set<Id> resumeIds = new Set<Id>();
      for (Workflow_Instance__c inst : readyToResume) {
        resumeIds.add(inst.Id);
      }

      List<Workflow_Step_Execution__c> latestSteps = [
        SELECT Workflow_Instance__c, Step_Name__c
        FROM Workflow_Step_Execution__c
        WHERE Workflow_Instance__c IN :resumeIds
        WITH SYSTEM_MODE
        ORDER BY CreatedDate DESC, Id DESC
      ];

      Map<Id, Workflow_Step_Execution__c> latestStepByInstId = new Map<Id, Workflow_Step_Execution__c>();
      for (Workflow_Step_Execution__c step : latestSteps) {
        if (!latestStepByInstId.containsKey(step.Workflow_Instance__c)) {
          latestStepByInstId.put(step.Workflow_Instance__c, step);
        }
      }

      List<Id> instanceIds = new List<Id>();
      for (Workflow_Instance__c inst : readyToResume) {
        Workflow_Step_Execution__c latestStep = latestStepByInstId.get(inst.Id);
        if (
          latestStep != null &&
          latestStep.Step_Name__c != null &&
          latestStep.Step_Name__c.endsWith('_Compensate')
        ) {
          if (
            inst.Error_Message__c != null &&
            inst.Error_Message__c.contains('Cancelled')
          ) {
            inst.Status__c = 'Cancelling';
          } else {
            inst.Status__c = 'Compensating';
          }
        } else {
          inst.Status__c = 'Running';
        }
        inst.Sleep_Until__c = null;
        inst.Async_Job_Id__c = null;
        instanceIds.add(inst.Id);
      }
      update as system readyToResume;
      enqueueOrchestrators(instanceIds);
    }
  }

  private static Integer getStepTimeoutSeconds(String stepName) {
    if (String.isBlank(stepName)) {
      return null;
    }
    String className = stepName.endsWith('_Compensate')
      ? stepName.substring(0, stepName.lastIndexOf('_Compensate'))
      : stepName;
    try {
      Type stepType = Type.forName(className);
      if (stepType != null) {
        Object stepObj = stepType.newInstance();
        if (stepObj instanceof TimeoutConfigurable) {
          return ((TimeoutConfigurable) stepObj).getTimeoutSeconds();
        }
      }
    } catch (Exception e) {
      System.debug(LoggingLevel.FINE, 'Failed to instantiate type to read timeout duration for step: ' + className + ', error: ' + e.getMessage());
    }
    return null;
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

  public static void scheduleTimeoutJobsForInstances(
    List<Workflow_Instance__c> instances
  ) {
    for (Workflow_Instance__c instance : instances) {
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
              instance.Id,
              stack[stack.size() - 1] + '_Compensate'
            );
          }
        }
      } else if (String.isNotBlank(instance.Current_Step__c)) {
        if (instance.Current_Step__c.contains(',')) {
          for (String pStep : instance.Current_Step__c.split(',')) {
            scheduleTimeoutJobIfNeeded(instance.Id, pStep.trim());
          }
        } else {
          scheduleTimeoutJobIfNeeded(instance.Id, instance.Current_Step__c);
        }
      }
    }
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
    scheduleTimeoutJobsForInstances(new List<Workflow_Instance__c>{ instance });
  }

  public static void scheduleTimeoutJobIfNeeded(
    Id instanceId,
    String stepName
  ) {
    if (String.isBlank(stepName) || !useDynamicScheduling) {
      return;
    }
    try {
      Integer timeoutSeconds = getStepTimeoutSeconds(stepName);
      if (timeoutSeconds != null && timeoutSeconds > 0) {
        if (
          !Test.isRunningTest() &&
          timeoutSeconds >= 60 &&
          timeoutSeconds <= 600 &&
          Math.mod(timeoutSeconds, 60) == 0
        ) {
          if (Limits.getQueueableJobs() < Limits.getLimitQueueableJobs()) {
            System.enqueueJob(
              new WorkflowTimeoutJob.QueueableTimeoutJob(instanceId, stepName),
              timeoutSeconds / 60
            );
            return;
          }
        }
        WorkflowTimeoutJob job = new WorkflowTimeoutJob(instanceId, stepName);
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
        // The job name is deterministic, so a re-schedule (e.g. retry, or a yielded step
        // that re-enters before its prior timeout job fires) collides with the existing
        // scheduled job and System.schedule() throws. Clear any stale job with this name
        // first so the new timeout is actually registered instead of silently dropped.
        cancelTimeoutJob(instanceId, stepName);
        System.schedule(jobName, cronStr, job);
      }
    } catch (AsyncException ex) {
      System.debug(LoggingLevel.INFO, 'Async timeout scheduling limit reached, relying on watchdog: ' + ex.getMessage());
    } catch (Exception ex) {
      System.debug(LoggingLevel.WARN, 'Failed to schedule timeout job: ' + ex.getMessage());
    }
  }

  private static String scheduleRetry(
    Id instanceId,
    String stepName,
    Integer delaySeconds
  ) {
    if (!useDynamicScheduling) {
      return null;
    }
    try {
      if (
        !Test.isRunningTest() &&
        delaySeconds >= 60 &&
        delaySeconds <= 600 &&
        Math.mod(delaySeconds, 60) == 0
      ) {
        if (Limits.getQueueableJobs() < Limits.getLimitQueueableJobs()) {
          return String.valueOf(System.enqueueJob(
            new WorkflowRetryJob.QueueableRetryJob(instanceId, stepName),
            delaySeconds / 60
          ));
        }
      }
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
      return String.valueOf(System.schedule(
        'WorkflowRetry_' + instanceId + '_' + runTime.getTime(),
        cronStr,
        job
      ));
    } catch (AsyncException ex) {
      System.debug(LoggingLevel.INFO, 'Async retry scheduling limit reached, relying on watchdog: ' + ex.getMessage());
      return null;
    } catch (Exception ex) {
      System.debug(LoggingLevel.WARN, 'Failed to schedule retry job: ' + ex.getMessage());
      return null;
    }
  }

  private static String scheduleSleepResume(Id instanceId, Integer delaySeconds) {
    if (!useDynamicScheduling) {
      return null;
    }
    try {
      if (
        !Test.isRunningTest() &&
        delaySeconds >= 60 &&
        delaySeconds <= 600 &&
        Math.mod(delaySeconds, 60) == 0
      ) {
        if (Limits.getQueueableJobs() < Limits.getLimitQueueableJobs()) {
          return String.valueOf(System.enqueueJob(
            new WorkflowSleepJob.QueueableSleepJob(instanceId),
            delaySeconds / 60
          ));
        }
      }
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
      return String.valueOf(System.schedule(
        'WorkflowSleep_' + instanceId + '_' + runTime.getTime(),
        cronStr,
        job
      ));
    } catch (AsyncException ex) {
      System.debug(LoggingLevel.INFO, 'Async sleep scheduling limit reached, relying on watchdog: ' + ex.getMessage());
      return null;
    } catch (Exception ex) {
      System.debug(LoggingLevel.WARN, 'Failed to schedule sleep job: ' + ex.getMessage());
      return null;
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
        System.debug(LoggingLevel.WARN, 'Failed to cancel timeout job ' + triggerJob.Id + ': ' + e.getMessage());
      }
    }
  }
}
