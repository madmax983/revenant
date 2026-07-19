/**
 * @description In-memory start-input validation for the workflow start subsystem.
 * When a start request targets a definition that implements {@link
 * ValidatedWorkflow}, this service checks the start payload against the declared
 * {@link WorkflowInputContract} and reports every missing required field, every
 * wrong-typed field, and a malformed-JSON payload as {@link
 * WorkflowInputFieldError} records. It is invoked BEFORE any insert/enqueue on
 * both the scalar admission path ({@link WorkflowScalarStartService}) and the bulk
 * pipeline ({@link WorkflowBulkStartService}), and by the Flow-facing invocable
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
    List<WorkflowInputFieldError> errors = collectErrors(req);
    if (!errors.isEmpty()) {
      throw buildException(describeErrors(errors), errors);
    }
  }

  /**
   * @description Validates every request in a bulk start before any row is
   * inserted. Because the bulk admission pipeline is all-or-none (a genuine error
   * rolls the whole batch back and leaves no partial writes), an invalid input is
   * a genuine error: this throws a single {@link WorkflowInputException}
   * enumerating every bad field across every offending request (tagged by request
   * index) and no instance is created. Per-row, non-aborting behavior for
   * declarative callers is provided at the Flow-facing invocable, which validates
   * each row and routes only the valid ones to the engine.
   * @param requests the bulk start requests to validate (nulls skipped)
   */
  public static void validateBulk(List<WorkflowEngine.StartRequest> requests) {
    if (requests == null || requests.isEmpty()) {
      return;
    }
    List<String> clauses = new List<String>();
    List<WorkflowInputFieldError> allErrors = new List<WorkflowInputFieldError>();
    for (Integer i = 0; i < requests.size(); i++) {
      List<WorkflowInputFieldError> errors = collectErrors(requests[i]);
      if (!errors.isEmpty()) {
        allErrors.addAll(errors);
        clauses.add('request[' + i + '] ' + describeErrors(errors));
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
   * @description Collects — without throwing — every violation of the target
   * workflow's input contract. Returns an empty list when the workflow does not
   * implement {@link ValidatedWorkflow}, when its contract is empty, or when the
   * payload satisfies the contract. Used by the invocable to build branchable
   * results and by {@link #validate}/{@link #validateBulk} before they throw.
   * @param req the start request whose input to inspect (null yields no errors)
   * @return the complete set of violations (empty when valid or not opted in)
   */
  public static List<WorkflowInputFieldError> collectErrors(
    WorkflowEngine.StartRequest req
  ) {
    List<WorkflowInputFieldError> errors = new List<WorkflowInputFieldError>();
    if (req == null) {
      return errors;
    }
    WorkflowInputContract contract = resolveContract(req.workflowName);
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

  /**
   * @description Renders a list of violations as a single readable sentence, e.g.
   * "Workflow input validation failed: field 'accountId' is required but missing;
   * field 'amount' expected DECIMAL but was String." Used for the exception
   * message and for the invocable's `validationError` output.
   * @param errors the violations to enumerate (must be non-empty)
   * @return a human-readable enumeration of the violations
   */
  public static String describeErrors(List<WorkflowInputFieldError> errors) {
    List<String> clauses = new List<String>();
    for (WorkflowInputFieldError err : errors) {
      clauses.add(err.describe());
    }
    return 'Workflow input validation failed: ' + String.join(clauses, '; ');
  }

  // Resolve the target workflow definition, instantiate it, and return its
  // declared contract when it opts in; null otherwise (not a ValidatedWorkflow,
  // unresolvable, or an empty name). No SOQL/DML.
  private static WorkflowInputContract resolveContract(String workflowName) {
    if (String.isBlank(workflowName)) {
      return null;
    }
    Type resolvedType = WorkflowTypeResolver.resolve(
      workflowName,
      WorkflowTypeResolver.extractNamespace(workflowName)
    );
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
