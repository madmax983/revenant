/**
 * @description Best-effort logger that persists engine errors to Workflow_Log__c records,
 * swallowing insert failures so diagnostics logging can never break workflow execution.
 */
public with sharing class WorkflowLog {
  private static final String LEVEL_ERROR = 'Error';
  private static final Integer MAX_MESSAGE_LENGTH = 131000;

  /**
   * @description Immutable-style parameter object describing a single error log
   * entry, bundling the required category/message with the optional workflow
   * context so callers do not exceed the parameter-list threshold. Required
   * fields are supplied through the constructor; optional context is stamped
   * through fluent setters, mirroring the request-object convention used
   * elsewhere in the engine (e.g. WorkflowEngine.SignalRequest).
   */
  public class ErrorEntry {
    /**
     * @description A short category label classifying the source of the error.
     */
    public String logType;
    /**
     * @description The error detail to persist; truncated if it exceeds the field limit.
     */
    public String message;
    /**
     * @description The Id of the workflow instance the error relates to, if any.
     */
    public Id instanceId;
    /**
     * @description The correlation key tying the error to a business transaction, if any.
     */
    public String correlationKey;
    /**
     * @description The developer name of the workflow that produced the error, if any.
     */
    public String workflowName;

    /**
     * @description Builds an error entry with the required category and message
     * and no additional workflow context.
     * @param logType A short category label classifying the source of the error.
     * @param message The error detail to persist; truncated if it exceeds the field limit.
     */
    public ErrorEntry(String logType, String message) {
      this.logType = logType;
      this.message = message;
    }

    /**
     * @description Fluent setter stamping the related workflow instance Id.
     * @param instanceIdArg The Id of the workflow instance the error relates to.
     * @return this entry, for call chaining.
     */
    public ErrorEntry withInstanceId(Id instanceIdArg) {
      this.instanceId = instanceIdArg;
      return this;
    }

    /**
     * @description Fluent setter stamping the business-transaction correlation key.
     * @param correlationKeyArg The correlation key tying the error to a business transaction.
     * @return this entry, for call chaining.
     */
    public ErrorEntry withCorrelationKey(String correlationKeyArg) {
      this.correlationKey = correlationKeyArg;
      return this;
    }

    /**
     * @description Fluent setter stamping the originating workflow developer name.
     * @param workflowNameArg The developer name of the workflow that produced the error.
     * @return this entry, for call chaining.
     */
    public ErrorEntry withWorkflowName(String workflowNameArg) {
      this.workflowName = workflowNameArg;
      return this;
    }
  }

  /**
   * @description Records an error log entry with no instance or workflow context.
   * @param logType A short category label classifying the source of the error.
   * @param message The error detail to persist; truncated if it exceeds the field limit.
   */
  public static void error(String logType, String message) {
    error(new ErrorEntry(logType, message));
  }

  /**
   * @description Records an error log entry associated with a specific workflow instance.
   * @param logType A short category label classifying the source of the error.
   * @param message The error detail to persist; truncated if it exceeds the field limit.
   * @param instanceId The Id of the workflow instance the error relates to.
   */
  public static void error(String logType, String message, Id instanceId) {
    error(new ErrorEntry(logType, message).withInstanceId(instanceId));
  }

  /**
   * @description Persists a fully-contextualized error log entry, truncating oversized
   * messages and silently ignoring any insert failure.
   * @param entry The parameter object describing the error to persist.
   */
  public static void error(ErrorEntry entry) {
    String truncated = entry.message;
    if (truncated != null && truncated.length() > MAX_MESSAGE_LENGTH) {
      truncated = truncated.substring(0, MAX_MESSAGE_LENGTH);
    }
    Workflow_Log__c logRecord = new Workflow_Log__c(
      Level__c = LEVEL_ERROR,
      Log_Type__c = entry.logType,
      Message__c = truncated,
      Workflow_Instance__c = entry.instanceId,
      Correlation_Key__c = entry.correlationKey,
      Workflow_Name__c = entry.workflowName,
      Fire_Time__c = System.now()
    );
    try {
      insert as system logRecord;
    } catch (Exception ignored) {
    }
  }
}
