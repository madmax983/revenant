/**
 * @description Validation seam for the workflow start subsystem. Validates
 * per-instance search attributes (count and key/value length limits) for both
 * the scalar admission path ({@link WorkflowStartService}) and the bulk pipeline
 * ({@link WorkflowBulkStartService}), and performs the bulk workflow-name
 * pre-validation that primes the shared authorization cache
 * ({@link WorkflowStartInstanceBuilder}.validatedWorkflows) in a single
 * `ApexTypeImplementor` query. Extracted from `WorkflowStartService` as the
 * non-invariant validation seam. All SOQL runs in system mode.
 */
public inherited sharing class WorkflowStartValidation {
  // Candidate class-name / namespace sets to query for workflow-name validation,
  // plus the raw-spelling back-references keyed by resolved class name.
  private class WorkflowNameQuery {
    Set<String> localNames = new Set<String>();
    Set<String> namespaces = new Set<String>();
    Map<String, List<String>> rawNamesByResolved = new Map<String, List<String>>();
  }

  /**
   * @description Validates a start request's search-attribute map against the
   * per-instance count limit and per-entry key/value limits.
   * @param attributes the search attributes to validate (may be null/empty)
   */
  public static void validateAttributes(Map<String, String> attributes) {
    if (attributes == null || attributes.isEmpty()) {
      return;
    }
    if (attributes.size() > WorkflowEngine.MAX_ATTRIBUTES_PER_INSTANCE) {
      throw new WorkflowEngine.WorkflowException(
        'Attribute count exceeds maximum limit of ' +
        WorkflowEngine.MAX_ATTRIBUTES_PER_INSTANCE
      );
    }
    for (String key : attributes.keySet()) {
      validateAttributeEntry(key, attributes.get(key));
    }
  }

  /**
   * Validates a single search-attribute key/value pair against the key-blankness,
   * key-length, and value-length limits.
   * @param key the attribute key
   * @param val the attribute value (may be null)
   */
  private static void validateAttributeEntry(String key, String val) {
    if (String.isBlank(key)) {
      throw new WorkflowEngine.WorkflowException(
        'Attribute key cannot be blank'
      );
    }
    if (key.length() > WorkflowEngine.MAX_ATTRIBUTE_KEY_LENGTH) {
      throw new WorkflowEngine.WorkflowException(
        'Attribute key length exceeds maximum limit of ' +
          WorkflowEngine.MAX_ATTRIBUTE_KEY_LENGTH +
          ' characters: ' +
          key
      );
    }
    if (
      val != null &&
      val.length() > WorkflowEngine.MAX_ATTRIBUTE_VALUE_LENGTH
    ) {
      throw new WorkflowEngine.WorkflowException(
        'Attribute value length exceeds maximum limit of ' +
          WorkflowEngine.MAX_ATTRIBUTE_VALUE_LENGTH +
          ' characters: ' +
          val
      );
    }
  }

  /**
   * @description §1 of the bulk pipeline: validate each request and gather
   * correlation keys; pre-validate any not-yet-cached workflow names in bulk via
   * `ApexTypeImplementor`.
   * @param requests the bulk start requests to validate
   * @return the set of non-blank correlation keys across the requests
   */
  public static Set<String> validateAndPrevalidateStarts(
    List<WorkflowEngine.StartRequest> requests
  ) {
    Set<String> correlationKeys = new Set<String>();
    Set<String> workflowNamesToQuery = new Set<String>();
    for (WorkflowEngine.StartRequest req : requests) {
      if (req == null) {
        continue;
      }
      WorkflowPayloadOffload.validateCorrelationKey(req.correlationKey);
      validateAttributes(req.attributes);
      if (String.isNotBlank(req.correlationKey)) {
        correlationKeys.add(req.correlationKey);
      }
      if (String.isNotBlank(req.workflowName)) {
        String wflowKey = req.workflowName.toLowerCase();
        if (
          !WorkflowStartInstanceBuilder.validatedWorkflows.containsKey(wflowKey)
        ) {
          workflowNamesToQuery.add(req.workflowName);
        }
      }
    }

    if (!workflowNamesToQuery.isEmpty()) {
      prevalidateWorkflowNames(workflowNamesToQuery);
    }
    return correlationKeys;
  }

  // Query ApexTypeImplementor for the candidate class/namespace pairs and mark
  // the matching workflow names validated (both resolved and raw spellings).
  private static void prevalidateWorkflowNames(
    Set<String> workflowNamesToQuery
  ) {
    WorkflowNameQuery q = buildWorkflowNameQuery(workflowNamesToQuery);
    Set<String> localNamesToQuery = q.localNames;
    Set<String> namespacesToQuery = q.namespaces;

    for (ApexTypeImplementor impl : [
      SELECT ClassName, ClassNamespacePrefix
      FROM ApexTypeImplementor
      WHERE
        ClassName IN :localNamesToQuery
        AND ClassNamespacePrefix IN :namespacesToQuery
        AND InterfaceName IN (
          'WorkflowDefinition',
          'VersionedWorkflow',
          'ErrorRoutingWorkflow'
        )
      WITH SYSTEM_MODE
    ]) {
      String matchName = String.isBlank(impl.ClassNamespacePrefix)
        ? impl.ClassName
        : (impl.ClassNamespacePrefix + '.' + impl.ClassName);
      String matchLower = matchName.toLowerCase();
      WorkflowStartInstanceBuilder.validatedWorkflows.put(matchLower, true);

      if (q.rawNamesByResolved.containsKey(matchLower)) {
        for (String rawName : q.rawNamesByResolved.get(matchLower)) {
          WorkflowStartInstanceBuilder.validatedWorkflows.put(
            rawName.toLowerCase(),
            true
          );
        }
      }
    }
  }

  // Resolve each raw workflow name into the local-name/namespace candidates to
  // query, tracking which raw spellings map to each resolved class.
  private static WorkflowNameQuery buildWorkflowNameQuery(
    Set<String> workflowNamesToQuery
  ) {
    WorkflowNameQuery q = new WorkflowNameQuery();
    for (String rawName : workflowNamesToQuery) {
      Type resolved = WorkflowTypeResolver.resolve(
        rawName,
        WorkflowTypeResolver.extractNamespace(rawName)
      );
      String localName1 = rawName;
      String ns1 = '';
      String localName2 = rawName;
      String ns2 = '';
      if (resolved != null) {
        String fqName = String.valueOf(resolved);
        String resName = fqName.toLowerCase();
        if (!q.rawNamesByResolved.containsKey(resName)) {
          q.rawNamesByResolved.put(resName, new List<String>());
        }
        q.rawNamesByResolved.get(resName).add(rawName);

        if (fqName.contains('.')) {
          ns1 = fqName.substringBefore('.');
          localName1 = fqName.substringAfter('.');
          ns2 = '';
          localName2 = fqName;
        } else {
          localName1 = fqName;
          localName2 = fqName;
        }
      }
      q.localNames.add(localName1);
      q.localNames.add(localName2);
      q.namespaces.add(ns1);
      q.namespaces.add(ns2);
    }
    return q;
  }
}
