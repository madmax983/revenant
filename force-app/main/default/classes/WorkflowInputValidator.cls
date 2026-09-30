/**
 * @description In-memory start-input validation for the workflow start subsystem.
 * When a start request targets a definition that implements {@link
 * ValidatedWorkflow}, this service checks the start payload against the declared
 * {@link WorkflowInputContract} and reports every missing required field, every
 * wrong-typed field, and a malformed-JSON payload as {@link
 * WorkflowInputFieldError} records. It is invoked BEFORE any insert/enqueue on
 * both the scalar admission path ({@link WorkflowScalarStartService}) and the bulk
 * pipeline ({@link WorkflowBulkStartService}), by the internal child-start and
 * continue-as-new paths (issue #227), and by the Flow-facing invocable
 * ({@link WorkflowStartInvocableAction}) to build branchable results. Payload
 * normalization is delegated to {@link WorkflowInputPayloadParser} and primitive
 * type-matching to {@link WorkflowInputTypeChecker}.
 *
 * Cost contract: opt-in detection is a single `instanceof` on the resolved
 * definition instance, and all checking is pure in-memory parsing. This service
 * issues ZERO SOQL and ZERO DML — it resolves the definition Type through the
 * cached {@link WorkflowTypeResolver} and instantiates it with `newInstance()`
 * (the same instantiation the start path already performs), never touching the
 * database. A non-`ValidatedWorkflow` definition (or an unresolvable name) yields
 * no errors, so validation is fully backward compatible and never masks the
 * engine's own authorization error for a bad name.
 */
