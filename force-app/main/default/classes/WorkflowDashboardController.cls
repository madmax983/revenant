public inherited sharing class WorkflowDashboardController {
  // Class-level static binding variable for dynamic SOQL wildcard queries.
  // This is required because dynamic SOQL string bindings (:variable) must be in scope
  // when Database.query() is executed, even if the WHERE clause is built in a helper method.
  private static String likeTerm;

  private static void checkAuthorization() {
    if (FeatureManagement.checkPermission('Workflow_Admin')) {
      return;
    }
    List<Profile> profiles = [
      SELECT Name
      FROM Profile
      WHERE Id = :UserInfo.getProfileId()
      WITH SYSTEM_MODE
      LIMIT 1
    ];
    if (!profiles.isEmpty() && profiles[0].Name == 'System Administrator') {
      return;
    }

    AuraHandledException ex = new AuraHandledException(
      'Unauthorized: Access to the Workflow Dashboard is restricted.'
    );
    ex.setMessage(
      'Unauthorized: Access to the Workflow Dashboard is restricted.'
    );
    throw ex;
  }

  private static Id getAttachmentId(String textValue) {
    if (
      String.isNotBlank(textValue) && textValue.startsWith('{"$attachmentId":')
    ) {
      try {
        Map<String, Object> marker = (Map<String, Object>) JSON.deserializeUntyped(
          textValue
        );
        return (Id) marker.get('$attachmentId');
      } catch (Exception ex) {
        // fallback
      }
    }
    return null;
  }

  private static String truncatePayload(String val) {
    if (val != null && val.length() > 50000) {
      return val.substring(0, 50000) + '... (truncated)';
    }
    return val;
  }

  private static String resolveSinglePayload(
    String textValue,
    Map<Id, String> attachmentIdToData
  ) {
    if (String.isBlank(textValue)) {
      return textValue;
    }
    Id attachmentId = getAttachmentId(textValue);
    if (attachmentId != null) {
      if (attachmentIdToData.containsKey(attachmentId)) {
        return truncatePayload(attachmentIdToData.get(attachmentId));
      }
    }
    return truncatePayload(textValue);
  }

  private static void resolvePayloadsInBulk(
    Workflow_Instance__c instance,
    List<Workflow_Step_Execution__c> steps
  ) {
    Set<Id> attachmentIds = new Set<Id>();

    Id instInputId = getAttachmentId(instance.Input__c);
    if (instInputId != null)
      attachmentIds.add(instInputId);

    Id instOutputId = getAttachmentId(instance.Output__c);
    if (instOutputId != null)
      attachmentIds.add(instOutputId);

    for (Workflow_Step_Execution__c step : steps) {
      Id stepInputId = getAttachmentId(step.Input__c);
      if (stepInputId != null)
        attachmentIds.add(stepInputId);

      Id stepOutputId = getAttachmentId(step.Output__c);
      if (stepOutputId != null)
        attachmentIds.add(stepOutputId);
    }

    Map<Id, String> attachmentIdToData = new Map<Id, String>();
    if (!attachmentIds.isEmpty()) {
      for (ContentVersion cv : [
        SELECT ContentDocumentId, VersionData
        FROM ContentVersion
        WHERE ContentDocumentId IN :attachmentIds AND IsLatest = TRUE
        WITH SYSTEM_MODE
      ]) {
        if (cv.VersionData != null) {
          attachmentIdToData.put(
            cv.ContentDocumentId,
            cv.VersionData.toString()
          );
        }
      }
    }

    instance.Input__c = resolveSinglePayload(
      instance.Input__c,
      attachmentIdToData
    );
    instance.Output__c = resolveSinglePayload(
      instance.Output__c,
      attachmentIdToData
    );
    for (Workflow_Step_Execution__c step : steps) {
      step.Input__c = resolveSinglePayload(step.Input__c, attachmentIdToData);
      step.Output__c = resolveSinglePayload(step.Output__c, attachmentIdToData);
    }
  }

  private static String buildWhereClause(
    String workflowName,
    String status,
    String searchTerm
  ) {
    List<String> conditions = new List<String>();
    if (String.isNotBlank(workflowName)) {
      conditions.add('Workflow_Name__c = :workflowName');
    }
    if (String.isNotBlank(status)) {
      conditions.add('Status__c = :status');
    }
    if (String.isNotBlank(searchTerm)) {
      likeTerm = '%' + String.escapeSingleQuotes(searchTerm) + '%';
      conditions.add(
        '(Name LIKE :likeTerm OR Correlation_Key__c LIKE :likeTerm OR Workflow_Name__c LIKE :likeTerm OR Error_Message__c LIKE :likeTerm)'
      );
    }
    return conditions.isEmpty()
      ? ''
      : ' WHERE ' + String.join(conditions, ' AND ');
  }

  @AuraEnabled(cacheable=true)
  public static List<Workflow_Instance__c> getFilteredInstances(
    String workflowName,
    String status,
    String searchTerm,
    Integer limitSize,
    Integer offsetSize,
    String cacheBuster
  ) {
    checkAuthorization();
    String query =
      'SELECT Id, Name, Workflow_Name__c, Status__c, Correlation_Key__c, CreatedDate, Error_Message__c ' +
      'FROM Workflow_Instance__c' +
      buildWhereClause(workflowName, status, searchTerm);

    query += ' ORDER BY CreatedDate DESC LIMIT :limitSize OFFSET :offsetSize';

    return Database.query(query, AccessLevel.SYSTEM_MODE);
  }

  @AuraEnabled
  public static Map<String, Integer> getWorkflowStats(
    String workflowName,
    String status,
    String searchTerm
  ) {
    checkAuthorization();
    String query =
      'SELECT Status__c, COUNT(Id) cnt FROM Workflow_Instance__c' +
      buildWhereClause(workflowName, status, searchTerm) +
      ' GROUP BY Status__c';

    Map<String, Integer> results = new Map<String, Integer>{
      'total' => 0,
      'active' => 0,
      'completed' => 0,
      'failed' => 0
    };

    for (AggregateResult ar : Database.query(query, AccessLevel.SYSTEM_MODE)) {
      String stat = (String) ar.get('Status__c');
      Integer count = (Integer) ar.get('cnt');
      results.put('total', results.get('total') + count);

      if (
        stat == 'Pending' ||
        stat == 'Running' ||
        stat == 'Suspended' ||
        stat == 'Compensating' ||
        stat == 'Cancelling'
      ) {
        results.put('active', results.get('active') + count);
      } else if (stat == 'Completed' || stat == 'ContinuedAsNew') {
        results.put('completed', results.get('completed') + count);
      } else if (
        stat == 'Failed' ||
        stat == 'Compensated' ||
        stat == 'Cancelled'
      ) {
        results.put('failed', results.get('failed') + count);
      }
    }
    return results;
  }

  @AuraEnabled
  public static Map<String, Object> getInstanceDetails(Id instanceId) {
    checkAuthorization();
    Workflow_Instance__c instance = [
      SELECT
        Id,
        Name,
        Workflow_Name__c,
        Status__c,
        Correlation_Key__c,
        Input__c,
        Output__c,
        Current_Step__c,
        Error_Message__c,
        CreatedDate,
        Parent_Instance__c,
        Parent_Instance__r.Name,
        Previous_Instance__c,
        Previous_Instance__r.Name
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
      WITH SYSTEM_MODE
    ];

    List<Workflow_Step_Execution__c> steps = [
      SELECT
        Id,
        Step_Name__c,
        Status__c,
        Input__c,
        Output__c,
        Retry_Count__c,
        Error_Details__c,
        CreatedDate
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c = :instanceId
      WITH SYSTEM_MODE
      ORDER BY CreatedDate ASC
    ];
    resolvePayloadsInBulk(instance, steps);

    List<Workflow_Instance__c> children = [
      SELECT
        Id,
        Name,
        Workflow_Name__c,
        Status__c,
        Correlation_Key__c,
        CreatedDate
      FROM Workflow_Instance__c
      WHERE Parent_Instance__c = :instanceId
      WITH SYSTEM_MODE
      ORDER BY CreatedDate ASC
    ];

    List<Workflow_Instance__c> successors = [
      SELECT Id, Name
      FROM Workflow_Instance__c
      WHERE Previous_Instance__c = :instanceId
      WITH SYSTEM_MODE
      LIMIT 1
    ];
    Workflow_Instance__c successor = successors.isEmpty()
      ? null
      : successors[0];

    return new Map<String, Object>{
      'instance' => instance,
      'steps' => steps,
      'children' => children,
      'successor' => successor
    };
  }

  @AuraEnabled(cacheable=true)
  public static List<String> getDefinitions() {
    checkAuthorization();
    List<String> definitions = new List<String>();
    // Query Apex classes and check body in memory to bypass SOQL Body restriction
    List<ApexClass> classes = [
      SELECT Name, Body
      FROM ApexClass
      WHERE NamespacePrefix = NULL
      WITH SYSTEM_MODE
      ORDER BY Name ASC
    ];

    Pattern classPattern = Pattern.compile(
      '(?i)\\bclass\\s+([a-zA-Z0-9_]+)\\s+[^\\{]*?\\bimplements\\s+[^\\{]*?\\b(WorkflowDefinition|VersionedWorkflow)\\b'
    );

    for (ApexClass ac : classes) {
      if (ac.Body != null) {
        Matcher pm = classPattern.matcher(ac.Body);
        while (pm.find()) {
          String className = pm.group(1);
          // Check if it's the outer class or an inner class
          if (className.equalsIgnoreCase(ac.Name)) {
            // Exclude test classes
            if (
              !ac.Name.contains('WorkflowEngineTest') &&
              !ac.Name.contains('WorkflowDashboardControllerTest')
            ) {
              definitions.add(ac.Name);
            }
          } else {
            // Inner class: prefix with outer class name
            // Exclude test classes
            if (
              !ac.Name.contains('WorkflowEngineTest') &&
              !ac.Name.contains('WorkflowDashboardControllerTest')
            ) {
              definitions.add(ac.Name + '.' + className);
            }
          }
        }
      }
    }
    definitions.sort();
    return definitions;
  }

  @AuraEnabled
  public static Id startWorkflow(
    String workflowName,
    String correlationKey,
    String inputJson
  ) {
    checkAuthorization();
    try {
      Object input = null;
      if (String.isNotBlank(inputJson)) {
        input = JSON.deserializeUntyped(inputJson);
      }
      return WorkflowEngine.start(workflowName, correlationKey, input);
    } catch (Exception ex) {
      throw new AuraHandledException(ex.getMessage());
    }
  }

  @AuraEnabled
  public static void retryWorkflowInstance(Id instanceId) {
    checkAuthorization();
    try {
      WorkflowEngine.retryWorkflow(instanceId);
    } catch (Exception ex) {
      throw new AuraHandledException(ex.getMessage());
    }
  }

  @AuraEnabled
  public static void cancelWorkflow(Id instanceId, Boolean runCompensations) {
    checkAuthorization();
    try {
      WorkflowEngine.cancel(instanceId, runCompensations);
    } catch (Exception ex) {
      throw new AuraHandledException(ex.getMessage());
    }
  }

  @AuraEnabled
  public static void submitApproval(
    Id instanceId,
    String approvalKey,
    Boolean approved,
    String comments
  ) {
    checkAuthorization();
    try {
      Map<String, Object> payload = new Map<String, Object>{
        'approved' => approved,
        'comments' => comments,
        'approver' => UserInfo.getName()
      };
      String payloadJson = JSON.serialize(payload);
      String signalName = 'Approve:' + approvalKey;

      WorkflowEngine.signal(
        String.valueOf(instanceId),
        signalName,
        payloadJson
      );
    } catch (Exception ex) {
      throw new AuraHandledException(ex.getMessage());
    }
  }
}
