/**
 * @description Instance and search-attribute builder for the workflow start
 * subsystem. Constructs the unsaved `Workflow_Instance__c` for a start request
 * (resolving the definition version, initial step and execution deadline),
 * authorizes the workflow name against `ApexTypeImplementor`, and builds the
 * `Workflow_Search_Attribute__c` records. Extracted from `WorkflowStartService`
 * as the non-invariant building seam shared by the scalar admission path
 * ({@link WorkflowStartService}) and the bulk pipeline ({@link
 * WorkflowBulkStartService}). All SOQL runs in system mode.
 */
public inherited sharing class WorkflowStartInstanceBuilder {
  /**
   * @description Memoized workflow-name authorization cache (name lowercased ->
   * validated). Shared with {@link WorkflowStartValidation}, which pre-populates
   * it in bulk; both the scalar and bulk name-authorization paths consult one
   * cache so a name is authorized against `ApexTypeImplementor` at most once.
   */
  public static Map<String, Boolean> validatedWorkflows = new Map<String, Boolean>();

  // Candidate (localName, namespace) pairs used to authorize a workflow name
  // against ApexTypeImplementor with and without its resolved namespace prefix.
  private class WorkflowNameCandidates {
    String localName1;
    String ns1;
    String localName2;
    String ns2;
  }

  /**
   * @description Builds an unsaved Workflow_Instance__c for a start request,
   * resolving the definition version and initial step and authorizing the name.
   * @param req the start request describing the workflow to instantiate
   * @return an unsaved Workflow_Instance__c populated from the request and definition
   */
  public static Workflow_Instance__c buildInstance(
    WorkflowEngine.StartRequest req
  ) {
    Workflow_Instance__c instance = new Workflow_Instance__c();
    Type startWflowType = WorkflowTypeResolver.resolve(
      req.workflowName,
      WorkflowTypeResolver.extractNamespace(req.workflowName)
    );
    instance.Workflow_Name__c = startWflowType != null
      ? String.valueOf(startWflowType)
      : req.workflowName;
    instance.Status__c = 'Pending';
    instance.Correlation_Key__c = req.correlationKey;
    instance.Parent_Instance__c = req.parentInstanceId;
    instance.Causation_Id__c = resolveCausationId(req);

    validateWorkflowAuthorization(req);
    applyDefinitionMetadata(instance, req);
    return instance;
  }

  /**
   * @description Builds the search-attribute records for a freshly-inserted
   * instance from its request attribute map.
   * @param instanceId the inserted instance Id to relate the attributes to
   * @param attributes the search attributes to materialize (may be null/empty)
   * @return the unsaved Workflow_Search_Attribute__c records
   */
  public static List<Workflow_Search_Attribute__c> buildAttributes(
    Id instanceId,
    Map<String, String> attributes
  ) {
    List<Workflow_Search_Attribute__c> records = new List<Workflow_Search_Attribute__c>();
    if (attributes == null || attributes.isEmpty()) {
      return records;
    }
    for (String key : attributes.keySet()) {
      String val = attributes.get(key);
      records.add(
        new Workflow_Search_Attribute__c(
          Workflow_Instance__c = instanceId,
          Key__c = key,
          Value__c = val,
          Key_Value__c = key + '=' + (val == null ? '' : val)
        )
      );
    }
    return records;
  }

  /**
   * Resolves the causation Id for a start request, minting a keyed causation
   * token (with a future validity stamp) when the request carries one.
   * @param req the start request
   * @return the resolved causation Id (parent instance, or a normalized key token)
   */
  private static String resolveCausationId(WorkflowEngine.StartRequest req) {
    if (String.isBlank(req.causationId)) {
      return req.parentInstanceId;
    }
    String finalCausationId = req.causationId;
    if (finalCausationId.startsWith('key:')) {
      Map<String, Object> payload = new Map<String, Object>{
        'k' => finalCausationId.substring(4),
        't' => System.now().getTime() + 1000
      };
      finalCausationId = 'key:' + JSON.serialize(payload);
    }
    return finalCausationId;
  }

  // Authorize the workflow name against ApexTypeImplementor once per name
  // (memoized in validatedWorkflows); throws when no authorized implementor
  // matches either candidate (local or fully-qualified) form.
  private static void validateWorkflowAuthorization(
    WorkflowEngine.StartRequest req
  ) {
    if (String.isBlank(req.workflowName)) {
      return;
    }
    String wflowKey = req.workflowName.toLowerCase();
    if (validatedWorkflows.containsKey(wflowKey)) {
      return;
    }
    WorkflowNameCandidates c = resolveNameCandidates(req.workflowName);
    List<ApexTypeImplementor> queryResults = [
      SELECT ClassName, ClassNamespacePrefix
      FROM ApexTypeImplementor
      WHERE
        ClassName IN (:c.localName1, :c.localName2)
        AND ClassNamespacePrefix IN (:c.ns1, :c.ns2)
        AND InterfaceName IN (
          'WorkflowDefinition',
          'VersionedWorkflow',
          'ErrorRoutingWorkflow'
        )
      WITH SYSTEM_MODE
    ];
    if (!matchesAuthorizedImpl(queryResults, c)) {
      throw new WorkflowEngine.WorkflowException(
        'Unauthorized or invalid workflow definition: ' + req.workflowName
      );
    }
    validatedWorkflows.put(wflowKey, true);
  }

  private static WorkflowNameCandidates resolveNameCandidates(
    String workflowName
  ) {
    WorkflowNameCandidates c = new WorkflowNameCandidates();
    c.localName1 = workflowName;
    c.ns1 = '';
    c.localName2 = workflowName;
    c.ns2 = '';
    Type resolvedWflowType = WorkflowTypeResolver.resolve(
      workflowName,
      WorkflowTypeResolver.extractNamespace(workflowName)
    );
    if (resolvedWflowType != null) {
      String fqName = String.valueOf(resolvedWflowType);
      if (fqName.contains('.')) {
        c.ns1 = fqName.substringBefore('.');
        c.localName1 = fqName.substringAfter('.');
        c.ns2 = '';
        c.localName2 = fqName;
      } else {
        c.localName1 = fqName;
        c.localName2 = fqName;
      }
    }
    return c;
  }

  private static Boolean matchesAuthorizedImpl(
    List<ApexTypeImplementor> queryResults,
    WorkflowNameCandidates c
  ) {
    for (ApexTypeImplementor impl : queryResults) {
      String implNs = String.isBlank(impl.ClassNamespacePrefix)
        ? ''
        : impl.ClassNamespacePrefix;
      if (
        (impl.ClassName.equalsIgnoreCase(c.localName1) &&
        implNs.equalsIgnoreCase(c.ns1)) ||
        (impl.ClassName.equalsIgnoreCase(c.localName2) &&
        implNs.equalsIgnoreCase(c.ns2))
      ) {
        return true;
      }
    }
    return false;
  }

  private static void applyDefinitionMetadata(
    Workflow_Instance__c instance,
    WorkflowEngine.StartRequest req
  ) {
    Type wflowType = WorkflowTypeResolver.resolve(
      req.workflowName,
      WorkflowTypeResolver.extractNamespace(req.workflowName)
    );
    if (wflowType == null) {
      instance.Definition_Version__c = 1;
      return;
    }
    Object defObj = wflowType.newInstance();
    if (defObj instanceof VersionedWorkflow) {
      instance.Definition_Version__c = ((VersionedWorkflow) defObj)
        .getLatestVersion();
    } else {
      instance.Definition_Version__c = 1;
    }
    if (defObj instanceof WorkflowDefinition) {
      instance.Current_Step__c = ((WorkflowDefinition) defObj).getInitialStep();
    }
    if (defObj instanceof ExecutionTimeoutConfigurable) {
      Integer timeoutSecs = ((ExecutionTimeoutConfigurable) defObj)
        .getExecutionTimeoutSeconds();
      if (timeoutSecs != null) {
        instance.Deadline_At__c = DateTime.now().addSeconds(timeoutSecs);
      }
    }
  }
}
