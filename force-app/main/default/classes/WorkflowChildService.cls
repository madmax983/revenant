/**
 * @description Single child-workflow spawn surface for the Revenant engine. Starts
 * one child workflow under a parent instance with correlation-key idempotency and a
 * DUPLICATE_VALUE concurrency backstop, then applies the operator pause / concurrency
 * gates and enqueues the orchestrator. Also owns `resolveParentNamespace`, the shared
 * parent-namespace lookup used by the bulk path (`WorkflowChildBulkService`).
 * Extracted from `WorkflowEngine`; the resident `WorkflowEngine.WorkflowException`
 * type is referenced fully qualified. All SOQL/DML executes in system mode.
 */
public inherited sharing class WorkflowChildService {
  /**
   * @description Request DTO for starting a single child workflow. Populated
   * field-by-field to avoid a wide constructor.
   */
  public class ChildWorkflowStartRequest {
    public Id parentId;
    public String workflowName;
    public String correlationKey;
    public String inputJson;
  }

  /**
   * @description Starts a single child workflow under a parent instance, resolving
   * correlation-key idempotency before creating the child, its initial step, and
   * finalizing scheduling/enqueue.
   * @param req the child start request
   */
  public static void startChildWorkflow(ChildWorkflowStartRequest req) {
    Id parentId = req.parentId;
    String correlationKey = req.correlationKey;
    String inputJson = req.inputJson;
    WorkflowPayloadOffload.validateCorrelationKey(correlationKey);
    if (
      String.isNotBlank(correlationKey) &&
      isChildStartIdempotent(correlationKey, parentId)
    ) {
      return;
    }

    if (String.isBlank(req.workflowName)) {
      throw new WorkflowEngine.WorkflowException('Workflow name is required.');
    }
    String parentNamespace = resolveParentNamespace(parentId);
    Workflow_Instance__c instance = buildChildInstance(req, parentNamespace);

    if (insertChildInstance(instance)) {
      return;
    }

    instance.Input__c = WorkflowPayloadOffload.savePayloadIfNeeded(
      instance.Id,
      inputJson,
      'Input_Child_' + instance.Id
    );
    Database.update(instance, true, AccessLevel.SYSTEM_MODE);

    insertInitialChildStep(instance);

    finalizeChildStart(instance);
  }

  /**
   * Resolves the correlation-key preconditions for starting a child workflow.
   * Returns true when an idempotent re-suspend applies (an active instance under
   * the same parent, or a terminal sibling under the same parent already exists),
   * and throws when the key collides with an active instance under a different
   * parent.
   * @param correlationKey the child's correlation key (assumed not blank)
   * @param parentId the requesting parent instance id
   * @return true when the start should resolve idempotently without creating one
   */
  private static Boolean isChildStartIdempotent(
    String correlationKey,
    Id parentId
  ) {
    // 1. Check for active globally unique key
    List<Workflow_Instance__c> existingActive = [
      SELECT Id, Parent_Instance__c, Status__c
      FROM Workflow_Instance__c
      WHERE Active_Correlation_Key__c = :correlationKey
      WITH SYSTEM_MODE
      LIMIT 1
    ];
    if (!existingActive.isEmpty()) {
      if (existingActive[0].Parent_Instance__c == parentId) {
        return true; // Idempotent re-suspend
      }
      throw new WorkflowEngine.WorkflowException(
        'An active workflow already exists with correlation key: ' +
        correlationKey
      );
    }

    // 2. Check for sibling terminal key under same parent
    List<Workflow_Instance__c> existingSibling = [
      SELECT Id, Parent_Instance__c, Status__c
      FROM Workflow_Instance__c
      WHERE
        Correlation_Key__c = :correlationKey
        AND Parent_Instance__c = :parentId
      WITH SYSTEM_MODE
      LIMIT 1
    ];
    return !existingSibling.isEmpty(); // non-empty => idempotent re-suspend
  }

  /**
   * Builds (in memory) the child Workflow_Instance__c from the start request and
   * its resolved definition, populating status, correlation/parent linkage,
   * definition version and initial step. Throws when the workflow name cannot be
   * resolved or the class does not implement WorkflowDefinition.
   * @param req the child start request
   * @param parentNamespace the parent's namespace used to resolve the type
   * @return the unsaved child instance
   */
  private static Workflow_Instance__c buildChildInstance(
    ChildWorkflowStartRequest req,
    String parentNamespace
  ) {
    Type wflowType = WorkflowTypeResolver.resolve(
      req.workflowName,
      parentNamespace
    );
    if (wflowType == null) {
      throw new WorkflowEngine.WorkflowException(
        'Workflow definition not found for name: ' + req.workflowName
      );
    }
    Workflow_Instance__c instance = new Workflow_Instance__c();
    instance.Workflow_Name__c = String.valueOf(wflowType);
    instance.Status__c = 'Pending';
    instance.Correlation_Key__c = req.correlationKey;
    instance.Parent_Instance__c = req.parentId;
    instance.Causation_Id__c = req.parentId;
    Object defObj = wflowType.newInstance();
    if (!(defObj instanceof WorkflowDefinition)) {
      throw new WorkflowEngine.WorkflowException(
        'Class ' + req.workflowName + ' must implement WorkflowDefinition'
      );
    }

    if (defObj instanceof VersionedWorkflow) {
      instance.Definition_Version__c = ((VersionedWorkflow) defObj)
        .getLatestVersion();
    } else {
      instance.Definition_Version__c = 1;
    }
    instance.Current_Step__c = ((WorkflowDefinition) defObj).getInitialStep();
    return instance;
  }

  /**
   * Inserts the child instance, handling the DUPLICATE_VALUE concurrency
   * backstop: when a sibling wins the insert race under the same parent the
   * start resolves idempotently, otherwise a collision throws.
   * @param instance the unsaved child instance
   * @return true when a concurrent sibling won the race and the start should
   * resolve idempotently without proceeding
   */
  private static Boolean insertChildInstance(Workflow_Instance__c instance) {
    Id parentId = instance.Parent_Instance__c;
    String correlationKey = instance.Correlation_Key__c;
    try {
      Database.insert(instance, true, AccessLevel.SYSTEM_MODE);
      if (Test.isRunningTest() && parentId != null) {
        WorkflowFaultInjection.registerChildParent(instance.Id, parentId);
      }
    } catch (DmlException ex) {
      if (ex.getDmlStatusCode(0) == 'DUPLICATE_VALUE') {
        // Concurrency backstop: check if the sibling that won the insert race belongs to the same parent.
        List<Workflow_Instance__c> sibling = [
          SELECT Id, Parent_Instance__c
          FROM Workflow_Instance__c
          WHERE Active_Correlation_Key__c = :correlationKey
          WITH SYSTEM_MODE
          LIMIT 1
        ];
        if (!sibling.isEmpty() && sibling[0].Parent_Instance__c == parentId) {
          return true; // Sibling won the insert race, and it belongs to this parent; resolve idempotently.
        }
        throw new WorkflowEngine.WorkflowException(
          'An active workflow already exists with correlation key: ' +
          correlationKey
        );
      }
      throw ex;
    }
    return false;
  }

  /**
   * Inserts the child's initial Pending step execution, mirroring the instance's
   * initial step and input.
   * @param instance the persisted child instance
   */
  private static void insertInitialChildStep(Workflow_Instance__c instance) {
    if (String.isNotBlank(instance.Current_Step__c)) {
      Workflow_Step_Execution__c stepExec = new Workflow_Step_Execution__c();
      stepExec.Workflow_Instance__c = instance.Id;
      stepExec.Step_Name__c = instance.Current_Step__c;
      stepExec.Status__c = 'Pending';
      stepExec.Input__c = instance.Input__c;
      stepExec.Retry_Count__c = 0;
      Database.insert(stepExec, true, AccessLevel.SYSTEM_MODE);
    }
  }

  /**
   * Finalizes a freshly-persisted child instance: applies the operator pause
   * gate, schedules (or defers) the initial-step watchdog, and enqueues the
   * orchestrator when not running under test.
   * @param instance the persisted child instance to finalize
   */
  private static void finalizeChildStart(Workflow_Instance__c instance) {
    // Operator pause gate — park the child at start if its definition is paused, so a
    // running parent cannot bypass the pause by spawning children. The initial Pending
    // step (above) gives resume a concrete step to drive; skip timeout scheduling and
    // the enqueue. The child's correlation reservation still holds (the trigger keeps
    // Active_Correlation_Key__c set for Paused).
    if (
      WorkflowPauseGate.anyPaused() &&
      WorkflowPauseGate.isDefinitionPaused(instance.Workflow_Name__c)
    ) {
      instance.Status__c = 'Paused';
      Database.update(instance, true, AccessLevel.SYSTEM_MODE);
      return;
    }

    // Schedule the watchdog for the child's initial step before executing it, matching
    // the start() overloads. Without this a TimeoutConfigurable first step of a child
    // workflow would never get a scheduled timeout job. A concurrency-bounded child
    // defers this until its first RUN_STEP wins an admission slot (mirrors doStart):
    // a parked sibling could take the freed slot before this child reaches the gate,
    // so an armed timeout could fail it while it is only waiting for capacity.
    if (!ConcurrencyGate.isConfigured(instance.Workflow_Name__c)) {
      WorkflowTimeoutArming.scheduleTimeoutJobForInstance(instance.Id);
    } else {
      // Durable awaiting-admission marker (see doStart): the pre-start watchdog keys
      // its null-deadline skip off this, not the live CMDT, so a ceiling added later
      // cannot silence a genuine unbounded pre-start watchdog. Cleared on admission.
      instance.Concurrency_Parked__c = true;
      Database.update(instance, true, AccessLevel.SYSTEM_MODE);
    }

    if (!Test.isRunningTest()) {
      WorkflowOrchestratorEnqueue.enqueueOrchestrator(instance.Id, null);
    }
  }

  /**
   * @description Resolves the namespace of a parent instance from its workflow
   * name, used to resolve child workflow types relative to the parent. Public so
   * the bulk spawn path (`WorkflowChildBulkService`) shares the same lookup.
   * @param parentId the parent instance id (may be null)
   * @return the parent's namespace, or an empty string when unresolved
   */
  public static String resolveParentNamespace(Id parentId) {
    if (parentId == null) {
      return '';
    }
    List<Workflow_Instance__c> parentInsts = [
      SELECT Workflow_Name__c
      FROM Workflow_Instance__c
      WHERE Id = :parentId
      WITH SYSTEM_MODE
      LIMIT 1
    ];
    if (parentInsts.isEmpty()) {
      return '';
    }
    return WorkflowTypeResolver.extractNamespace(
      parentInsts[0].Workflow_Name__c
    );
  }
}
