/**
 * @description Bulk child-workflow planning surface for the Revenant engine. Owns the
 * "decide which children to create and insert them" half of the bulk-start flow:
 * validates child requests, indexes already-existing correlated children, builds the
 * unsaved child instances, and bulk-inserts them with a DUPLICATE_VALUE reconciliation
 * backstop. Called by `WorkflowChildBulkService`. Extracted from `WorkflowEngine`; the
 * resident `WorkflowEngine.WorkflowException` type and `WorkflowEngine.normalizeKey`
 * helper are referenced fully qualified. All SOQL/DML executes in system mode.
 */
public inherited sharing class WorkflowChildBulkPlanner {
  /**
   * @description Validates each child request (correlation key, workflow name, and
   * that the resolved type implements WorkflowDefinition) and collects the requested
   * correlation keys.
   * @param requests the child requests to validate
   * @param parentNamespace the parent's namespace used to resolve child types
   * @return the set of requested correlation keys
   */
  public static Set<String> validateChildRequests(
    List<StepResult.ChildRequest> requests,
    String parentNamespace
  ) {
    Set<String> correlationKeys = new Set<String>();
    for (StepResult.ChildRequest req : requests) {
      WorkflowPayloadOffload.validateCorrelationKey(req.correlationKey);
      correlationKeys.add(req.correlationKey);

      if (String.isBlank(req.workflowName)) {
        throw new WorkflowEngine.WorkflowException(
          'Workflow name is required.'
        );
      }
      Type wflowType = WorkflowTypeResolver.resolve(
        req.workflowName,
        parentNamespace
      );
      if (wflowType == null) {
        throw new WorkflowEngine.WorkflowException(
          'Workflow definition not found for name: ' + req.workflowName
        );
      }
      Object defObj = wflowType.newInstance();
      if (!(defObj instanceof WorkflowDefinition)) {
        throw new WorkflowEngine.WorkflowException(
          'Class ' + req.workflowName + ' must implement WorkflowDefinition'
        );
      }
    }
    return correlationKeys;
  }

  /**
   * @description Indexes the children that already exist for the given parent and
   * correlation keys (active globally-unique keys and terminal siblings under this
   * parent), keyed by normalized correlation key. Throws when an active key belongs
   * to a different parent.
   * @param parentId the requesting parent instance id
   * @param correlationKeys the correlation keys to look up
   * @return a map of normalized correlation key to the existing child instance
   */
  public static Map<String, Workflow_Instance__c> findExistingChildren(
    Id parentId,
    Set<String> correlationKeys
  ) {
    Map<String, Workflow_Instance__c> existingByCorrKey = new Map<String, Workflow_Instance__c>();
    if (correlationKeys.isEmpty()) {
      return existingByCorrKey;
    }

    List<Workflow_Instance__c> existingActive = [
      SELECT Id, Parent_Instance__c, Status__c, Active_Correlation_Key__c
      FROM Workflow_Instance__c
      WHERE Active_Correlation_Key__c IN :correlationKeys
      WITH SYSTEM_MODE
    ];
    for (Workflow_Instance__c existing : existingActive) {
      if (existing.Parent_Instance__c == parentId) {
        existingByCorrKey.put(
          WorkflowEngine.normalizeKey(existing.Active_Correlation_Key__c),
          existing
        );
      } else {
        throw new WorkflowEngine.WorkflowException(
          'An active workflow already exists with correlation key: ' +
          existing.Active_Correlation_Key__c
        );
      }
    }

    List<Workflow_Instance__c> existingSiblings = [
      SELECT Id, Parent_Instance__c, Status__c, Correlation_Key__c
      FROM Workflow_Instance__c
      WHERE
        Correlation_Key__c IN :correlationKeys
        AND Parent_Instance__c = :parentId
      WITH SYSTEM_MODE
    ];
    for (Workflow_Instance__c existing : existingSiblings) {
      existingByCorrKey.put(
        WorkflowEngine.normalizeKey(existing.Correlation_Key__c),
        existing
      );
    }
    return existingByCorrKey;
  }

  /**
   * @description Builds (in memory) a child Workflow_Instance__c from a bulk child
   * request and its resolved definition, populating status, correlation/parent
   * linkage, definition version and initial step.
   * @param req the bulk child request
   * @param parentId the requesting parent instance id
   * @param parentNamespace the parent's namespace used to resolve the type
   * @return the unsaved child instance
   */
  public static Workflow_Instance__c buildChildInstance(
    StepResult.ChildRequest req,
    Id parentId,
    String parentNamespace
  ) {
    Type wflowType = WorkflowTypeResolver.resolve(
      req.workflowName,
      parentNamespace
    );
    Workflow_Instance__c instance = new Workflow_Instance__c();
    // wflowType is guaranteed non-null by the validation loop above
    instance.Workflow_Name__c = String.valueOf(wflowType);
    instance.Status__c = 'Pending';
    instance.Correlation_Key__c = req.correlationKey;
    instance.Parent_Instance__c = parentId;
    instance.Causation_Id__c = parentId;
    Object defObj = wflowType.newInstance();
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
   * @description Bulk-inserts the child instances, returning true when processing
   * should continue and false when a DUPLICATE_VALUE race was reconciled against
   * existing siblings (the original early return).
   * @param instancesToInsert the unsaved child instances
   * @param parentId the requesting parent instance id
   * @return true to continue processing; false when a duplicate race was reconciled
   */
  public static Boolean insertChildInstances(
    List<Workflow_Instance__c> instancesToInsert,
    Id parentId
  ) {
    try {
      Database.insert(instancesToInsert, true, AccessLevel.SYSTEM_MODE);
      if (Test.isRunningTest()) {
        for (Workflow_Instance__c inst : instancesToInsert) {
          WorkflowFaultInjection.registerChildParent(inst.Id, parentId);
        }
      }
      return true;
    } catch (DmlException ex) {
      if (ex.getDmlStatusCode(0) == 'DUPLICATE_VALUE') {
        reconcileDuplicateChildren(instancesToInsert, parentId);
        return false;
      }
      throw ex;
    }
  }

  private static Set<String> collectChildCorrelationKeys(
    List<Workflow_Instance__c> instances
  ) {
    Set<String> corrKeys = new Set<String>();
    for (Workflow_Instance__c inst : instances) {
      if (String.isNotBlank(inst.Correlation_Key__c)) {
        corrKeys.add(WorkflowEngine.normalizeKey(inst.Correlation_Key__c));
      }
    }
    return corrKeys;
  }

  // Re-verifies that each duplicate-keyed child already exists as a sibling of
  // this parent; throws only for a correlation-key collision with a foreign
  // instance. Mirrors the original in-catch reconciliation exactly.
  private static void reconcileDuplicateChildren(
    List<Workflow_Instance__c> instancesToInsert,
    Id parentId
  ) {
    Set<String> corrKeys = collectChildCorrelationKeys(instancesToInsert);
    Map<String, Workflow_Instance__c> siblingsMap = new Map<String, Workflow_Instance__c>();
    if (!corrKeys.isEmpty()) {
      for (Workflow_Instance__c sibling : [
        SELECT Id, Parent_Instance__c, Active_Correlation_Key__c
        FROM Workflow_Instance__c
        WHERE Active_Correlation_Key__c IN :corrKeys
        WITH SYSTEM_MODE
      ]) {
        siblingsMap.put(
          WorkflowEngine.normalizeKey(sibling.Active_Correlation_Key__c),
          sibling
        );
      }
    }
    for (Workflow_Instance__c inst : instancesToInsert) {
      if (String.isNotBlank(inst.Correlation_Key__c)) {
        Workflow_Instance__c sibling = siblingsMap.get(
          WorkflowEngine.normalizeKey(inst.Correlation_Key__c)
        );
        if (sibling == null || sibling.Parent_Instance__c != parentId) {
          throw new WorkflowEngine.WorkflowException(
            'An active workflow already exists with correlation key: ' +
            inst.Correlation_Key__c
          );
        }
      }
    }
  }
}
