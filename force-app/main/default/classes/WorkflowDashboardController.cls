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

  // Upper bound on Suspended candidate rows a single stalled query/count scans, so a
  // large backlog of long-suspended instances cannot exhaust governor limits. The list
  // filters then paginates within this bound; the count reports `capped` when hit.
  private static final Integer STALLED_CANDIDATE_CAP = 2000;

  // Statuses that mean an instance still needs its definition-version code deployed.
  // CompensationFailed is included because such instances can still be Resume-Rollback'd.
  private static final Set<String> NON_TERMINAL_STATUSES = new Set<String>{
    'Pending',
    'Running',
    'Suspended',
    'Compensating',
    'Cancelling',
    'CompensationFailed',
    'Paused'
  };

  // Terminal statuses that are nonetheless re-drivable on their original version
  // (Retry/Re-drive replays the run on the same Definition_Version__c). Reported as
  // a distinct count by getVersionDrain so retiring a version's code never silently
  // breaks a still-recoverable failed run.
  private static final Set<String> RECOVERABLE_TERMINAL_STATUSES = new Set<String>{
    'Failed'
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

    Id instProgressId = getAttachmentId(instance.Progress__c);
    if (instProgressId != null)
      attachmentIds.add(instProgressId);

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
    instance.Progress__c = resolveAndRecordPayload(
      instance.Progress__c,
      'instance.Progress',
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
    return buildWhereClause(workflowName, status, searchTerm, null);
  }

  private static String buildWhereClause(
    String workflowName,
    String status,
    String searchTerm,
    String failureCategory
  ) {
    List<String> conditions = new List<String>();
    if (String.isNotBlank(workflowName)) {
      conditions.add('Workflow_Name__c = :workflowName');
    }
    if (String.isNotBlank(status)) {
      conditions.add('Status__c = :status');
    }
    if (String.isNotBlank(failureCategory)) {
      conditions.add('Failure_Category__c = :failureCategory');
    }
    if (String.isNotBlank(searchTerm)) {
      likeTerm = '%' + searchTerm + '%';
      conditions.add(
        '(Name LIKE :likeTerm OR Correlation_Key__c LIKE :likeTerm OR Workflow_Name__c LIKE :likeTerm OR Error_Message__c LIKE :likeTerm)'
      );
    }
    return conditions.isEmpty()
      ? ''
      : ' WHERE ' + String.join(conditions, ' AND ');
  }

  // Shared WHERE body (no leading "WHERE") for the stalled list and count. Selects
  // Suspended instances idle beyond the cutoff with no sleep timer, no declared step
  // timeout, and no pending step (signal/approval/child waits park exactly one Pending
  // step-exec row; excluding those avoids false-positives on legitimate waits). The
  // remaining "no active job" check is applied in Apex by the caller since job liveness
  // cannot be expressed in SOQL. Requires the `stalledCutoff` binding to be set by the
  // caller before query execution.
  private static String buildStalledWhereClause(
    String workflowName,
    String searchTerm
  ) {
    List<String> conditions = new List<String>{
      'Status__c = \'Suspended\'',
      'Sleep_Until__c = null',
      'LastModifiedDate <= :stalledCutoff',
      'Id NOT IN (SELECT Workflow_Instance__c FROM Workflow_Step_Execution__c WHERE Timeout_At__c != null)',
      'Id NOT IN (SELECT Workflow_Instance__c FROM Workflow_Step_Execution__c WHERE Status__c = \'Pending\')'
    };
    if (String.isNotBlank(workflowName)) {
      conditions.add('Workflow_Name__c = :workflowName');
    }
    if (String.isNotBlank(searchTerm)) {
      likeTerm = '%' + searchTerm + '%';
      conditions.add(
        '(Name LIKE :likeTerm OR Correlation_Key__c LIKE :likeTerm OR Workflow_Name__c LIKE :likeTerm OR Error_Message__c LIKE :likeTerm)'
      );
    }
    return String.join(conditions, ' AND ');
  }

  public static List<Map<String, Object>> getFilteredInstances(
    String workflowName,
    String status,
    String searchTerm,
    Integer limitSize,
    Integer offsetSize,
    String cacheBuster
  ) {
    return getFilteredInstances(
      workflowName,
      status,
      searchTerm,
      null,
      limitSize,
      offsetSize,
      cacheBuster
    );
  }

  @AuraEnabled(cacheable=true)
  public static List<Map<String, Object>> getFilteredInstances(
    String workflowName,
    String status,
    String searchTerm,
    String failureCategory,
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
      'SELECT Id, Name, Workflow_Name__c, Status__c, Correlation_Key__c, CreatedDate, LastModifiedDate, Error_Message__c, Async_Job_Id__c, Sleep_Until__c, Deadline_At__c, Failure_Category__c ' +
      'FROM Workflow_Instance__c' +
      buildWhereClause(workflowName, status, searchTerm, failureCategory);

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
    Set<Id> instancesWithPendingStep = queryInstancesWithPendingStep(pageIds);

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
        instancesWithPendingStep,
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
        'Deadline_At__c' => inst.Deadline_At__c,
        'Failure_Category__c' => inst.Failure_Category__c,
        'waitingOn' => waitingOn,
        'idleMinutes' => idleMinutes,
        'stalled' => stalled
      };
      results.add(m);
    }
    return results;
  }

  // cacheBuster is unused in Apex; it only varies the client-side cache key so a
  // dashboard refresh re-queries instead of serving a stale cached list (mirrors
  // getFilteredInstances).
  @AuraEnabled(cacheable=true)
  public static List<Map<String, Object>> getStalledInstances(
    String workflowName,
    String searchTerm,
    Integer thresholdMinutes,
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
    }

    Integer threshold = (thresholdMinutes == null)
      ? WorkflowEngine.staleThresholdMinutes
      : thresholdMinutes;
    stalledCutoff = Datetime.now().addMinutes(-threshold);

    String query =
      'SELECT Id, Name, Workflow_Name__c, Status__c, Correlation_Key__c, CreatedDate, LastModifiedDate, Error_Message__c, Async_Job_Id__c, Sleep_Until__c, Deadline_At__c ' +
      'FROM Workflow_Instance__c WHERE ' +
      buildStalledWhereClause(workflowName, searchTerm) +
      ' ORDER BY LastModifiedDate ASC LIMIT :STALLED_CANDIDATE_CAP';

    List<Workflow_Instance__c> candidates = Database.query(
      query,
      AccessLevel.SYSTEM_MODE
    );

    Set<Id> cronIds = new Set<Id>();
    Set<Id> asyncIds = new Set<Id>();
    for (Workflow_Instance__c inst : candidates) {
      collectJobId(inst.Async_Job_Id__c, cronIds, asyncIds);
    }

    Set<Id> activeCronIds = queryActiveCronIds(cronIds);
    Set<Id> activeAsyncIds = queryActiveAsyncIds(asyncIds);
    // Step-timeout and pending-step instances are already excluded by the WHERE clause
    // anti-joins, so pass empty sets to computeStalled.
    Set<Id> noStepTimeout = new Set<Id>();
    Set<Id> noPendingStep = new Set<Id>();

    Long nowMs = Datetime.now().getTime();
    // Filter to genuinely stalled rows FIRST, then paginate, so the in-memory
    // job-liveness filter (which SOQL cannot express) never returns a short page
    // that would make the LWC stop paging before later stalled rows are reached.
    List<Map<String, Object>> stalledRows = new List<Map<String, Object>>();
    for (Workflow_Instance__c inst : candidates) {
      String waitingOn = computeWaitingOn(inst, activeCronIds, activeAsyncIds);
      Long idleMinutes = Math.max(
        0L,
        (nowMs - inst.LastModifiedDate.getTime()) / 60000L
      );
      if (
        !computeStalled(
          inst,
          waitingOn,
          noStepTimeout,
          noPendingStep,
          idleMinutes,
          threshold
        )
      ) {
        continue;
      }
      stalledRows.add(
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
          'Deadline_At__c' => inst.Deadline_At__c,
          'waitingOn' => waitingOn,
          'idleMinutes' => idleMinutes,
          'stalled' => true
        }
      );
    }

    List<Map<String, Object>> results = new List<Map<String, Object>>();
    for (
      Integer i = offsetSize;
      i < stalledRows.size() &&
      results.size() < limitSize;
      i++
    ) {
      results.add(stalledRows[i]);
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

    String query =
      'SELECT Id, Async_Job_Id__c, Sleep_Until__c, Status__c, LastModifiedDate ' +
      'FROM Workflow_Instance__c WHERE ' +
      buildStalledWhereClause(workflowName, searchTerm) +
      ' LIMIT :STALLED_CANDIDATE_CAP';

    List<Workflow_Instance__c> candidates = Database.query(
      query,
      AccessLevel.SYSTEM_MODE
    );
    Boolean capped = candidates.size() >= STALLED_CANDIDATE_CAP;

    Set<Id> cronIds = new Set<Id>();
    Set<Id> asyncIds = new Set<Id>();
    for (Workflow_Instance__c inst : candidates) {
      collectJobId(inst.Async_Job_Id__c, cronIds, asyncIds);
    }

    Set<Id> activeCronIds = queryActiveCronIds(cronIds);
    Set<Id> activeAsyncIds = queryActiveAsyncIds(asyncIds);
    // Step-timeout and pending-step instances are excluded by the WHERE clause anti-joins.
    Set<Id> noStepTimeout = new Set<Id>();
    Set<Id> noPendingStep = new Set<Id>();

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
          noStepTimeout,
          noPendingStep,
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

  private static Set<Id> queryInstancesWithPendingStep(Set<Id> instanceIds) {
    Set<Id> result = new Set<Id>();
    if (instanceIds.isEmpty()) {
      return result;
    }
    for (Workflow_Step_Execution__c se : [
      SELECT Workflow_Instance__c
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c IN :instanceIds AND Status__c = 'Pending'
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
    Set<Id> instancesWithPendingStep,
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
    // Signal/approval/child-completion waits park a Pending step-exec row;
    // exclude them so only true orphans (no resume mechanism at all) are flagged.
    if (instancesWithPendingStep.contains(inst.Id)) {
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
        stat == 'Cancelling' ||
        stat == 'Paused'
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

  // Selectable trend windows for getDefinitionTrends, mapped to a span in hours.
  // Blank/unrecognized keys fall back to TREND_DEFAULT_WINDOW.
  private static final Map<String, Integer> TREND_WINDOW_HOURS = new Map<String, Integer>{
    '1h' => 1,
    '24h' => 24,
    '7d' => 168
  };
  private static final String TREND_DEFAULT_WINDOW = '24h';

  // Terminal statuses classified as a successful outcome by getDefinitionTrends.
  // CompensationFailed is intentionally absent from FAILURE_STATUSES: it is a
  // non-terminal status (WorkflowInstanceTrigger never stamps Terminal_At__c for
  // it), so the windowed query can never surface such instances. getWorkflowStats'
  // snapshot "failed" bucket does include CompensationFailed because it queries
  // all instances without a Terminal_At__c filter.
  private static final Set<String> SUCCESS_STATUSES = new Set<String>{
    'Completed',
    'ContinuedAsNew'
  };
  private static final Set<String> FAILURE_STATUSES = new Set<String>{
    'Failed',
    'Compensated',
    'Cancelled'
  };

  /**
   * Per-definition success-rate and throughput over a selectable recent window.
   *
   * Answers "is this workflow definition healthier or sicker than it was an hour
   * ago?". The window is computed against Terminal_At__c (not CreatedDate) so a
   * long-running instance that *finished* inside the window is counted in that
   * window. Uses a single GROUP BY aggregate — no per-instance rows are
   * materialized into heap.
   *
   * Governor note: Salesforce counts the underlying rows scanned by an aggregate
   * query toward the 50,000 synchronous query-row limit. On orgs with >50k
   * terminal instances in the selected window the query will throw LimitException.
   * Move to an async context if governor pressure is observed in practice.
   *
   * @param windowKey one of '1h' | '24h' | '7d' (blank/unknown → 24h)
   * @return Map with 'windowKey', 'windowHours', and 'rows' — a List<Map<String,Object>>
   *         (one row per Workflow_Name__c with terminal activity in the window),
   *         sorted worst-first (highest failure count). Empty 'rows' when nothing
   *         terminated in the window.
   */
  @AuraEnabled
  public static Map<String, Object> getDefinitionTrends(String windowKey) {
    checkAuthorization();

    String resolvedKey = TREND_WINDOW_HOURS.containsKey(windowKey)
      ? windowKey
      : TREND_DEFAULT_WINDOW;
    Integer windowHours = TREND_WINDOW_HOURS.get(resolvedKey);
    Datetime since = Datetime.now().addHours(-windowHours);

    // Aggregate by definition + status. The Terminal_At__c predicate restricts to
    // terminal instances (active instances have a null Terminal_At__c), so every
    // returned row is already a terminal outcome to be bucketed.
    Map<String, WorkflowTrendAggregate> byDefinition = new Map<String, WorkflowTrendAggregate>();
    for (AggregateResult ar : [
      SELECT Workflow_Name__c, Status__c, COUNT(Id) cnt
      FROM Workflow_Instance__c
      WHERE Terminal_At__c >= :since
      WITH SYSTEM_MODE
      GROUP BY Workflow_Name__c, Status__c
    ]) {
      String name = (String) ar.get('Workflow_Name__c');
      String stat = (String) ar.get('Status__c');
      Integer count = (Integer) ar.get('cnt');

      WorkflowTrendAggregate agg = byDefinition.get(name);
      if (agg == null) {
        agg = new WorkflowTrendAggregate(name);
        byDefinition.put(name, agg);
      }
      if (SUCCESS_STATUSES.contains(stat)) {
        agg.successCount += count;
      } else if (FAILURE_STATUSES.contains(stat)) {
        agg.failureCount += count;
      }
    }

    List<WorkflowTrendAggregate> aggregates = byDefinition.values();
    aggregates.sort(); // worst-first (highest failure count, then name)

    List<Map<String, Object>> rows = new List<Map<String, Object>>();
    for (WorkflowTrendAggregate agg : aggregates) {
      rows.add(agg.toRow(windowHours));
    }

    return new Map<String, Object>{
      'windowKey' => resolvedKey,
      'windowHours' => windowHours,
      'rows' => rows
    };
  }

  /**
   * Accumulates per-definition success/failure terminal counts for getDefinitionTrends
   * and renders the display row. Comparable so the panel surfaces the sickest
   * definition first (highest failure count, ties broken by name).
   */
  private class WorkflowTrendAggregate implements Comparable {
    String workflowName;
    Integer successCount = 0;
    Integer failureCount = 0;

    WorkflowTrendAggregate(String workflowName) {
      this.workflowName = workflowName;
    }

    Integer terminalCount() {
      return successCount + failureCount;
    }

    Map<String, Object> toRow(Integer windowHours) {
      Integer terminal = terminalCount();
      // terminal is always >= 1 for a row that exists, but guard anyway so the
      // contract is divide-by-zero-safe for any caller.
      Decimal successRate = terminal == 0
        ? null
        : (Decimal.valueOf(successCount) * 100)
            .divide(terminal, 1, System.RoundingMode.HALF_UP);
      Decimal throughputPerHour = windowHours == 0
        ? null
        : Decimal.valueOf(terminal)
            .divide(windowHours, 2, System.RoundingMode.HALF_UP);
      return new Map<String, Object>{
        'workflowName' => workflowName,
        'terminalCount' => terminal,
        'successCount' => successCount,
        'failureCount' => failureCount,
        'successRate' => successRate,
        'throughputPerHour' => throughputPerHour
      };
    }

    public Integer compareTo(Object other) {
      WorkflowTrendAggregate that = (WorkflowTrendAggregate) other;
      if (this.failureCount != that.failureCount) {
        return that.failureCount - this.failureCount; // higher failures first
      }
      return this.workflowName.compareTo(that.workflowName);
    }
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
        Compensated_By__c,
        Compensated_By__r.Name,
        Async_Job_Id__c,
        Sleep_Until__c,
        Compensation_Stack__c,
        Deadline_At__c,
        Failure_Category__c,
        Progress__c
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

  // Strips Apex line ('// ...') and block ('/* ... */') comments so the definition
  // scan never reads documentation prose as code. DOTALL (?s) lets a block comment
  // span lines; the line-comment branch stops at the newline. Note: this does not
  // protect '//' or '/*' sequences that live inside string literals, but that is
  // harmless here — a real 'class X implements WorkflowDefinition' is never inside
  // a literal, so stripping can only remove noise, never a genuine definition.
  private static final Pattern COMMENT_PATTERN = Pattern.compile(
    '(?s)/\\*.*?\\*/|//[^\\n]*'
  );

  // Upper bound on a class body we will comment-strip with COMMENT_PATTERN. A
  // single oversized body (e.g. the multi-hundred-KB engine class) can trip an
  // uncatchable "Regex too complicated" LimitException inside replaceAll() before
  // the per-iteration heap/CPU guard can react. Bodies this large are infra
  // classes (engine/controllers), never small WorkflowDefinition holders, so
  // skipping them from the source scan loses no real definitions.
  @TestVisible
  private static Integer maxScannableBodyLength = 100000;

  @AuraEnabled(cacheable=true)
  public static List<String> getDefinitions() {
    checkAuthorization();
    return getDefinitionsUnchecked();
  }

  /**
   * WorkflowDefinition discovery WITHOUT an authorization check. Callers MUST
   * perform their own authorization first. Exists so sibling controllers (e.g.
   * WorkflowScheduleController, gated on a different permission) can reuse the
   * exact discovery logic without tripping this controller's Workflow_Admin gate.
   */
  public static List<String> getDefinitionsUnchecked() {
    return getDefinitionsFromTypeIndex();
  }

  /**
   * Precise discovery via Apex source regex. Uses a SOQL for-loop so only ~200 class
   * bodies are resident in heap at a time, and proactively aborts (throwing
   * DefinitionScanLimitException) before crossing the heap/CPU governor limits.
   */
  // getDefinitionsFromSource and guardsTripped removed to optimize performance and safety.

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
        className.equalsIgnoreCase('BulkRedriveWorkflow') ||
        className.equalsIgnoreCase('BulkCancelWorkflow')
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

  /**
   * Exact count of active/stalled instances that a "Cancel matching" action would
   * cancel/rollback for the operator's CURRENT filter.
   */
  @AuraEnabled
  public static Integer getCancelEligibleCount(
    String workflowName,
    String status,
    String searchTerm
  ) {
    checkAuthorization();
    try {
      return BulkCancelWorkflow.countEligible(workflowName, status, searchTerm);
    } catch (Exception ex) {
      System.debug(
        LoggingLevel.ERROR,
        'Aura getCancelEligibleCount failed: ' +
          ex.getMessage() +
          '\n' +
          ex.getStackTraceString()
      );
      throw new AuraHandledException(ex.getMessage());
    }
  }

  /**
   * Cancels every active or stalled instance matching the operator's current filter
   * in a single bounded action. The actual cancellation runs asynchronously as a
   * BulkCancelWorkflow instance.
   */
  @AuraEnabled
  public static Map<String, Object> cancelMatchingInstances(
    String workflowName,
    String status,
    String searchTerm,
    Boolean runCompensations
  ) {
    checkAuthorization();
    try {
      Integer eligibleCount = BulkCancelWorkflow.countEligible(
        workflowName,
        status,
        searchTerm
      );
      if (eligibleCount == 0) {
        return new Map<String, Object>{
          'started' => false,
          'eligibleCount' => 0,
          'cancelInstanceId' => null
        };
      }

      Map<String, Object> filter = new Map<String, Object>{
        'workflowName' => workflowName,
        'status' => status,
        'searchTerm' => searchTerm,
        'runCompensations' => runCompensations
      };
      String correlationKey =
        'BulkCancel_' +
        DateTime.now().getTime() +
        '_' +
        Math.abs(Crypto.getRandomLong());
      Id cancelInstanceId = WorkflowEngine.start(
        BulkCancelWorkflow.CANCELER_WORKFLOW_NAME,
        correlationKey,
        filter
      );

      return new Map<String, Object>{
        'started' => true,
        'eligibleCount' => eligibleCount,
        'cancelInstanceId' => cancelInstanceId
      };
    } catch (Exception ex) {
      System.debug(
        LoggingLevel.ERROR,
        'Aura cancelMatchingInstances failed: ' +
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
  public static Id compensateWorkflow(Id instanceId) {
    checkAuthorization();
    try {
      return WorkflowEngine.compensate(instanceId);
    } catch (Exception ex) {
      System.debug(
        LoggingLevel.ERROR,
        'Aura compensateWorkflow failed: ' +
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
        String stateKey = (String) state.get('approvalKey');
        if (
          state.get('waitingForApproval') == true &&
          approvalKey != null &&
          approvalKey.equalsIgnoreCase(stateKey)
        ) {
          gateFound = true;
          requiredRole = (String) state.get('approvalRole');
          break;
        }
      } catch (Exception ex) {
        System.debug(
          LoggingLevel.WARN,
          'Malformed or oversized state payload ignored: ' + ex.getMessage()
        );
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

      List<Map<String, Object>> pausedDefs = new List<Map<String, Object>>();
      try {
        pausedDefs = getPausedDefinitions();
      } catch (Exception ex) {
        System.debug(
          LoggingLevel.WARN,
          'getWatchdogStatus: failed to load pausedDefinitions: ' +
          ex.getMessage()
        );
      }

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
        'elasticAsyncLimit' => elasticAsyncLimit,
        'pausedDefinitions' => pausedDefs
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

  /**
   * Returns a per-Definition_Version__c drain view for the given workflow name.
   * Each row carries three buckets — non-terminal (still executing), failed
   * (terminal but re-drivable on this version), and clean terminal — plus a
   * safeToRetire flag that is true only when BOTH the non-terminal and failed
   * counts are 0. Failed runs are surfaced separately rather than folded into
   * either bucket: a transient failure may recover on re-drive (so the version's
   * code is still needed), while a failure caused by the very bug a new version
   * fixes will never recover — the engine cannot tell which, so it reports the
   * count and leaves the retire/re-drive judgement to the operator.
   * Only versions actually observed in Workflow_Instance__c are returned;
   * absence from results is NOT reported as "safe".
   */
  @AuraEnabled
  public static List<Map<String, Object>> getVersionDrain(String workflowName) {
    checkAuthorization();

    if (String.isBlank(workflowName)) {
      return new List<Map<String, Object>>();
    }

    Map<String, Integer> nonTerminalByVersion = new Map<String, Integer>();
    Map<String, Integer> failedByVersion = new Map<String, Integer>();
    Map<String, Integer> terminalByVersion = new Map<String, Integer>();
    Map<String, Integer> versionKeyToInt = new Map<String, Integer>();

    Integer totalCount = [
      SELECT COUNT()
      FROM Workflow_Instance__c
      WHERE Workflow_Name__c = :workflowName
      WITH SYSTEM_MODE
    ];

    if (totalCount <= 40000) {
      for (Workflow_Instance__c inst : [
        SELECT Definition_Version__c, Status__c
        FROM Workflow_Instance__c
        WHERE Workflow_Name__c = :workflowName
        WITH SYSTEM_MODE
      ]) {
        Decimal verDecimal = inst.Definition_Version__c;
        Integer ver = verDecimal == null ? null : verDecimal.intValue();
        String verKey = ver == null ? 'null' : String.valueOf(ver);
        String stat = inst.Status__c;

        if (!nonTerminalByVersion.containsKey(verKey)) {
          nonTerminalByVersion.put(verKey, 0);
          failedByVersion.put(verKey, 0);
          terminalByVersion.put(verKey, 0);
          versionKeyToInt.put(verKey, ver);
        }

        if (NON_TERMINAL_STATUSES.contains(stat)) {
          nonTerminalByVersion.put(verKey, nonTerminalByVersion.get(verKey) + 1);
        } else if (RECOVERABLE_TERMINAL_STATUSES.contains(stat)) {
          failedByVersion.put(verKey, failedByVersion.get(verKey) + 1);
        } else {
          terminalByVersion.put(verKey, terminalByVersion.get(verKey) + 1);
        }
      }
    } else {
      Set<Decimal> versionDecimals = new Set<Decimal>();
      Boolean hasNullVersion = false;

      // Query active/failed runs to extract version numbers
      for (Workflow_Instance__c inst : [
        SELECT Definition_Version__c
        FROM Workflow_Instance__c
        WHERE Workflow_Name__c = :workflowName
          AND Status__c NOT IN ('Completed', 'Cancelled', 'ContinuedAsNew')
        WITH SYSTEM_MODE
        LIMIT 5000
      ]) {
        if (inst.Definition_Version__c != null) {
          versionDecimals.add(inst.Definition_Version__c);
        } else {
          hasNullVersion = true;
        }
      }

      // Query recent runs to find other versions
      for (Workflow_Instance__c inst : [
        SELECT Definition_Version__c
        FROM Workflow_Instance__c
        WHERE Workflow_Name__c = :workflowName
        WITH SYSTEM_MODE
        ORDER BY CreatedDate DESC
        LIMIT 10000
      ]) {
        if (inst.Definition_Version__c != null) {
          versionDecimals.add(inst.Definition_Version__c);
        } else {
          hasNullVersion = true;
        }
      }

      List<Decimal> versionsToQuery = new List<Decimal>(versionDecimals);

      for (Decimal ver : versionsToQuery) {
        Integer verInt = ver == null ? null : ver.intValue();
        String verKey = String.valueOf(verInt);

        nonTerminalByVersion.put(verKey, 0);
        failedByVersion.put(verKey, 0);
        terminalByVersion.put(verKey, 0);
        versionKeyToInt.put(verKey, verInt);

        for (AggregateResult ar : [
          SELECT Status__c, COUNT(Id) cnt
          FROM Workflow_Instance__c
          WHERE Workflow_Name__c = :workflowName
            AND Definition_Version__c = :ver
          WITH SYSTEM_MODE
          GROUP BY Status__c
        ]) {
          String stat = (String) ar.get('Status__c');
          Integer count = (Integer) ar.get('cnt');

          if (NON_TERMINAL_STATUSES.contains(stat)) {
            nonTerminalByVersion.put(verKey, nonTerminalByVersion.get(verKey) + count);
          } else if (RECOVERABLE_TERMINAL_STATUSES.contains(stat)) {
            failedByVersion.put(verKey, failedByVersion.get(verKey) + count);
          } else {
            terminalByVersion.put(verKey, terminalByVersion.get(verKey) + count);
          }
        }
      }

      if (hasNullVersion) {
        String verKey = 'null';
        nonTerminalByVersion.put(verKey, 0);
        failedByVersion.put(verKey, 0);
        terminalByVersion.put(verKey, 0);
        versionKeyToInt.put(verKey, null);

        for (AggregateResult ar : [
          SELECT Status__c, COUNT(Id) cnt
          FROM Workflow_Instance__c
          WHERE Workflow_Name__c = :workflowName
            AND Definition_Version__c = NULL
          WITH SYSTEM_MODE
          GROUP BY Status__c
        ]) {
          String stat = (String) ar.get('Status__c');
          Integer count = (Integer) ar.get('cnt');

          if (NON_TERMINAL_STATUSES.contains(stat)) {
            nonTerminalByVersion.put(verKey, nonTerminalByVersion.get(verKey) + count);
          } else if (RECOVERABLE_TERMINAL_STATUSES.contains(stat)) {
            failedByVersion.put(verKey, failedByVersion.get(verKey) + count);
          } else {
            terminalByVersion.put(verKey, terminalByVersion.get(verKey) + count);
          }
        }
      }
    }

    // Sort version keys numerically (null sorts last)
    List<String> sortedKeys = new List<String>(nonTerminalByVersion.keySet());
    sortedKeys.sort();
    Integer nullKeyIdx = sortedKeys.indexOf('null');
    if (nullKeyIdx != -1) {
      sortedKeys.remove(nullKeyIdx);
      sortedKeys.add('null');
    }

    List<Map<String, Object>> results = new List<Map<String, Object>>();
    for (String verKey : sortedKeys) {
      Integer nonTerminal = nonTerminalByVersion.get(verKey);
      Integer failed = failedByVersion.get(verKey);
      Integer terminal = terminalByVersion.get(verKey);
      results.add(
        new Map<String, Object>{
          'version' => versionKeyToInt.get(verKey),
          'nonTerminalCount' => nonTerminal,
          'failedCount' => failed,
          'terminalCount' => terminal,
          'totalCount' => nonTerminal + failed + terminal,
          'safeToRetire' => nonTerminal == 0 && failed == 0
        }
      );
    }

    return results;
  }

  // ── Unrouted-signal dashboard methods ─────────────────────────────────────

  private static final Integer UNROUTED_CANDIDATE_CAP = 2000;

  @AuraEnabled(cacheable=true)
  public static List<Map<String, Object>> getUnroutedSignals(
    String searchTerm,
    Integer limitSize,
    Integer offsetSize,
    String cacheBuster
  ) {
    checkAuthorization();

    Integer lim = (limitSize == null ||
      limitSize <= 0)
      ? 50
      : Math.min(limitSize, 100);
    Integer off = (offsetSize == null ||
      offsetSize < 0)
      ? 0
      : Math.min(offsetSize, 2000);

    String query =
      'SELECT Id, Correlation_Key__c, Signal_Name__c, CreatedDate ' +
      'FROM Workflow_Signal__c ' +
      'WHERE Status__c = \'Unrouted\'';

    if (String.isNotBlank(searchTerm)) {
      likeTerm = '%' + searchTerm.trim() + '%';
      query += ' AND (Correlation_Key__c LIKE :likeTerm OR Signal_Name__c LIKE :likeTerm)';
    }

    query += ' ORDER BY CreatedDate ASC LIMIT :lim OFFSET :off';

    List<Workflow_Signal__c> rows = Database.query(
      query,
      AccessLevel.SYSTEM_MODE
    );

    Long nowMs = Datetime.now().getTime();
    List<Map<String, Object>> results = new List<Map<String, Object>>();
    for (Workflow_Signal__c sig : rows) {
      Long ageMinutes = Math.max(
        0L,
        (nowMs - sig.CreatedDate.getTime()) / 60000L
      );
      results.add(
        new Map<String, Object>{
          'id' => sig.Id,
          'correlationKey' => sig.Correlation_Key__c,
          'signalName' => sig.Signal_Name__c,
          'createdDate' => sig.CreatedDate,
          'ageMinutes' => ageMinutes
        }
      );
    }
    return results;
  }

  @AuraEnabled
  public static Map<String, Object> getUnroutedSignalCount(String searchTerm) {
    checkAuthorization();

    String query = 'SELECT Id FROM Workflow_Signal__c WHERE Status__c = \'Unrouted\'';

    if (String.isNotBlank(searchTerm)) {
      likeTerm = '%' + searchTerm.trim() + '%';
      query += ' AND (Correlation_Key__c LIKE :likeTerm OR Signal_Name__c LIKE :likeTerm)';
    }

    query += ' LIMIT :UNROUTED_CANDIDATE_CAP';

    List<Workflow_Signal__c> candidates = Database.query(
      query,
      AccessLevel.SYSTEM_MODE
    );
    Boolean capped = candidates.size() >= UNROUTED_CANDIDATE_CAP;

    return new Map<String, Object>{
      'count' => candidates.size(),
      'capped' => capped
    };
  }

  @AuraEnabled
  public static Map<String, Object> redeliverSignal(Id signalId) {
    checkAuthorization();
    Boolean matched = WorkflowEngine.redeliverCapturedSignal(signalId);
    return new Map<String, Object>{ 'matched' => matched };
  }

  /**
   * Pause a workflow definition (or * for org-wide maintenance mode).
   * After calling this, new starts for the definition are parked (Paused) and
   * the chain handoff gate parks in-flight instances instead of executing the
   * next step.
   */
  @AuraEnabled
  public static void pauseDefinition(String workflowName, String reason) {
    checkAuthorization();
    try {
      WorkflowPauseGate.pauseDefinition(workflowName, reason);
    } catch (Exception ex) {
      System.debug(
        LoggingLevel.ERROR,
        'Aura pauseDefinition failed: ' +
          ex.getMessage() +
          '\n' +
          ex.getStackTraceString()
      );
      throw new AuraHandledException(ex.getMessage());
    }
  }

  /**
   * Resume a paused workflow definition (or * for all). All instances currently
   * in Paused status are transitioned back to Running and re-enqueued.
   */
  @AuraEnabled
  public static void resumeDefinition(String workflowName) {
    checkAuthorization();
    try {
      WorkflowPauseGate.resumeDefinition(workflowName);
    } catch (Exception ex) {
      System.debug(
        LoggingLevel.ERROR,
        'Aura resumeDefinition failed: ' +
          ex.getMessage() +
          '\n' +
          ex.getStackTraceString()
      );
      throw new AuraHandledException(ex.getMessage());
    }
  }

  /**
   * Returns a list of currently paused definitions with parked-instance counts.
   * Each entry: { workflowName, reason, pausedAt (CreatedDate), parkedCount }.
   */
  @AuraEnabled
  public static List<Map<String, Object>> getPausedDefinitions() {
    checkAuthorization();
    try {
      List<Workflow_Pause_State__c> pauseRecords = [
        SELECT Workflow_Name__c, Reason__c, CreatedById, CreatedDate
        FROM Workflow_Pause_State__c
        WITH SYSTEM_MODE
        ORDER BY CreatedDate ASC
      ];

      if (pauseRecords.isEmpty()) {
        return new List<Map<String, Object>>();
      }

      // Collect all paused def names (including * which covers everything)
      Set<String> pausedNames = new Set<String>();
      Boolean wildcardPaused = false;
      for (Workflow_Pause_State__c r : pauseRecords) {
        pausedNames.add(r.Workflow_Name__c);
        if (r.Workflow_Name__c == '*') {
          wildcardPaused = true;
        }
      }

      // Count parked instances per definition (or all if wildcard)
      List<AggregateResult> counts;
      if (wildcardPaused) {
        counts = [
          SELECT Workflow_Name__c, COUNT(Id) cnt
          FROM Workflow_Instance__c
          WHERE Status__c = 'Paused'
          WITH SYSTEM_MODE
          GROUP BY Workflow_Name__c
        ];
      } else {
        counts = [
          SELECT Workflow_Name__c, COUNT(Id) cnt
          FROM Workflow_Instance__c
          WHERE Status__c = 'Paused' AND Workflow_Name__c IN :pausedNames
          WITH SYSTEM_MODE
          GROUP BY Workflow_Name__c
        ];
      }
      Map<String, Integer> countByDef = new Map<String, Integer>();
      Integer totalParked = 0;
      for (AggregateResult ar : counts) {
        String name = (String) ar.get('Workflow_Name__c');
        // Grouped COUNT(Id) is returned as Integer in this org (see getWorkflowStats);
        // a Decimal cast throws TypeException as soon as a definition has parked rows.
        Integer cnt = (Integer) ar.get('cnt');
        // Workflow_Name__c is a case-insensitive external id, so the SOQL filter
        // above matches a pause record against instances of any casing, but an
        // Apex Map key is case-sensitive. Normalize the key (and the lookup
        // below) to lower case so a pause record created with different casing
        // than its instances still resolves its parked count instead of 0.
        countByDef.put(name == null ? null : name.toLowerCase(), cnt);
        totalParked += cnt;
      }

      List<Map<String, Object>> result = new List<Map<String, Object>>();
      for (Workflow_Pause_State__c r : pauseRecords) {
        Integer parked;
        if (r.Workflow_Name__c == '*') {
          parked = totalParked;
        } else {
          String key = r.Workflow_Name__c == null
            ? null
            : r.Workflow_Name__c.toLowerCase();
          parked = countByDef.containsKey(key) ? countByDef.get(key) : 0;
        }
        result.add(
          new Map<String, Object>{
            'workflowName' => r.Workflow_Name__c,
            'reason' => r.Reason__c,
            'pausedAt' => r.CreatedDate,
            'parkedCount' => parked
          }
        );
      }
      return result;
    } catch (Exception ex) {
      System.debug(
        LoggingLevel.ERROR,
        'Aura getPausedDefinitions failed: ' +
          ex.getMessage() +
          '\n' +
          ex.getStackTraceString()
      );
      throw new AuraHandledException(ex.getMessage());
    }
  }

  /**
   * Returns the concurrency-limit picture for each governed workflow (issue #28):
   * current in-flight count vs. its configured ceiling, and the number of
   * parked/throttled instances awaiting admission. One row per durable counter
   * (Concurrency_State__c) — i.e. every workflow that is, or has been, governed.
   * Each entry: { workflowName, ceiling, inFlight, parked }.
   */
  @AuraEnabled
  public static List<Map<String, Object>> getConcurrencyStatus() {
    checkAuthorization();
    try {
      List<Concurrency_State__c> states = [
        SELECT Workflow_Definition__c, In_Flight_Count__c
        FROM Concurrency_State__c
        WITH SYSTEM_MODE
        ORDER BY Workflow_Definition__c ASC
      ];
      if (states.isEmpty()) {
        return new List<Map<String, Object>>();
      }

      Set<String> workflowNames = new Set<String>();
      for (Concurrency_State__c s : states) {
        workflowNames.add(s.Workflow_Definition__c);
      }

      // Parked = Suspended specifically awaiting a concurrency slot (distinct from
      // ordinary sleep/signal waits), grouped per definition.
      Map<String, Integer> parkedByDef = new Map<String, Integer>();
      for (AggregateResult ar : [
        SELECT Workflow_Name__c wf, COUNT(Id) cnt
        FROM Workflow_Instance__c
        WHERE
          Workflow_Name__c IN :workflowNames
          AND Status__c = 'Suspended'
          AND Concurrency_Parked__c = TRUE
        WITH SYSTEM_MODE
        GROUP BY Workflow_Name__c
      ]) {
        parkedByDef.put((String) ar.get('wf'), (Integer) ar.get('cnt'));
      }

      List<Map<String, Object>> result = new List<Map<String, Object>>();
      for (Concurrency_State__c s : states) {
        result.add(
          new Map<String, Object>{
            'workflowName' => s.Workflow_Definition__c,
            'ceiling' => ConcurrencyGate.getCeiling(s.Workflow_Definition__c),
            'inFlight' => s.In_Flight_Count__c == null
              ? 0
              : (Integer) s.In_Flight_Count__c,
            'parked' => parkedByDef.containsKey(s.Workflow_Definition__c)
              ? parkedByDef.get(s.Workflow_Definition__c)
              : 0
          }
        );
      }
      return result;
    } catch (Exception ex) {
      System.debug(
        LoggingLevel.ERROR,
        'Aura getConcurrencyStatus failed: ' +
          ex.getMessage() +
          '\n' +
          ex.getStackTraceString()
      );
      throw new AuraHandledException(ex.getMessage());
    }
  }

  private static final Integer FAILURE_BREAKDOWN_CAP = 2000;

  @AuraEnabled
  public static Map<String, Object> getWorkflowFailureBreakdown(
    String workflowName,
    String timeWindow
  ) {
    checkAuthorization();

    if (String.isBlank(workflowName)) {
      return new Map<String, Object>{
        'workflowName' => '',
        'timeWindow' => timeWindow,
        'isCapped' => false,
        'capLimit' => FAILURE_BREAKDOWN_CAP,
        'totalFailures' => 0,
        'steps' => new List<Map<String, Object>>()
      };
    }

    Datetime since = null;
    if (
      String.isNotBlank(timeWindow) &&
      TREND_WINDOW_HOURS.containsKey(timeWindow)
    ) {
      Integer windowHours = TREND_WINDOW_HOURS.get(timeWindow);
      since = Datetime.now().addHours(-windowHours);
    }

    List<Workflow_Step_Execution__c> steps;
    if (since != null) {
      steps = [
        SELECT
          Step_Name__c,
          Error_Details__c,
          Workflow_Instance__c,
          Workflow_Instance__r.Name,
          CreatedDate
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__r.Workflow_Name__c = :workflowName
          AND Status__c = 'Failed'
          AND CreatedDate >= :since
        WITH SYSTEM_MODE
        ORDER BY CreatedDate DESC
        LIMIT :FAILURE_BREAKDOWN_CAP
      ];
    } else {
      steps = [
        SELECT
          Step_Name__c,
          Error_Details__c,
          Workflow_Instance__c,
          Workflow_Instance__r.Name,
          CreatedDate
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__r.Workflow_Name__c = :workflowName
          AND Status__c = 'Failed'
        WITH SYSTEM_MODE
        ORDER BY CreatedDate DESC
        LIMIT :FAILURE_BREAKDOWN_CAP
      ];
    }

    Map<String, StepFailureGroup> stepGroups = new Map<String, StepFailureGroup>();

    for (Workflow_Step_Execution__c se : steps) {
      String stepName = se.Step_Name__c;
      if (String.isBlank(stepName)) {
        stepName = 'Unknown Step';
      }

      StepFailureGroup stepGroup = stepGroups.get(stepName);
      if (stepGroup == null) {
        stepGroup = new StepFailureGroup(stepName);
        stepGroups.put(stepName, stepGroup);
      }
      stepGroup.addFailure(se);
    }

    List<StepFailureGroup> sortedSteps = stepGroups.values();
    sortedSteps.sort();

    List<Map<String, Object>> stepList = new List<Map<String, Object>>();
    for (StepFailureGroup sg : sortedSteps) {
      stepList.add(sg.toMap());
    }

    return new Map<String, Object>{
      'workflowName' => workflowName,
      'timeWindow' => String.isNotBlank(timeWindow) ? timeWindow : 'all',
      'isCapped' => (steps.size() >= FAILURE_BREAKDOWN_CAP),
      'capLimit' => FAILURE_BREAKDOWN_CAP,
      'totalFailures' => steps.size(),
      'steps' => stepList
    };
  }

  @TestVisible
  private static String getNormalizedSignature(String errorDetails) {
    if (String.isBlank(errorDetails)) {
      return 'Unknown Error';
    }
    String signature = errorDetails.split('\n')[0];
    if (String.isBlank(signature)) {
      signature = 'Unknown Error';
    }

    // Normalize UUIDs
    signature = signature.replaceAll(
      '\\b[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}\\b',
      '[UUID]'
    );

    // Normalize Datetimes
    signature = signature.replaceAll(
      '\\b\\d{4}-\\d{2}-\\d{2}[T ]\\d{2}:\\d{2}:\\d{2}(?:\\.\\d+)?(?:Z|[+-]\\d{2}:?\\d{2})?\\b',
      '[DATETIME]'
    );

    // Normalize Dates
    signature = signature.replaceAll('\\b\\d{4}-\\d{2}-\\d{2}\\b', '[DATE]');

    // Normalize Salesforce IDs containing at least one digit
    signature = signature.replaceAll(
      '\\b(?=[a-zA-Z0-9]*[0-9])[a-zA-Z0-9]{15,18}\\b',
      '[ID]'
    );

    // Normalize standalone numbers
    signature = signature.replaceAll('\\b\\d+\\b', '[NUM]');

    signature = signature.trim();
    if (signature.length() > 255) {
      signature = signature.substring(0, 252) + '...';
    }

    return signature;
  }

  private class StepFailureGroup implements Comparable {
    String stepName;
    Integer failureCount = 0;
    Map<String, SignatureGroup> signatures = new Map<String, SignatureGroup>();

    StepFailureGroup(String stepName) {
      this.stepName = stepName;
    }

    void addFailure(Workflow_Step_Execution__c se) {
      this.failureCount++;
      String sig = getNormalizedSignature(se.Error_Details__c);
      SignatureGroup sigGroup = signatures.get(sig);
      if (sigGroup == null) {
        sigGroup = new SignatureGroup(sig);
        signatures.put(sig, sigGroup);
      }
      sigGroup.addOccurrence(se);
    }

    Map<String, Object> toMap() {
      List<SignatureGroup> sortedSigs = signatures.values();
      sortedSigs.sort();

      List<Map<String, Object>> sigList = new List<Map<String, Object>>();
      for (SignatureGroup sg : sortedSigs) {
        sigList.add(sg.toMap());
      }

      return new Map<String, Object>{
        'stepName' => stepName,
        'failureCount' => failureCount,
        'errorSignatures' => sigList
      };
    }

    public Integer compareTo(Object other) {
      StepFailureGroup that = (StepFailureGroup) other;
      if (this.failureCount != that.failureCount) {
        return that.failureCount - this.failureCount; // higher failures first
      }
      return this.stepName.compareTo(that.stepName);
    }
  }

  private class SignatureGroup implements Comparable {
    String signature;
    Integer count = 0;
    List<Map<String, String>> examples = new List<Map<String, String>>();
    Set<Id> exampleInstanceIds = new Set<Id>();

    SignatureGroup(String signature) {
      this.signature = signature;
    }

    void addOccurrence(Workflow_Step_Execution__c se) {
      this.count++;
      if (
        examples.size() < 5 &&
        se.Workflow_Instance__c != null &&
        !exampleInstanceIds.contains(se.Workflow_Instance__c)
      ) {
        exampleInstanceIds.add(se.Workflow_Instance__c);
        examples.add(
          new Map<String, String>{
            'id' => se.Workflow_Instance__c,
            'name' => se.Workflow_Instance__r.Name
          }
        );
      }
    }

    Map<String, Object> toMap() {
      return new Map<String, Object>{
        'signature' => signature,
        'count' => count,
        'examples' => examples
      };
    }

    public Integer compareTo(Object other) {
      SignatureGroup that = (SignatureGroup) other;
      if (this.count != that.count) {
        return that.count - this.count; // higher counts first
      }
      return this.signature.compareTo(that.signature);
    }
  }
}
