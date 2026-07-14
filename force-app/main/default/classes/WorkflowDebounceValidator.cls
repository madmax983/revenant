/**
 * @description Validates and filters incoming debounce start requests before
 * registration: it enforces identity, timing, payload-size, and attributes
 * constraints, and collects the surviving requests together with their derived
 * debounce keys. Extracted from WorkflowDebouncer, which retains the durable
 * upsert/sweep paths and delegates request validation here.
 */
public inherited sharing class WorkflowDebounceValidator {
  /**
   * @description Validates each request and returns the surviving ones, skipping
   * null entries and accumulating the debounce key of every valid request into
   * the supplied set. Throws on the first invalid non-null request.
   * @param requests The debounce requests to validate; null entries are skipped.
   * @param debounceKeys Output set that accumulates the debounce key of each valid request.
   * @return The valid requests, in input order.
   */
  public static List<WorkflowDebouncer.DebounceRequest> collectValidRequests(
    List<WorkflowDebouncer.DebounceRequest> requests,
    Set<String> debounceKeys
  ) {
    List<WorkflowDebouncer.DebounceRequest> validRequests = new List<WorkflowDebouncer.DebounceRequest>();
    for (WorkflowDebouncer.DebounceRequest req : requests) {
      if (req == null) {
        continue;
      }
      validateRequestIdentity(req);
      validateRequestTiming(req);
      validateRequestPayloadSize(req);
      WorkflowDebouncer.validateAttributesJson(req.attributesJson);

      debounceKeys.add(
        WorkflowDebouncer.generateDebounceKey(
          req.workflowName,
          req.correlationKey
        )
      );
      validRequests.add(req);
    }
    return validRequests;
  }

  /**
   * @description Enforces workflow-name and correlation-key presence and the
   * correlation-key length ceiling.
   * @param req The request whose identity fields are validated.
   */
  private static void validateRequestIdentity(
    WorkflowDebouncer.DebounceRequest req
  ) {
    if (String.isBlank(req.workflowName)) {
      throw new WorkflowEngine.WorkflowException('Workflow name is required.');
    }
    if (String.isBlank(req.correlationKey)) {
      throw new WorkflowEngine.WorkflowException(
        'Correlation key is required.'
      );
    }
    if (req.correlationKey.length() > 200) {
      throw new WorkflowEngine.WorkflowException(
        'Correlation key length cannot exceed 200 characters.'
      );
    }
  }

  /**
   * @description Enforces non-negative debounce and (optional) max-wait windows.
   * @param req The request whose timing windows are validated.
   */
  private static void validateRequestTiming(
    WorkflowDebouncer.DebounceRequest req
  ) {
    if (req.debounceSeconds == null || req.debounceSeconds < 0) {
      throw new WorkflowEngine.WorkflowException(
        'Debounce seconds must be non-negative.'
      );
    }
    if (req.maxWaitSeconds != null && req.maxWaitSeconds < 0) {
      throw new WorkflowEngine.WorkflowException(
        'Max wait seconds must be non-negative.'
      );
    }
  }

  /**
   * @description Enforces the input JSON payload size ceiling.
   * @param req The request whose input payload size is validated.
   */
  private static void validateRequestPayloadSize(
    WorkflowDebouncer.DebounceRequest req
  ) {
    if (String.isNotBlank(req.inputJson) && req.inputJson.length() > 131072) {
      throw new WorkflowEngine.WorkflowException(
        'Input JSON payload exceeds maximum size limit of 131,072 characters.'
      );
    }
  }
}
