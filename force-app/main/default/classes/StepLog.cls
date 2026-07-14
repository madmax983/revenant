/**
 * @description Buffered breadcrumb logging for a single step execution, split
 * out of StepContext. Owns the in-memory breadcrumb list and the volume and
 * character-length caps that keep step logs bounded. Reached by step authors
 * via StepContext.logger(). The breadcrumb value type and severity enum remain
 * nested on StepContext (StepContext.Breadcrumb / StepContext.Level) so existing
 * references keep compiling.
 */
public inherited sharing class StepLog {
  /** Maximum number of breadcrumb entries retained before logs are discarded. */
  private static final Integer MAX_LOG_ENTRIES = 100;
  /** Maximum character length of a single breadcrumb message. */
  private static final Integer MAX_MESSAGE_LENGTH = 4000;

  /** The buffered breadcrumb entries for this step execution, in log order. */
  private List<StepContext.Breadcrumb> breadcrumbs = new List<StepContext.Breadcrumb>();

  /**
   * @description Logs a message at the specified level without any context.
   * @param level The severity level (INFO, WARN, or ERROR).
   * @param message The log message.
   */
  public void log(StepContext.Level level, String message) {
    this.log(level, message, null);
  }

  /**
   * @description Logs a message at the specified level with a context map, which
   * will be serialized as JSON. Enforces log volume caps (up to 100 entries, with
   * a truncation warning on the 101st log) and character length limits (entries
   * are truncated to exactly 4000 characters).
   * @param level The severity level (INFO, WARN, or ERROR).
   * @param message The log message.
   * @param logContext Context data as key-value pairs to be appended to the log.
   */
  public void log(
    StepContext.Level level,
    String message,
    Map<String, Object> logContext
  ) {
    if (this.breadcrumbs.size() > MAX_LOG_ENTRIES) {
      return;
    }
    if (this.breadcrumbs.size() == MAX_LOG_ENTRIES) {
      this.breadcrumbs.add(buildTruncationBreadcrumb());
      return;
    }

    String formattedMessage = appendContext(message, logContext);
    formattedMessage = capMessageLength(formattedMessage);
    this.breadcrumbs.add(new StepContext.Breadcrumb(level, formattedMessage));
  }

  /**
   * @description Builds the single truncation-warning breadcrumb appended when
   * the log-entry cap is first reached.
   * @return A WARN breadcrumb announcing that subsequent logs are discarded.
   */
  private static StepContext.Breadcrumb buildTruncationBreadcrumb() {
    return new StepContext.Breadcrumb(
      StepContext.Level.WARN,
      '[TRUNCATED] Log limit of ' +
        MAX_LOG_ENTRIES +
        ' entries reached. Subsequent step logs are discarded.'
    );
  }

  /**
   * @description Appends the serialized context (if any) to the message, applying
   * the size, heap-pressure, oversized-value and serialization-failure guards in
   * order.
   * @param message The base log message.
   * @param logContext The context map to append, or null/empty for none.
   * @return The message with the serialized (or guard-substituted) context.
   */
  private static String appendContext(
    String message,
    Map<String, Object> logContext
  ) {
    if (logContext == null || logContext.isEmpty()) {
      return message;
    }
    String base = (message != null) ? message : 'null';
    if (logContext.size() > 50) {
      return base +
        ' | Context: [TRUNCATED] Map size limit of 50 entries exceeded.';
    }
    if (Limits.getHeapSize() > Limits.getLimitHeapSize() * 0.85) {
      return base +
        ' | Context: [TRUNCATED] JSON serialization bypassed due to heap pressure.';
    }
    if (hasOversizedStringValue(logContext)) {
      return base +
        ' | Context: [TRUNCATED] JSON serialization bypassed due to oversized string value.';
    }
    return base + ' | Context: ' + serializeContext(logContext);
  }

  /**
   * @description True when any string value in the context exceeds the per-message
   * length cap, so serialization is bypassed to avoid heap pressure.
   * @param logContext The context map to inspect.
   * @return True if a string value is oversized.
   */
  private static Boolean hasOversizedStringValue(
    Map<String, Object> logContext
  ) {
    for (Object val : logContext.values()) {
      if (
        val instanceof String && ((String) val).length() > MAX_MESSAGE_LENGTH
      ) {
        return true;
      }
    }
    return false;
  }

  /**
   * @description Serializes the context map to JSON, truncating to the message
   * cap and substituting a marker when serialization fails.
   * @param logContext The context map to serialize.
   * @return The serialized (and possibly truncated) context string.
   */
  private static String serializeContext(Map<String, Object> logContext) {
    try {
      String serializedContext = JSON.serialize(logContext);
      if (serializedContext.length() > MAX_MESSAGE_LENGTH) {
        serializedContext =
          serializedContext.substring(0, MAX_MESSAGE_LENGTH) +
          '... [TRUNCATED]';
      }
      return serializedContext;
    } catch (Exception ex) {
      return '[TRUNCATED] JSON serialization failed: ' + ex.getMessage();
    }
  }

  /**
   * @description Caps the formatted message to the maximum length, appending a
   * truncation marker when it is exceeded.
   * @param formattedMessage The formatted message to cap.
   * @return The capped message.
   */
  private static String capMessageLength(String formattedMessage) {
    if (
      formattedMessage != null &&
      formattedMessage.length() > MAX_MESSAGE_LENGTH
    ) {
      return formattedMessage.substring(0, MAX_MESSAGE_LENGTH - 15) +
        '... [TRUNCATED]';
    }
    return formattedMessage;
  }

  /**
   * @description Retrieves the buffered log entries (breadcrumbs) for this step
   * execution.
   * @return The list of Breadcrumb logs.
   */
  public List<StepContext.Breadcrumb> getBreadcrumbs() {
    return this.breadcrumbs;
  }
}
