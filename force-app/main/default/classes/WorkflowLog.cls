public with sharing class WorkflowLog {
  private static final String LEVEL_ERROR = 'Error';
  private static final Integer MAX_MESSAGE_LENGTH = 131000;

  public static void error(String logType, String message) {
    error(logType, message, null, null, null);
  }

  public static void error(String logType, String message, Id instanceId) {
    error(logType, message, instanceId, null, null);
  }

  public static void error(
    String logType,
    String message,
    Id instanceId,
    String correlationKey,
    String workflowName
  ) {
    Workflow_Log__c logRecord = buildLog(
      logType,
      message,
      instanceId,
      correlationKey,
      workflowName
    );
    try {
      insert as system logRecord;
    } catch (Exception ignored) {
    }
  }

  private static Workflow_Log__c buildLog(
    String logType,
    String message,
    Id instanceId,
    String correlationKey,
    String workflowName
  ) {
    String truncated = message;
    if (truncated != null && truncated.length() > MAX_MESSAGE_LENGTH) {
      truncated = truncated.substring(0, MAX_MESSAGE_LENGTH);
    }
    return new Workflow_Log__c(
      Level__c = LEVEL_ERROR,
      Log_Type__c = logType,
      Message__c = truncated,
      Workflow_Instance__c = instanceId,
      Correlation_Key__c = correlationKey,
      Workflow_Name__c = workflowName,
      Fire_Time__c = System.now()
    );
  }
}
