public inherited sharing class WorkflowDashboardController {
  // Class-level static binding variable for dynamic SOQL wildcard queries.
  // This is required because dynamic SOQL string bindings (:variable) must be in scope
  // when Database.query() is executed, even if the WHERE clause is built in a helper method.
  private static String likeTerm;
  // Binding variable for the stalled-instance cutoff DateTime (used in getStalledInstances /
  // getStalledCount dynamic SOQL — same reason as likeTerm above).
  private static Datetime stalledCutoff;

  private static final Set<String> TERMINAL_STATUSES = new Set<String>{
    'Completed',
    'Failed',
    'Compensated',
    'Cancelled',
    'ContinuedAsNew'
  };

  private static void checkAuthorization() {
    if (FeatureManagement.checkPermission('Workflow_Admin')) {
      return;
    }
    // Fall back to users who hold the "Modify All Data" system permission (see
    // currentUserHasModifyAllData). This replaces the previous hard-coded 'System
    // Administrator' profile-NAME comparison, which silently locked out real admins when
    // the profile was renamed (common post-migration) and could be spoofed by cloning a
    // profile and naming it 'System Administrator'.
    if (currentUserHasModifyAllData()) {
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

  /**
   * True when the running user has "Modify All Data", granted via EITHER their profile or
   * an assigned permission set. Rename-proof and covers permission-set-granted admins,
   * unlike matching a mutable profile name.
   */
  private static Boolean currentUserHasModifyAllData() {
    return ![
        SELECT Id
        FROM PermissionSetAssignment
        WHERE
          AssigneeId = :UserInfo.getUserId()
          AND PermissionSet.PermissionsModifyAllData = TRUE
        WITH SYSTEM_MODE
        LIMIT 1
      ]
      .isEmpty();
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
        System.debug(
          LoggingLevel.FINE,
          'getAttachmentId parsing fallback: ' + ex.getMessage()
        );
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

  // Character length above which the dashboard shows a truncated preview. Payloads that
  // are attachment-backed AND exceed this get a download link to the full ContentDocument.
  @TestVisible
  private static final Integer PAYLOAD_DISPLAY_LIMIT = 50000;

  /**
   * Resolves a payload field for display: returns the (possibly truncated) text and, when
   * the value is attachment-backed and was truncated, records a download descriptor for
   * the full ContentDocument under fieldKey in payloadFiles so the UI can offer the file.
   */
  private static String resolveAndRecordPayload(
    String textValue,
    String fieldKey,
    Map<Id, String> attachmentIdToData,
    Map<String, Object> payloadFiles
  ) {
    if (String.isBlank(textValue)) {
      return textValue;
    }
    Id attachmentId = getAttachmentId(textValue);
    if (attachmentId != null && attachmentIdToData.containsKey(attachmentId)) {
      String full = attachmentIdToData.get(attachmentId);
      if (full != null && full.length() > PAYLOAD_DISPLAY_LIMIT) {
        payloadFiles.put(
          fieldKey,
          new Map<String, Object>{
            'contentDocumentId' => attachmentId,
            'downloadUrl' => '/sfc/servlet.shepherd/document/download/' +
            attachmentId,
            'fullLength' => full.length()
          }
        );
      }
      return truncatePayload(full);
    }
    return truncatePayload(textValue);
  }

  private static Map<String, Object> resolvePayloadsInBulk(
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

    Map<String, Object> payloadFiles = new Map<String, Object>();
    instance.Input__c = resolveAndRecordPayload(
      instance.Input__c,
      'instance.Input',
      attachmentIdToData,
      payloadFiles
    );
    instance.Output__c = resolveAndRecordPayload(
      instance.Output__c,
      'instance.Output',
      attachmentIdToData,
      payloadFiles
    );
    for (Workflow_Step_Execution__c step : steps) {
      step.Input__c = resolveAndRecordPayload(
        step.Input__c,
        'step.' + step.Id + '.Input',
        attachmentIdToData,
        payloadFiles
      );
      step.Output__c = resolveAndRecordPayload(
        step.Output__c,
        'step.' + step.Id + '.Output',
        attachmentIdToData,
        payloadFiles
      );
    }
    return payloadFiles;
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
      'SELECT Id, Name, Workflow_Name__c, Status__c, Correlation_Key__c, CreatedDate, LastModifiedDate, Error_Message__c, Async_Job_Id__c, Sleep_Until__c ' +
      'FROM Workflow_Instance__c' +
      buildWhereClause(workflowName, status, searchTerm);

    query += ' ORDER BY CreatedDate DESC LIMIT :limitSize OFFSET :offsetSize';

    List<Workflow_Instance__c> instances = Database.query(
      query,
      AccessLevel.SYSTEM_MODE
    );

    Set<Id> cronIds = new Set<Id>();
    Set<Id> asyncIds = new Set<Id>();
    Set<Id> pageIds = new Set<Id>();
    for (Workflow_Instance__c inst : instances) {
      pageIds.add(inst.Id);
      collectJobId(inst.Async_Job_Id__c, cronIds, asyncIds);
    }

    Set<Id> activeCronIds = queryActiveCronIds(cronIds);
    Set<Id> activeAsyncIds = queryActiveAsyncIds(asyncIds);
    Set<Id> instancesWithStepTimeout = queryInstancesWithStepTimeout(pageIds);

    Long nowMs = Datetime.now().getTime();
    List<Map<String, Object>> results = new List<Map<String, Object>>();
    for (Workflow_Instance__c inst : instances) {
      String waitingOn = computeWaitingOn(inst, activeCronIds, activeAsyncIds);
      Long idleMinutes = TERMINAL_STATUSES.contains(inst.Status__c)
        ? null
        : Math.max(0L, (nowMs - inst.LastModifiedDate.getTime()) / 60000L);
      Boolean stalled = computeStalled(
        inst,
        waitingOn,
        instancesWithStepTimeout,
        idleMinutes,
        WorkflowEngine.staleThresholdMinutes
      );

      Map<String, Object> m = new Map<String, Object>{
        'Id' => inst.Id,
        'Name' => inst.Name,
        'Workflow_Name__c' => inst.Workflow_Name__c,
        'Status__c' => inst.Status__c,
        'Correlation_Key__c' => inst.Correlation_Key__c,
        'CreatedDate' => inst.CreatedDate,
        'LastModifiedDate' => inst.LastModifiedDate,
        'Error_Message__c' => inst.Error_Message__c,
        'Async_Job_Id__c' => inst.Async_Job_Id__c,
        'Sleep_Until__c' => inst.Sleep_Until__c,
        'waitingOn' => waitingOn,
        'idleMinutes' => idleMinutes,
        'stalled' => stalled
      };
      results.add(m);
    }
    return results;
  }

  @AuraEnabled(cacheable=true)
  public static List<Map<String, Object>> getStalledInstances(
    String workflowName,
    String searchTerm,
    Integer thresholdMinutes,
    Integer limitSize,
    Integer offsetSize
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

    Integer threshold = (thresholdMinutes == null)
      ? WorkflowEngine.staleThresholdMinutes
      : thresholdMinutes;
    stalledCutoff = Datetime.now().addMinutes(-threshold);

    List<String> conditions = new List<String>{
      'Status__c = \'Suspended\'',
      'Sleep_Until__c = null',
      'LastModifiedDate <= :stalledCutoff'
    };
    if (String.isNotBlank(workflowName)) {
      conditions.add('Workflow_Name__c = :workflowName');
    }
    if (String.isNotBlank(searchTerm)) {
      likeTerm = '%' + String.escapeSingleQuotes(searchTerm) + '%';
      conditions.add(
        '(Name LIKE :likeTerm OR Correlation_Key__c LIKE :likeTerm OR Workflow_Name__c LIKE :likeTerm OR Error_Message__c LIKE :likeTerm)'
      );
    }

    String query =
      'SELECT Id, Name, Workflow_Name__c, Status__c, Correlation_Key__c, CreatedDate, LastModifiedDate, Error_Message__c, Async_Job_Id__c, Sleep_Until__c ' +
      'FROM Workflow_Instance__c WHERE ' +
      String.join(conditions, ' AND ') +
      ' ORDER BY LastModifiedDate ASC LIMIT :limitSize OFFSET :offsetSize';

    List<Workflow_Instance__c> instances = Database.query(
      query,
      AccessLevel.SYSTEM_MODE
    );

    Set<Id> cronIds = new Set<Id>();
    Set<Id> asyncIds = new Set<Id>();
    Set<Id> pageIds = new Set<Id>();
    for (Workflow_Instance__c inst : instances) {
      pageIds.add(inst.Id);
      collectJobId(inst.Async_Job_Id__c, cronIds, asyncIds);
    }

    Set<Id> activeCronIds = queryActiveCronIds(cronIds);
    Set<Id> activeAsyncIds = queryActiveAsyncIds(asyncIds);
    Set<Id> instancesWithStepTimeout = queryInstancesWithStepTimeout(pageIds);

    Long nowMs = Datetime.now().getTime();
    List<Map<String, Object>> results = new List<Map<String, Object>>();
    for (Workflow_Instance__c inst : instances) {
      String waitingOn = computeWaitingOn(inst, activeCronIds, activeAsyncIds);
      Long idleMinutes = Math.max(
        0L,
        (nowMs - inst.LastModifiedDate.getTime()) / 60000L
      );
      if (
        !computeStalled(
          inst,
          waitingOn,
          instancesWithStepTimeout,
          idleMinutes,
          threshold
        )
      ) {
        continue;
      }
      results.add(
        new Map<String, Object>{
          'Id' => inst.Id,
          'Name' => inst.Name,
          'Workflow_Name__c' => inst.Workflow_Name__c,
          'Status__c' => inst.Status__c,
          'Correlation_Key__c' => inst.Correlation_Key__c,
          'CreatedDate' => inst.CreatedDate,
          'LastModifiedDate' => inst.LastModifiedDate,
          'Error_Message__c' => inst.Error_Message__c,
          'Async_Job_Id__c' => inst.Async_Job_Id__c,
          'Sleep_Until__c' => inst.Sleep_Until__c,
          'waitingOn' => waitingOn,
          'idleMinutes' => idleMinutes,
          'stalled' => true
        }
      );
    }
    return results;
  }

  @AuraEnabled
  public static Map<String, Object> getStalledCount(
    String workflowName,
    String searchTerm,
    Integer thresholdMinutes
  ) {
    checkAuthorization();

    Integer threshold = (thresholdMinutes == null)
      ? WorkflowEngine.staleThresholdMinutes
      : thresholdMinutes;
    stalledCutoff = Datetime.now().addMinutes(-threshold);

    final Integer CAP = 2000;
    List<String> conditions = new List<String>{
      'Status__c = \'Suspended\'',
      'Sleep_Until__c = null',
      'LastModifiedDate <= :stalledCutoff'
    };
    if (String.isNotBlank(workflowName)) {
      conditions.add('Workflow_Name__c = :workflowName');
    }
    if (String.isNotBlank(searchTerm)) {
      likeTerm = '%' + String.escapeSingleQuotes(searchTerm) + '%';
      conditions.add(
        '(Name LIKE :likeTerm OR Correlation_Key__c LIKE :likeTerm OR Workflow_Name__c LIKE :likeTerm OR Error_Message__c LIKE :likeTerm)'
      );
    }

    String query =
      'SELECT Id, Async_Job_Id__c, Sleep_Until__c, Status__c, LastModifiedDate ' +
      'FROM Workflow_Instance__c WHERE ' +
      String.join(conditions, ' AND ') +
      ' LIMIT :CAP';

    List<Workflow_Instance__c> candidates = Database.query(
      query,
      AccessLevel.SYSTEM_MODE
    );
    Boolean capped = candidates.size() >= CAP;

    Set<Id> cronIds = new Set<Id>();
    Set<Id> asyncIds = new Set<Id>();
    Set<Id> pageIds = new Set<Id>();
    for (Workflow_Instance__c inst : candidates) {
      pageIds.add(inst.Id);
      collectJobId(inst.Async_Job_Id__c, cronIds, asyncIds);
    }

    Set<Id> activeCronIds = queryActiveCronIds(cronIds);
    Set<Id> activeAsyncIds = queryActiveAsyncIds(asyncIds);
    Set<Id> instancesWithStepTimeout = queryInstancesWithStepTimeout(pageIds);

    Long nowMs = Datetime.now().getTime();
    Integer count = 0;
    for (Workflow_Instance__c inst : candidates) {
      String waitingOn = computeWaitingOn(inst, activeCronIds, activeAsyncIds);
      Long idleMinutes = Math.max(
        0L,
        (nowMs - inst.LastModifiedDate.getTime()) / 60000L
      );
      if (
        computeStalled(
          inst,
          waitingOn,
          instancesWithStepTimeout,
          idleMinutes,
          threshold
        )
      ) {
        count++;
      }
    }

    return new Map<String, Object>{ 'count' => count, 'capped' => capped };
  }

  // ── Private helpers shared by getFilteredInstances / getStalledInstances / getStalledCount ──

  private static void collectJobId(
    String jobIdStr,
    Set<Id> cronIds,
    Set<Id> asyncIds
  ) {
    if (String.isBlank(jobIdStr)) {
      return;
    }
    if (
      (jobIdStr.length() == 15 || jobIdStr.length() == 18) &&
      (jobIdStr.startsWith('08e') || jobIdStr.startsWith('707'))
    ) {
      try {
        Id jobId = (Id) jobIdStr;
        if (jobId.getSobjectType() == CronTrigger.SObjectType) {
          cronIds.add(jobId);
        } else if (jobId.getSobjectType() == AsyncApexJob.SObjectType) {
          asyncIds.add(jobId);
        }
      } catch (Exception ex) {
        System.debug(
          LoggingLevel.WARN,
          'Failed to cast Async Job ID: ' +
            jobIdStr +
            ', error: ' +
            ex.getMessage()
        );
      }
    } else {
      System.debug(
        LoggingLevel.WARN,
        'Invalid Async Job ID format: ' + jobIdStr
      );
    }
  }

  private static Set<Id> queryActiveCronIds(Set<Id> cronIds) {
    Set<Id> result = new Set<Id>();
    if (cronIds.isEmpty()) {
      return result;
    }
    for (CronTrigger ct : [
      SELECT Id
      FROM CronTrigger
      WHERE
        Id IN :cronIds
        AND State IN ('WAITING', 'ACQUIRED', 'QUEUED', 'EXECUTING')
      WITH SYSTEM_MODE
    ]) {
      result.add(ct.Id);
    }
    return result;
  }

  private static Set<Id> queryActiveAsyncIds(Set<Id> asyncIds) {
    Set<Id> result = new Set<Id>();
    if (asyncIds.isEmpty()) {
      return result;
    }
    for (AsyncApexJob aaj : [
      SELECT Id
      FROM AsyncApexJob
      WHERE
        Id IN :asyncIds
        AND Status IN ('Queued', 'Holding', 'Preparing', 'Processing')
      WITH SYSTEM_MODE
    ]) {
      result.add(aaj.Id);
    }
    return result;
  }

  private static Set<Id> queryInstancesWithStepTimeout(Set<Id> instanceIds) {
    Set<Id> result = new Set<Id>();
    if (instanceIds.isEmpty()) {
      return result;
    }
    for (Workflow_Step_Execution__c se : [
      SELECT Workflow_Instance__c
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c IN :instanceIds AND Timeout_At__c != NULL
      WITH SYSTEM_MODE
    ]) {
      result.add(se.Workflow_Instance__c);
    }
    return result;
  }

  private static String computeWaitingOn(
    Workflow_Instance__c inst,
    Set<Id> activeCronIds,
    Set<Id> activeAsyncIds
  ) {
    if (inst.Status__c != 'Suspended') {
      return null;
    }
    if (String.isNotBlank(inst.Async_Job_Id__c)) {
      String jobIdStr = inst.Async_Job_Id__c;
      if (
        (jobIdStr.length() == 15 || jobIdStr.length() == 18) &&
        (jobIdStr.startsWith('08e') || jobIdStr.startsWith('707'))
      ) {
        try {
          Id jobId = (Id) jobIdStr;
          if (
            jobId.getSobjectType() == CronTrigger.SObjectType &&
            activeCronIds.contains(jobId)
          ) {
            return 'Scheduled Job';
          } else if (
            jobId.getSobjectType() == AsyncApexJob.SObjectType &&
            activeAsyncIds.contains(jobId)
          ) {
            return 'Delayed Queueable';
          } else {
            return 'Watchdog';
          }
        } catch (Exception ex) {
          System.debug(
            LoggingLevel.WARN,
            'Failed to cast Async Job ID: ' +
              jobIdStr +
              ', error: ' +
              ex.getMessage()
          );
          return 'Watchdog';
        }
      } else {
        System.debug(
          LoggingLevel.WARN,
          'Invalid Async Job ID format: ' + jobIdStr
        );
        return 'Watchdog';
      }
    } else if (inst.Sleep_Until__c != null) {
      return 'Watchdog';
    }
    return null;
  }

  private static Boolean computeStalled(
    Workflow_Instance__c inst,
    String waitingOn,
    Set<Id> instancesWithStepTimeout,
    Long idleMinutes,
    Integer thresholdMinutes
  ) {
    if (inst.Status__c != 'Suspended') {
      return false;
    }
    if (waitingOn == 'Scheduled Job' || waitingOn == 'Delayed Queueable') {
      return false;
    }
    if (inst.Sleep_Until__c != null) {
      return false;
    }
    if (instancesWithStepTimeout.contains(inst.Id)) {
      return false;
    }
    return idleMinutes > thresholdMinutes;
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
        stat == 'CompensationFailed' ||
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
    if (instanceId == null) {
      AuraHandledException ex = new AuraHandledException(
        'instanceId is required.'
      );
      ex.setMessage('instanceId is required.');
      throw ex;
    }
    List<Workflow_Instance__c> instanceList = [
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
        Sleep_Until__c,
        Compensation_Stack__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
      WITH SYSTEM_MODE
      LIMIT 1
    ];
    if (instanceList.isEmpty()) {
      AuraHandledException ex = new AuraHandledException(
        'Workflow instance not found: ' + instanceId
      );
      ex.setMessage('Workflow instance not found: ' + instanceId);
      throw ex;
    }
    Workflow_Instance__c instance = instanceList[0];

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
    Map<String, Object> payloadFiles = resolvePayloadsInBulk(instance, steps);

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
        if (
          (jobIdStr.length() == 15 || jobIdStr.length() == 18) &&
          (jobIdStr.startsWith('08e') || jobIdStr.startsWith('707'))
        ) {
          try {
            Id jobId = (Id) jobIdStr;
            if (jobId.getSobjectType() == CronTrigger.SObjectType) {
              List<CronTrigger> cronJobs = [
                SELECT Id
                FROM CronTrigger
                WHERE
                  Id = :jobId
                  AND State IN ('WAITING', 'ACQUIRED', 'QUEUED', 'EXECUTING')
                WITH SYSTEM_MODE
                LIMIT 1
              ];
              if (!cronJobs.isEmpty()) {
                waitingOn = 'Scheduled Job';
              } else {
                waitingOn = 'Watchdog';
              }
            } else if (jobId.getSobjectType() == AsyncApexJob.SObjectType) {
              List<AsyncApexJob> asyncJobs = [
                SELECT Id
                FROM AsyncApexJob
                WHERE
                  Id = :jobId
                  AND Status IN ('Queued', 'Holding', 'Preparing', 'Processing')
                WITH SYSTEM_MODE
                LIMIT 1
              ];
              if (!asyncJobs.isEmpty()) {
                waitingOn = 'Delayed Queueable';
              } else {
                waitingOn = 'Watchdog';
              }
            }
          } catch (Exception ex) {
            System.debug(
              LoggingLevel.WARN,
              'Failed to cast Async Job ID: ' +
                jobIdStr +
                ', error: ' +
                ex.getMessage()
            );
            waitingOn = 'Watchdog';
          }
        } else {
          System.debug(
            LoggingLevel.WARN,
            'Invalid Async Job ID format: ' + jobIdStr
          );
          waitingOn = 'Watchdog';
        }
      } else if (instance.Sleep_Until__c != null) {
        waitingOn = 'Watchdog';
      }
    }

    // Derive the un-run remainder of the LIFO compensation stack so a stalled
    // ("rollback incomplete") saga can show, at a glance, how many and which forward
    // steps still have un-reversed side effects — no manual JSON inspection required.
    // The stack is presented top-of-stack first (next to be compensated).
    List<String> pendingCompensations = new List<String>();
    if (String.isNotBlank(instance.Compensation_Stack__c)) {
      try {
        List<String> stack = (List<String>) JSON.deserialize(
          instance.Compensation_Stack__c,
          List<String>.class
        );
        for (Integer i = stack.size() - 1; i >= 0; i--) {
          pendingCompensations.add(stack[i]);
        }
      } catch (Exception ex) {
        System.debug(
          LoggingLevel.WARN,
          'Failed to parse Compensation_Stack__c: ' + ex.getMessage()
        );
      }
    }

    return new Map<String, Object>{
      'instance' => instance,
      'steps' => steps,
      'children' => children,
      'successor' => successors.isEmpty() ? null : successors[0],
      'waitingOn' => waitingOn,
      'pendingCompensationCount' => pendingCompensations.size(),
      'pendingCompensations' => pendingCompensations,
      'payloadFiles' => payloadFiles
    };
  }

  /**
   * Raised internally when the precise source-scan strategy approaches a governor
   * limit. It is thrown *before* the (uncatchable) platform LimitException would fire,
   * so the caller can degrade gracefully to the lightweight ApexTypeImplementor index.
   */
  @TestVisible
  private class DefinitionScanLimitException extends Exception {
  }

  // When the running transaction reaches this fraction of its heap or CPU budget while
  // scanning Apex source, abandon the source scan and fall back to ApexTypeImplementor.
  @TestVisible
  private static Decimal definitionScanGuardFraction = 0.7;
  // Forces the fallback path in tests (an empty org has no classes to scan otherwise).
  @TestVisible
  private static Boolean forceDefinitionFallback = false;

  @AuraEnabled(cacheable=true)
  public static List<String> getDefinitions() {
    checkAuthorization();
    // Primary strategy: scan Apex source so we can detect *inner-class* definitions
    // (reported as "Outer.Inner"), which the platform index cannot express. This is
    // governor-bounded by the proactive guards inside getDefinitionsFromSource().
    //
    // Fallback strategy: on very large orgs the source scan can exhaust heap or CPU.
    // Governor LimitExceptions are uncatchable in Apex, so we cannot react to them;
    // instead we monitor Limits.* and bail to the cheap ApexTypeImplementor index.
    //
    // KNOWN TRADE-OFF: the fallback queries the platform's compiled-type index rather
    // than raw source. Verified behavior (API 67): it DOES surface inner-class
    // definitions with qualified "Outer.Inner" names and resolves transitive interface
    // inheritance, so for *startable* definitions it is at least as complete as the
    // regex. The differences are (a) it lists only concrete (IsConcrete = true) types,
    // so non-instantiable abstract/virtual definition classes are omitted — acceptable,
    // since those cannot be started anyway; and (b) it reflects the compiled index, a
    // separate source of truth that is normally current but updates on class compile.
    try {
      if (forceDefinitionFallback) {
        throw new DefinitionScanLimitException('Forced fallback (test).');
      }
      return getDefinitionsFromSource();
    } catch (DefinitionScanLimitException ex) {
      System.debug(
        LoggingLevel.WARN,
        'getDefinitions: source scan hit governor guard, falling back to ' +
          'ApexTypeImplementor (inner-class definitions will be omitted): ' +
          ex.getMessage()
      );
      return getDefinitionsFromTypeIndex();
    }
  }

  /**
   * Precise discovery via Apex source regex. Uses a SOQL for-loop so only ~200 class
   * bodies are resident in heap at a time, and proactively aborts (throwing
   * DefinitionScanLimitException) before crossing the heap/CPU governor limits.
   */
  private static List<String> getDefinitionsFromSource() {
    List<String> definitions = new List<String>();
    Pattern classPattern = Pattern.compile(
      '(?i)\\bclass\\s+([a-zA-Z0-9_]+)\\s+[^\\{]*?\\bimplements\\s+[^\\{]*?\\b(WorkflowDefinition|VersionedWorkflow)\\b'
    );

    Long heapGuard = (Long) (Limits.getLimitHeapSize() *
    definitionScanGuardFraction);
    Integer cpuGuard = (Integer) (Limits.getLimitCpuTime() *
    definitionScanGuardFraction);

    // SOQL for-loop retrieves records in chunks of 200, bounding resident heap so a
    // large org's class bodies are not all materialized at once.
    for (ApexClass ac : [
      SELECT Name, Body
      FROM ApexClass
      WHERE NamespacePrefix = NULL
      WITH SYSTEM_MODE
      ORDER BY Name ASC
    ]) {
      if (Limits.getHeapSize() > heapGuard || Limits.getCpuTime() > cpuGuard) {
        throw new DefinitionScanLimitException(
          'Heap/CPU guard tripped during Apex source scan.'
        );
      }
      if (ac.Body == null) {
        continue;
      }
      // Skip @isTest classes (any class whose body carries the annotation) and
      // system-only workflows that must not be launched from the dashboard.
      if (
        ac.Body.toLowerCase().contains('@istest') ||
        ac.Name.equalsIgnoreCase('BulkRedriveWorkflow')
      ) {
        continue;
      }
      Matcher pm = classPattern.matcher(ac.Body);
      while (pm.find()) {
        String className = pm.group(1);
        // Outer class match returns the bare name; inner class is qualified.
        definitions.add(
          className.equalsIgnoreCase(ac.Name)
            ? ac.Name
            : ac.Name + '.' + className
        );
      }
    }
    definitions.sort();
    return definitions;
  }

  /**
   * Degraded-mode discovery via the platform's compiled-type index. Heap/CPU cheap.
   * Includes inner classes (qualified "Outer.Inner") and transitive interface
   * inheritance, but lists only concrete (IsConcrete = true) implementing classes.
   */
  private static List<String> getDefinitionsFromTypeIndex() {
    Set<String> definitions = new Set<String>();
    for (ApexTypeImplementor impl : [
      SELECT ClassName
      FROM ApexTypeImplementor
      WHERE
        InterfaceName IN ('WorkflowDefinition', 'VersionedWorkflow')
        AND ClassNamespacePrefix = NULL
        AND IsConcrete = TRUE
      WITH SYSTEM_MODE
    ]) {
      String className = impl.ClassName;
      if (String.isBlank(className)) {
        continue;
      }
      // By convention all test classes end with 'Test'. Extract the outer class
      // name (before '.' for inner classes) to catch inners of test classes too.
      // Also exclude system-only workflows not meant to be launched from the UI.
      String outerClass = className.contains('.')
        ? className.substringBefore('.')
        : className;
      if (
        outerClass.toLowerCase().endsWith('test') ||
        className.equalsIgnoreCase('BulkRedriveWorkflow')
      ) {
        continue;
      }
      definitions.add(className);
    }
    List<String> sorted = new List<String>(definitions);
    sorted.sort();
    return sorted;
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
        try {
          input = JSON.deserializeUntyped(inputJson);
        } catch (System.JSONException je) {
          AuraHandledException ex = new AuraHandledException(
            'Input Payload is not valid JSON: ' + je.getMessage()
          );
          ex.setMessage('Input Payload is not valid JSON: ' + je.getMessage());
          throw ex;
        }
      }
      return WorkflowEngine.start(workflowName, correlationKey, input);
    } catch (AuraHandledException ahe) {
      throw ahe;
    } catch (Exception ex) {
      System.debug(
        LoggingLevel.ERROR,
        'Aura startWorkflow failed: ' +
          ex.getMessage() +
          '\n' +
          ex.getStackTraceString()
      );
      AuraHandledException ahe = new AuraHandledException(ex.getMessage());
      ahe.setMessage(ex.getMessage());
      throw ahe;
    }
  }

  @AuraEnabled
  public static void retryWorkflowInstance(Id instanceId) {
    checkAuthorization();
    try {
      WorkflowEngine.retryWorkflow(instanceId);
    } catch (Exception ex) {
      System.debug(
        LoggingLevel.ERROR,
        'Aura retryWorkflowInstance failed: ' +
          ex.getMessage() +
          '\n' +
          ex.getStackTraceString()
      );
      throw new AuraHandledException(ex.getMessage());
    }
  }

  /**
   * Exact count of failed instances that a "Re-drive matching" action would
   * re-enqueue for the operator's CURRENT filter. Shown in the confirmation
   * prompt before anything is enqueued. Uses the same selection surface
   * (workflowName / status / searchTerm) as getFilteredInstances, restricted to
   * the operator-recoverable terminal set and excluding the re-driver itself.
   */
  @AuraEnabled
  public static Integer getRedriveEligibleCount(
    String workflowName,
    String status,
    String searchTerm
  ) {
    checkAuthorization();
    try {
      return BulkRedriveWorkflow.countEligible(
        workflowName,
        status,
        searchTerm
      );
    } catch (Exception ex) {
      System.debug(
        LoggingLevel.ERROR,
        'Aura getRedriveEligibleCount failed: ' +
          ex.getMessage() +
          '\n' +
          ex.getStackTraceString()
      );
      throw new AuraHandledException(ex.getMessage());
    }
  }

  /**
   * Re-drives every failed instance matching the operator's current filter in a
   * single bounded action. The actual re-drive runs asynchronously as a
   * BulkRedriveWorkflow instance, which pages over the selection in safe-sized
   * chunks (so the platform async-enqueue budget is never exceeded) and recovers
   * each instance through the existing WorkflowEngine.retryWorkflow primitive.
   *
   * Returns { started, eligibleCount, redriveInstanceId } so the dashboard can
   * confirm the launch and link the operator to the re-driver for live progress.
   */
  @AuraEnabled
  public static Map<String, Object> redriveMatchingInstances(
    String workflowName,
    String status,
    String searchTerm
  ) {
    checkAuthorization();
    try {
      Integer eligibleCount = BulkRedriveWorkflow.countEligible(
        workflowName,
        status,
        searchTerm
      );
      if (eligibleCount == 0) {
        return new Map<String, Object>{
          'started' => false,
          'eligibleCount' => 0,
          'redriveInstanceId' => null
        };
      }

      Map<String, Object> filter = new Map<String, Object>{
        'workflowName' => workflowName,
        'status' => status,
        'searchTerm' => searchTerm
      };
      String correlationKey =
        'BulkRedrive_' +
        DateTime.now().getTime() +
        '_' +
        Math.abs(Crypto.getRandomLong());
      Id redriveInstanceId = WorkflowEngine.start(
        BulkRedriveWorkflow.REDRIVER_WORKFLOW_NAME,
        correlationKey,
        filter
      );

      return new Map<String, Object>{
        'started' => true,
        'eligibleCount' => eligibleCount,
        'redriveInstanceId' => redriveInstanceId
      };
    } catch (Exception ex) {
      System.debug(
        LoggingLevel.ERROR,
        'Aura redriveMatchingInstances failed: ' +
          ex.getMessage() +
          '\n' +
          ex.getStackTraceString()
      );
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
      System.debug(
        LoggingLevel.ERROR,
        'Aura resumeWorkflowInstance failed: ' +
          ex.getMessage() +
          '\n' +
          ex.getStackTraceString()
      );
      throw new AuraHandledException(ex.getMessage());
    }
  }

  /**
   * Operator action to resume a stalled saga rollback (status CompensationFailed)
   * from exactly the failed compensation point. Idempotent: a repeated/overlapping
   * call after the rollback has already resumed is a safe no-op in the engine.
   */
  @AuraEnabled
  public static void resumeCompensationInstance(Id instanceId) {
    checkAuthorization();
    try {
      WorkflowEngine.resumeCompensation(instanceId);
    } catch (Exception ex) {
      System.debug(
        LoggingLevel.ERROR,
        'Aura resumeCompensationInstance failed: ' +
          ex.getMessage() +
          '\n' +
          ex.getStackTraceString()
      );
      throw new AuraHandledException(ex.getMessage());
    }
  }

  @AuraEnabled
  public static void cancelWorkflow(Id instanceId, Boolean runCompensations) {
    checkAuthorization();
    try {
      WorkflowEngine.cancel(instanceId, runCompensations);
    } catch (Exception ex) {
      System.debug(
        LoggingLevel.ERROR,
        'Aura cancelWorkflow failed: ' +
          ex.getMessage() +
          '\n' +
          ex.getStackTraceString()
      );
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
    // Enforce the approval gate's designated role BEFORE recording the decision, so a
    // dashboard admin cannot approve a gate they were not assigned to. Thrown before the
    // try/catch below so the specific message is not flattened into a generic one.
    enforceApprovalRole(instanceId, approvalKey);
    try {
      Map<String, Object> payload = new Map<String, Object>{
        'approved' => approved,
        'comments' => comments,
        // Record the immutable User Id (and username) as the authoritative approver
        // identity for the audit trail; the display name alone is mutable and not unique.
        'approverId' => UserInfo.getUserId(),
        'approverUsername' => UserInfo.getUserName(),
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
      System.debug(
        LoggingLevel.ERROR,
        'Aura submitApproval failed: ' +
          ex.getMessage() +
          '\n' +
          ex.getStackTraceString()
      );
      throw new AuraHandledException(ex.getMessage());
    }
  }

  /**
   * If the instance has a pending approval gate for the given key that designates an
   * approvalRole, require the running user to hold a custom permission of that API name
   * (or "Modify All Data" as a break-glass override). Gates with no role, or no matching
   * pending gate, impose no additional restriction beyond checkAuthorization().
   */
  private static void enforceApprovalRole(Id instanceId, String approvalKey) {
    if (instanceId == null) {
      return;
    }
    String requiredRole = null;
    Boolean gateFound = false;
    for (Workflow_Step_Execution__c se : [
      SELECT Output__c
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c = :instanceId AND Status__c = 'Pending'
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC, Id DESC
      LIMIT 50
    ]) {
      String resolved = WorkflowEngine.resolvePayload(se.Output__c);
      if (
        String.isBlank(resolved) || !resolved.contains('waitingForApproval')
      ) {
        continue;
      }
      try {
        Map<String, Object> state = (Map<String, Object>) JSON.deserializeUntyped(
          resolved
        );
        if (
          state.get('waitingForApproval') == true &&
          approvalKey == (String) state.get('approvalKey')
        ) {
          gateFound = true;
          requiredRole = (String) state.get('approvalRole');
          break;
        }
      } catch (Exception ex) {
        // Malformed/oversized state payload — ignore and keep scanning.
      }
    }

    if (
      gateFound &&
      String.isNotBlank(requiredRole) &&
      !FeatureManagement.checkPermission(requiredRole) &&
      !currentUserHasModifyAllData()
    ) {
      AuraHandledException ex = new AuraHandledException(
        'Unauthorized: this approval requires the "' +
          requiredRole +
          '" permission.'
      );
      ex.setMessage(
        'Unauthorized: this approval requires the "' +
          requiredRole +
          '" permission.'
      );
      throw ex;
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
        WHERE
          Correlation_Key__c = 'SystemWatchdog'
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
      System.debug(
        LoggingLevel.ERROR,
        'Aura getWatchdogStatus failed: ' +
          ex.getMessage() +
          '\n' +
          ex.getStackTraceString()
      );
      throw new AuraHandledException(ex.getMessage());
    }
  }

  @AuraEnabled
  public static void enqueueWatchdog() {
    checkAuthorization();
    try {
      WorkflowWatchdog.bootstrap();
    } catch (Exception ex) {
      System.debug(
        LoggingLevel.ERROR,
        'Aura enqueueWatchdog failed: ' +
          ex.getMessage() +
          '\n' +
          ex.getStackTraceString()
      );
      throw new AuraHandledException(ex.getMessage());
    }
  }
}