public inherited sharing class WorkflowInputValidator {
  /**
   * @description Validates one start request and throws when the payload violates
   * the target workflow's contract. A no-op when the workflow does not implement
   * {@link ValidatedWorkflow} or declares an empty contract.
   * @param req the start request whose input to validate (null is a no-op)
   */
  public static void validate(WorkflowEngine.StartRequest req) {
    if (req == null) {
      return;
    }
    throwIfAny(collectErrors(req));
  }

  // Throws WorkflowInputException if the list has an error.
  private static void throwIfAny(List<WorkflowInputFieldError> errors) {
    if (!errors.isEmpty()) {
      throw buildException(describeErrors(errors), errors);
    }
  }

  /**
   * @description Validates ONLY the bulk requests that will create a new instance,
   * identified by their original index in `requests`. The bulk pipeline calls this
   * AFTER the resolve-existing/dedup decision has determined which rows are fresh
   * starts and BEFORE those rows are inserted — so a request that deduped to an
   * existing instance (a get-or-start or signal-or-start hit) is never validated,
   * because its fallback start input is never persisted. Because the bulk admission
   * pipeline is all-or-none (a genuine error rolls the whole batch back and leaves
   * no partial writes), an invalid fresh-start input is a genuine error: this
   * throws a single {@link WorkflowInputException} enumerating every bad field
   * across every offending new-start request (tagged by original request index)
   * and no instance is created. Per-row, non-aborting behavior for declarative
   * callers is provided at the Flow-facing invocable.
   * @param requests the full bulk request list (indexed by newStartIndexes)
   * @param newStartIndexes original indices of the requests that will be inserted
   *   as new instances (the fresh-start subset)
   */
  public static void validateNewStarts(
    List<WorkflowEngine.StartRequest> requests,
    List<Integer> newStartIndexes
  ) {
    if (
      requests == null ||
      newStartIndexes == null ||
      newStartIndexes.isEmpty()
    ) {
      return;
    }
    List<String> clauses = new List<String>();
    List<WorkflowInputFieldError> allErrors = new List<WorkflowInputFieldError>();
    for (Integer idx : newStartIndexes) {
      List<WorkflowInputFieldError> errors = collectErrors(requests[idx]);
      if (!errors.isEmpty()) {
        allErrors.addAll(errors);
        clauses.add('request[' + idx + '] ' + describeErrors(errors));
      }
    }
    if (!allErrors.isEmpty()) {
      throw buildException(
        'Workflow input validation failed for ' +
          clauses.size() +
          ' request(s): ' +
          String.join(clauses, '; '),
        allErrors
      );
    }
  }

  /**
   * @description Validates the input of one child start. Call it after the
   * dedup check and before the child insert. A no-op when the child class has
   * no contract. The method uses the parent namespace to find the type, as the
   * child builder does.
   * @param workflowName the child workflow name
   * @param parentNamespace the parent namespace that resolves the type
   * @param inputJson the child input JSON that the engine will persist
   */
  public static void validateChildStart(
    String workflowName,
    String parentNamespace,
    String inputJson
  ) {
    throwIfAny(
      collectErrors(
        resolveContract(workflowName, parentNamespace),
        inputOnly(inputJson)
      )
    );
  }

  /**
   * @description Validates the inputs of the fresh children of a bulk start.
   * Call it after the dedup check and before the insert. It throws one
   * exception that lists each bad child by correlation key, so no child is
   * created.
   * @param requests the child requests that will create new instances
   * @param parentNamespace the parent namespace that resolves the types
   */
  public static void validateChildStarts(
    List<StepResult.ChildRequest> requests,
    String parentNamespace
  ) {
    List<String> clauses = new List<String>();
    List<WorkflowInputFieldError> allErrors = new List<WorkflowInputFieldError>();
    Map<String, WorkflowInputContract> contracts = new Map<String, WorkflowInputContract>();
    for (StepResult.ChildRequest req : requests) {
      if (!contracts.containsKey(req.workflowName)) {
        contracts.put(
          req.workflowName,
          resolveContract(req.workflowName, parentNamespace)
        );
      }
      List<WorkflowInputFieldError> errors = collectErrors(
        contracts.get(req.workflowName),
        inputOnly(req.inputJson)
      );
      if (!errors.isEmpty()) {
        allErrors.addAll(errors);
        clauses.add(
          'child[' +
            (String.isBlank(req.correlationKey)
              ? ''
              : req.correlationKey.abbreviate(80)) +
            '] ' +
            describeClauses(errors)
        );
      }
    }
    if (!allErrors.isEmpty()) {
      throw buildException(
        'Workflow input validation failed for ' +
          clauses.size() +
          ' child request(s): ' +
          String.join(clauses, '; '),
        allErrors
      );
    }
  }

  /**
   * @description Validates the input of a continue-as-new successor. Call it
   * before any write, so a bad input leaves the predecessor unchanged.
   * @param workflowName the workflow name of the predecessor and successor
   * @param nextInputJson the successor input JSON that the engine will persist
   */
  public static void validateContinuation(
    String workflowName,
    String nextInputJson
  ) {
    throwIfAny(
      collectErrors(
        resolveContract(
          workflowName,
          WorkflowTypeResolver.extractNamespace(workflowName)
        ),
        inputOnly(nextInputJson)
      )
    );
  }

  /**
   * @description Collects — without throwing — every violation of the target
   * workflow's input contract. Returns an empty list when the workflow does not
   * implement {@link ValidatedWorkflow}, when its contract is empty, or when the
   * payload satisfies the contract. Used by the invocable to build branchable
   * results and by {@link #validate}/{@link #validateNewStarts} before they throw.
   * @param req the start request whose input to inspect (null yields no errors)
   * @return the complete set of violations (empty when valid or not opted in)
   */
  public static List<WorkflowInputFieldError> collectErrors(
    WorkflowEngine.StartRequest req
  ) {
    if (req == null) {
      return new List<WorkflowInputFieldError>();
    }
    return collectErrors(
      resolveContract(
        req.workflowName,
        WorkflowTypeResolver.extractNamespace(req.workflowName)
      ),
      req
    );
  }

  // Checks one request against a contract. A null or empty contract yields no
  // errors. Malformed JSON stops the per-field checks.
  private static List<WorkflowInputFieldError> collectErrors(
    WorkflowInputContract contract,
    WorkflowEngine.StartRequest req
  ) {
    List<WorkflowInputFieldError> errors = new List<WorkflowInputFieldError>();
    if (contract == null || contract.isEmpty()) {
      return errors;
    }
    Map<String, Object> fieldMap = WorkflowInputPayloadParser.parse(
      req,
      errors
    );
    if (fieldMap == null) {
      // Malformed JSON was recorded; per-field checks cannot run.
      return errors;
    }
    for (WorkflowInputContract.Field spec : contract.getFields()) {
      checkField(spec, fieldMap, errors);
    }
    return errors;
  }

  // Wraps a persisted input JSON as a request. The parser then reads it the
  // same way as the root start paths: a null JSON is an empty payload.
  private static WorkflowEngine.StartRequest inputOnly(String inputJson) {
    WorkflowEngine.StartRequest req = new WorkflowEngine.StartRequest(
      null,
      null,
      null
    );
    req.inputJson = inputJson;
    return req;
  }

  /**
   * @description Renders a list of violations as a single readable sentence, e.g.
   * "Workflow input validation failed: field 'accountId' is required but missing;
   * field 'amount' expected DECIMAL but was String." Used for the exception
   * message and for the invocable's `validationError` output.
   * @param errors the violations to enumerate (must be non-empty)
   * @return a human-readable enumeration of the violations
   */
  public static String describeErrors(List<WorkflowInputFieldError> errors) {
    return 'Workflow input validation failed: ' + describeClauses(errors);
  }

  // Joins the violations into one clause, without the message prefix.
  private static String describeClauses(List<WorkflowInputFieldError> errors) {
    List<String> clauses = new List<String>();
    for (WorkflowInputFieldError err : errors) {
      clauses.add(err.describe());
    }
    return String.join(clauses, '; ');
  }

  // Resolve the target workflow definition, instantiate it, and return its
  // declared contract when it opts in; null otherwise (not a ValidatedWorkflow,
  // unresolvable, or an empty name). No SOQL/DML.
  private static WorkflowInputContract resolveContract(
    String workflowName,
    String namespace
  ) {
    if (String.isBlank(workflowName)) {
      return null;
    }
    Type resolvedType = WorkflowTypeResolver.resolve(workflowName, namespace);
    if (resolvedType == null) {
      return null;
    }
    Object defObj = resolvedType.newInstance();
    if (!(defObj instanceof ValidatedWorkflow)) {
      return null;
    }
    return ((ValidatedWorkflow) defObj).getInputContract();
  }

  // Check one contract field against the parsed payload, appending a MISSING or
  // WRONG_TYPE violation as needed. Presence-and-non-null is required for a
  // required field; a present, non-null value is always type-checked.
  private static void checkField(
    WorkflowInputContract.Field spec,
    Map<String, Object> fieldMap,
    List<WorkflowInputFieldError> errors
  ) {
    Object rawValue = fieldMap.get(spec.name);
    if (rawValue == null) {
      if (spec.required) {
        errors.add(WorkflowInputFieldError.missing(spec.name));
      }
      return;
    }
    if (!WorkflowInputTypeChecker.matches(rawValue, spec.expectedType)) {
      errors.add(
        WorkflowInputFieldError.wrongType(
          spec.name,
          spec.expectedType,
          WorkflowInputTypeChecker.describeActual(rawValue)
        )
      );
    }
  }

  // Build the typed exception with its composed message and structured errors.
  private static WorkflowInputException buildException(
    String message,
    List<WorkflowInputFieldError> errors
  ) {
    WorkflowInputException ex = new WorkflowInputException(message);
    ex.setFieldErrors(errors);
    return ex;
  }
}
