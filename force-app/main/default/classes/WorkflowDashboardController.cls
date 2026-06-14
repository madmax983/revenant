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
        System.debug(LoggingLevel.FINE, 'getAttachmentId parsing fallback: ' + ex.getMessage());
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
  public static List<Map<String, Object>> getFilteredInstances(
    String workflowName,
    String status,
    String searchTerm,
    Integer limitSize,
    Integer offsetSize,
    String cacheBuster
  ) {
    checkAuthorization();

    if (limitSize == null || limitSize <= 0) {
      limitSize = 50;
    } else if (limitSize > 100) {
      limitSize = 100;
    }

    if (offsetSize == null || offsetSize < 0) {
      offsetSize = 0;
    } else if (offsetSize > 2000) {
      offsetSize = 2000;
    }

    String query =
      'SELECT Id, Name, Workflow_Name__c, Status__c, Correlation_Key__c, CreatedDate, Error_Message__c, Async_Job_Id__c, Sleep_Until__c ' +
      'FROM Workflow_Instance__c' +
      buildWhereClause(workflowName, status, searchTerm);

    query += ' ORDER BY CreatedDate DESC LIMIT :limitSize OFFSET :offsetSize';

    List<Workflow_Instance__c> instances = Database.query(query, AccessLevel.SYSTEM_MODE);

    Set<Id> cronIds = new Set<Id>();
    Set<Id> asyncIds = new Set<Id>();
    for (Workflow_Instance__c inst : instances) {
      if (String.isNotBlank(inst.Async_Job_Id__c)) {
        String jobIdStr = inst.Async_Job_Id__c;
        if ((jobIdStr.length() == 15 || jobIdStr.length() == 18) && 
            (jobIdStr.startsWith('08e') || jobIdStr.startsWith('707'))) {
          try {
            Id jobId = (Id) jobIdStr;
            if (jobId.getSobjectType() == CronTrigger.SObjectType) {
              cronIds.add(jobId);
            } else if (jobId.getSobjectType() == AsyncApexJob.SObjectType) {
              asyncIds.add(jobId);
            }
          } catch (Exception ex) {
            System.debug(LoggingLevel.WARN, 'Failed to cast Async Job ID: ' + jobIdStr + ', error: ' + ex.getMessage());
          }
        } else {
          System.debug(LoggingLevel.WARN, 'Invalid Async Job ID format: ' + jobIdStr);
        }
      }
    }

    Set<Id> activeCronIds = new Set<Id>();
    if (!cronIds.isEmpty()) {
      for (CronTrigger ct : [SELECT Id FROM CronTrigger WHERE Id IN :cronIds AND State IN ('WAITING', 'ACQUIRED', 'QUEUED', 'EXECUTING') WITH SYSTEM_MODE]) {
        activeCronIds.add(ct.Id);
      }
    }

    Set<Id> activeAsyncIds = new Set<Id>();
    if (!asyncIds.isEmpty()) {
      for (AsyncApexJob aaj : [SELECT Id FROM AsyncApexJob WHERE Id IN :asyncIds AND Status IN ('Queued', 'Holding', 'Preparing', 'Processing') WITH SYSTEM_MODE]) {
        activeAsyncIds.add(aaj.Id);
      }
    }

    List<Map<String, Object>> results = new List<Map<String, Object>>();
    for (Workflow_Instance__c inst : instances) {
      Map<String, Object> m = new Map<String, Object>{
        'Id' => inst.Id,
        'Name' => inst.Name,
        'Workflow_Name__c' => inst.Workflow_Name__c,
        'Status__c' => inst.Status__c,
        'Correlation_Key__c' => inst.Correlation_Key__c,
        'CreatedDate' => inst.CreatedDate,
        'Error_Message__c' => inst.Error_Message__c,
        'Async_Job_Id__c' => inst.Async_Job_Id__c,
        'Sleep_Until__c' => inst.Sleep_Until__c
      };

      String waitingOn = null;
      if (inst.Status__c == 'Suspended') {
        if (String.isNotBlank(inst.Async_Job_Id__c)) {
          String jobIdStr = inst.Async_Job_Id__c;
          if ((jobIdStr.length() == 15 || jobIdStr.length() == 18) && 
              (jobIdStr.startsWith('08e') || jobIdStr.startsWith('707'))) {
            try {
              Id jobId = (Id) jobIdStr;
              if (jobId.getSobjectType() == CronTrigger.SObjectType && activeCronIds.contains(jobId)) {
                waitingOn = 'Scheduled Job';
              } else if (jobId.getSobjectType() == AsyncApexJob.SObjectType && activeAsyncIds.contains(jobId)) {
                waitingOn = 'Delayed Queueable';
              } else {
                waitingOn = 'Watchdog';
              }
            } catch (Exception ex) {
              System.debug(LoggingLevel.WARN, 'Failed to cast Async Job ID: ' + jobIdStr + ', error: ' + ex.getMessage());
              waitingOn = 'Watchdog';
            }
          } else {
            System.debug(LoggingLevel.WARN, 'Invalid Async Job ID format: ' + jobIdStr);
            waitingOn = 'Watchdog';
          }
        } else if (inst.Sleep_Until__c != null) {
          waitingOn = 'Watchdog';
        }
      }
      m.put('waitingOn', waitingOn);
      results.add(m);
    }
    return results;
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
        Previous_Instance__r.Name,
        Async_Job_Id__c,
        Sleep_Until__c
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
    String waitingOn = null;
    if (instance.Status__c == 'Suspended') {
      if (String.isNotBlank(instance.Async_Job_Id__c)) {
        String jobIdStr = instance.Async_Job_Id__c;
        if ((jobIdStr.length() == 15 || jobIdStr.length() == 18) && 
            (jobIdStr.startsWith('08e') || jobIdStr.startsWith('707'))) {
          try {
            Id jobId = (Id) jobIdStr;
            if (jobId.getSobjectType() == CronTrigger.SObjectType) {
              List<CronTrigger> cronJobs = [SELECT Id FROM CronTrigger WHERE Id = :jobId AND State IN ('WAITING', 'ACQUIRED', 'QUEUED', 'EXECUTING') WITH SYSTEM_MODE LIMIT 1];
              if (!cronJobs.isEmpty()) {
                waitingOn = 'Scheduled Job';
              } else {
                waitingOn = 'Watchdog';
              }
            } else if (jobId.getSobjectType() == AsyncApexJob.SObjectType) {
              List<AsyncApexJob> asyncJobs = [SELECT Id FROM AsyncApexJob WHERE Id = :jobId AND Status IN ('Queued', 'Holding', 'Preparing', 'Processing') WITH SYSTEM_MODE LIMIT 1];
              if (!asyncJobs.isEmpty()) {
                waitingOn = 'Delayed Queueable';
              } else {
                waitingOn = 'Watchdog';
              }
            }
          } catch (Exception ex) {
            System.debug(LoggingLevel.WARN, 'Failed to cast Async Job ID: ' + jobIdStr + ', error: ' + ex.getMessage());
            waitingOn = 'Watchdog';
          }
        } else {
          System.debug(LoggingLevel.WARN, 'Invalid Async Job ID format: ' + jobIdStr);
          waitingOn = 'Watchdog';
        }
      } else if (instance.Sleep_Until__c != null) {
        waitingOn = 'Watchdog';
      }
    }

    return new Map<String, Object>{
      'instance' => instance,
      'steps' => steps,
      'children' => children,
      'successor' => successors.isEmpty() ? null : successors[0],
      'waitingOn' => waitingOn
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
      System.debug(LoggingLevel.ERROR, 'Aura startWorkflow failed: ' + ex.getMessage() + '\n' + ex.getStackTraceString());
      throw new AuraHandledException(ex.getMessage());
    }
  }

  @AuraEnabled
  public static void retryWorkflowInstance(Id instanceId) {
    checkAuthorization();
    try {
      WorkflowEngine.retryWorkflow(instanceId);
    } catch (Exception ex) {
      System.debug(LoggingLevel.ERROR, 'Aura retryWorkflowInstance failed: ' + ex.getMessage() + '\n' + ex.getStackTraceString());
      throw new AuraHandledException(ex.getMessage());
    }
  }

  @AuraEnabled
  public static void resumeWorkflowInstance(Id instanceId) {
    checkAuthorization();
    try {
      List<Workflow_Instance__c> instances = [
        SELECT Id, Status__c, Sleep_Until__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId AND Status__c = 'Suspended'
        WITH SYSTEM_MODE
        LIMIT 1
        FOR UPDATE
      ];
      if (!instances.isEmpty()) {
        Workflow_Instance__c inst = instances[0];
        inst.Status__c = 'Running';
        inst.Sleep_Until__c = null;
        inst.Async_Job_Id__c = null;
        update as system inst;
        WorkflowEngine.enqueueOrchestrators(new List<Id>{ inst.Id });
      }
    } catch (Exception ex) {
      System.debug(LoggingLevel.ERROR, 'Aura resumeWorkflowInstance failed: ' + ex.getMessage() + '\n' + ex.getStackTraceString());
      throw new AuraHandledException(ex.getMessage());
    }
  }

  @AuraEnabled
  public static void cancelWorkflow(Id instanceId, Boolean runCompensations) {
    checkAuthorization();
    try {
      WorkflowEngine.cancel(instanceId, runCompensations);
    } catch (Exception ex) {
      System.debug(LoggingLevel.ERROR, 'Aura cancelWorkflow failed: ' + ex.getMessage() + '\n' + ex.getStackTraceString());
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
      System.debug(LoggingLevel.ERROR, 'Aura submitApproval failed: ' + ex.getMessage() + '\n' + ex.getStackTraceString());
      throw new AuraHandledException(ex.getMessage());
    }
  }

  @AuraEnabled
  public static Map<String, Object> getWatchdogStatus() {
    checkAuthorization();
    try {
      List<Workflow_Instance__c> watchdogInstances = [
        SELECT
          Id,
          Name,
          Status__c,
          Current_Step__c,
          Error_Message__c,
          CreatedDate,
          LastModifiedDate
        FROM Workflow_Instance__c
        WHERE Correlation_Key__c = 'SystemWatchdog'
           OR Correlation_Key__c LIKE 'SystemWatchdog_run%'
        WITH SYSTEM_MODE
        ORDER BY CreatedDate DESC
        LIMIT 5
      ];
      Boolean isRunning = false;
      Workflow_Instance__c latestWatchdog = null;
      if (!watchdogInstances.isEmpty()) {
        latestWatchdog = watchdogInstances[0];
        String status = latestWatchdog.Status__c;
        if (
          status == 'Pending' ||
          status == 'Running' ||
          status == 'Suspended'
        ) {
          isRunning = true;
        }
      }

      Integer scheduledJobsCount = [
        SELECT COUNT()
        FROM CronTrigger
        WITH SYSTEM_MODE
      ];

      Integer sleepingInstances = [
        SELECT COUNT()
        FROM Workflow_Instance__c
        WHERE Sleep_Until__c != NULL AND Status__c = 'Suspended'
        WITH SYSTEM_MODE
      ];

      Integer pendingTimeouts = [
        SELECT COUNT()
        FROM Workflow_Step_Execution__c
        WHERE Timeout_At__c != NULL AND Status__c = 'Pending'
        WITH SYSTEM_MODE
      ];

      Map<String, System.OrgLimit> limitsMap = System.OrgLimits.getMap();
      Integer dailyAsyncValue = 0;
      Integer dailyAsyncLimit = 0;
      Boolean hasElasticLimit = false;
      Integer elasticAsyncValue = 0;
      Integer elasticAsyncLimit = 0;

      if (limitsMap.containsKey('DailyAsyncApexExecutions')) {
        System.OrgLimit limitObj = limitsMap.get('DailyAsyncApexExecutions');
        dailyAsyncValue = limitObj.getValue();
        dailyAsyncLimit = limitObj.getLimit();
      }
      if (limitsMap.containsKey('DailyAsyncApexElasticExecutions')) {
        System.OrgLimit limitObj = limitsMap.get(
          'DailyAsyncApexElasticExecutions'
        );
        hasElasticLimit = true;
        elasticAsyncValue = limitObj.getValue();
        elasticAsyncLimit = limitObj.getLimit();
      }

      Map<String, Object> config = new Map<String, Object>{
        'Use_Dynamic_Scheduling__c' => WorkflowEngine.useDynamicScheduling,
        'Watchdog_Delay_Minutes__c' => WorkflowEngine.watchdogDelayMinutes
      };

      return new Map<String, Object>{
        'isRunning' => isRunning,
        'latestJob' => latestWatchdog,
        'recentJobs' => watchdogInstances,
        'scheduledJobsCount' => scheduledJobsCount,
        'sleepingInstances' => sleepingInstances,
        'pendingTimeouts' => pendingTimeouts,
        'config' => config,
        'dailyAsyncValue' => dailyAsyncValue,
        'dailyAsyncLimit' => dailyAsyncLimit,
        'hasElasticLimit' => hasElasticLimit,
        'elasticAsyncValue' => elasticAsyncValue,
        'elasticAsyncLimit' => elasticAsyncLimit
      };
    } catch (Exception ex) {
      System.debug(LoggingLevel.ERROR, 'Aura getWatchdogStatus failed: ' + ex.getMessage() + '\n' + ex.getStackTraceString());
      throw new AuraHandledException(ex.getMessage());
    }
  }

  @AuraEnabled
  public static void enqueueWatchdog() {
    checkAuthorization();
    try {
      WorkflowWatchdog.bootstrap();
    } catch (Exception ex) {
      System.debug(LoggingLevel.ERROR, 'Aura enqueueWatchdog failed: ' + ex.getMessage() + '\n' + ex.getStackTraceString());
      throw new AuraHandledException(ex.getMessage());
    }
  }
}
