public inherited sharing class WorkflowDashboardController {
  // Class-level static binding variable for dynamic SOQL wildcard queries.
  // This is required because dynamic SOQL string bindings (:variable) must be in scope
  // when Database.query() is executed, even if the WHERE clause is built in a helper method.
  private static String likeTerm;
  // Binding variable for the stalled-instance cutoff DateTime (used in getStalledInstances /
  // getStalledCount dynamic SOQL — same reason as likeTerm above).
  private static Datetime stalledCutoff;
  // Binding variables for filtering by attributes (up to 2 semi-joins for performance).
  private static String attributeFilter0;
  private static String attributeFilter1;
  // Binding set for pre-queried search attributes to bypass SOQL semi-join sub-select limit (max 2)
  private static Set<Id> filterInstanceIds;

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

  // Character length above which the dashboard shows a truncated preview. Payloads that
  // are attachment-backed AND exceed this get a download link to the full ContentDocument.
  @TestVisible
  private static final Integer PAYLOAD_DISPLAY_LIMIT = 50000;

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

  @TestVisible
  private static Boolean forceDefinitionFallback = false;

  private static final Integer UNROUTED_CANDIDATE_CAP = 2000;

  private static final Integer FAILURE_BREAKDOWN_CAP = 2000;

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
      } catch (Exception ignored) {
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

  /**
   * Carries the resolved attachment bodies plus the download descriptors accumulated
   * while resolving an instance's payload fields, so resolveAndRecordPayload can take a
   * single context object instead of a long parameter list.
   */
  private class PayloadResolution {
    Map<Id, String> attachmentIdToData;
    Map<String, Object> payloadFiles;

    PayloadResolution(Map<Id, String> attachmentIdToData) {
      this.attachmentIdToData = attachmentIdToData;
      this.payloadFiles = new Map<String, Object>();
    }
  }

  /**
   * Resolves a payload field for display: returns the (possibly truncated) text and, when
   * the value is attachment-backed and was truncated, records a download descriptor for
   * the full ContentDocument under fieldKey in res.payloadFiles so the UI can offer the file.
   */
  private static String resolveAndRecordPayload(
    String textValue,
    String fieldKey,
    PayloadResolution res
  ) {
    if (String.isBlank(textValue)) {
      return textValue;
    }
    Id attachmentId = getAttachmentId(textValue);
    if (
      attachmentId != null && res.attachmentIdToData.containsKey(attachmentId)
    ) {
      String full = res.attachmentIdToData.get(attachmentId);
      if (full != null && full.length() > PAYLOAD_DISPLAY_LIMIT) {
        res.payloadFiles.put(
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

  private static void addAttachmentId(Set<Id> attachmentIds, String textValue) {
    Id attachmentId = getAttachmentId(textValue);
    if (attachmentId != null) {
      attachmentIds.add(attachmentId);
    }
  }

  private static Set<Id> collectPayloadAttachmentIds(
    Workflow_Instance__c instance,
    List<Workflow_Step_Execution__c> steps
  ) {
    Set<Id> attachmentIds = new Set<Id>();
    addAttachmentId(attachmentIds, instance.Input__c);
    addAttachmentId(attachmentIds, instance.Output__c);
    addAttachmentId(attachmentIds, instance.Progress__c);
    for (Workflow_Step_Execution__c step : steps) {
      addAttachmentId(attachmentIds, step.Input__c);
      addAttachmentId(attachmentIds, step.Output__c);
    }
    return attachmentIds;
  }

  private static Set<Id> verifyAttachmentLinks(
    Set<Id> attachmentIds,
    Id linkedEntityId
  ) {
    Set<Id> verifiedAttachmentIds = new Set<Id>();
    for (ContentDocumentLink cdl : [
      SELECT ContentDocumentId
      FROM ContentDocumentLink
      WHERE
        ContentDocumentId IN :attachmentIds
        AND LinkedEntityId = :linkedEntityId
      WITH SYSTEM_MODE
    ]) {
      verifiedAttachmentIds.add(cdl.ContentDocumentId);
    }
    return verifiedAttachmentIds;
  }

  private static Map<Id, String> loadAttachmentData(
    Set<Id> attachmentIds,
    Id linkedEntityId
  ) {
    Map<Id, String> attachmentIdToData = new Map<Id, String>();
    if (attachmentIds.isEmpty()) {
      return attachmentIdToData;
    }
    Set<Id> verifiedAttachmentIds = verifyAttachmentLinks(
      attachmentIds,
      linkedEntityId
    );
    if (verifiedAttachmentIds.isEmpty()) {
      return attachmentIdToData;
    }
    for (ContentVersion cv : [
      SELECT ContentDocumentId, VersionData
      FROM ContentVersion
      WHERE ContentDocumentId IN :verifiedAttachmentIds AND IsLatest = TRUE
      WITH SYSTEM_MODE
    ]) {
      if (cv.VersionData != null) {
        attachmentIdToData.put(cv.ContentDocumentId, cv.VersionData.toString());
      }
    }
    return attachmentIdToData;
  }

  private static Map<String, Object> resolvePayloadsInBulk(
    Workflow_Instance__c instance,
    List<Workflow_Step_Execution__c> steps
  ) {
    Set<Id> attachmentIds = collectPayloadAttachmentIds(instance, steps);
    Map<Id, String> attachmentIdToData = loadAttachmentData(
      attachmentIds,
      instance.Id
    );
    PayloadResolution res = new PayloadResolution(attachmentIdToData);

    instance.Input__c = resolveAndRecordPayload(
      instance.Input__c,
      'instance.Input',
      res
    );
    instance.Output__c = resolveAndRecordPayload(
      instance.Output__c,
      'instance.Output',
      res
    );
    instance.Progress__c = resolveAndRecordPayload(
      instance.Progress__c,
      'instance.Progress',
      res
    );
    for (Workflow_Step_Execution__c step : steps) {
      step.Input__c = resolveAndRecordPayload(
        step.Input__c,
        'step.' + step.Id + '.Input',
        res
      );
      step.Output__c = resolveAndRecordPayload(
        step.Output__c,
        'step.' + step.Id + '.Output',
        res
      );
    }
    return res.payloadFiles;
  }

  // Resolves attributeFilter0/1 (and resets filterInstanceIds) from the filter JSON
  // for the non-stalled queries, which express the attribute match as inline SOQL
  // semi-joins in buildWhereClause. Malformed JSON is treated as "no attribute filter".
  private static void resolveMatchingAttributes(String attributesFilterJson) {
    attributeFilter0 = null;
    attributeFilter1 = null;
    filterInstanceIds = new Set<Id>();
    if (String.isBlank(attributesFilterJson)) {
      return;
    }
    try {
      Map<String, Object> raw = (Map<String, Object>) JSON.deserializeUntyped(
        attributesFilterJson
      );
      if (raw == null || raw.isEmpty()) {
        return;
      }
      List<String> targetKeyValues = new List<String>();
      for (String k : raw.keySet()) {
        String val = String.valueOf(raw.get(k));
        targetKeyValues.add(k + '=' + (val == null ? '' : val));
      }
      if (targetKeyValues.size() > 0) {
        attributeFilter0 = targetKeyValues[0];
      }
      if (targetKeyValues.size() > 1) {
        attributeFilter1 = targetKeyValues[1];
      }
    } catch (Exception ignored) {
    }
  }

  // Attribute resolution for the stalled list/count, which cannot express the
  // attribute match inline (the stalled WHERE already uses two anti-join sub-selects
  // and SOQL caps sub-selects at 2). Resolves the same attributeFilter0/1, then
  // pre-queries the matching instance ids into filterInstanceIds for the WHERE bind.
  private static void resolveMatchingAttributesForStalled(
    String attributesFilterJson
  ) {
    resolveMatchingAttributes(attributesFilterJson);
    if (attributeFilter0 == null && attributeFilter1 == null) {
      return;
    }
    try {
      if (attributeFilter0 != null && attributeFilter1 != null) {
        Set<Id> ids0 = queryAttributeInstanceIds(attributeFilter0);
        for (Id instanceId : queryAttributeInstanceIds(attributeFilter1)) {
          if (ids0.contains(instanceId)) {
            filterInstanceIds.add(instanceId);
          }
        }
      } else {
        String target = (attributeFilter0 != null)
          ? attributeFilter0
          : attributeFilter1;
        filterInstanceIds.addAll(queryAttributeInstanceIds(target));
      }
    } catch (Exception ignored) {
    }
  }

  private static Set<Id> queryAttributeInstanceIds(String keyValue) {
    Set<Id> ids = new Set<Id>();
    for (Workflow_Search_Attribute__c attr : [
      SELECT Workflow_Instance__c
      FROM Workflow_Search_Attribute__c
      WHERE Key_Value__c = :keyValue
      WITH SYSTEM_MODE
      LIMIT 10000
    ]) {
      ids.add(attr.Workflow_Instance__c);
    }
    return ids;
  }

  // Lightweight holder for the instance-list filter fields, so buildWhereClause takes a
  // single argument. The condition strings bind to the caller's locals (:workflowName,
  // :status, :searchTerm, :failureCategory), which retain those names, plus the class
  // statics :likeTerm / :attributeFilter0 / :attributeFilter1.
  private class InstanceFilter {
    String workflowName;
    String status;
    String searchTerm;
    String failureCategory;
  }

  private static String buildWhereClause(InstanceFilter f) {
    List<String> conditions = new List<String>();
    if (String.isNotBlank(f.workflowName)) {
      conditions.add('Workflow_Name__c = :workflowName');
    }
    if (String.isNotBlank(f.status)) {
      conditions.add('Status__c = :status');
    }
    if (String.isNotBlank(f.failureCategory)) {
      conditions.add('Failure_Category__c = :failureCategory');
    }
    if (String.isNotBlank(f.searchTerm)) {
      likeTerm = '%' + f.searchTerm + '%';
      conditions.add(
        '(Name LIKE :likeTerm OR Correlation_Key__c LIKE :likeTerm OR Workflow_Name__c LIKE :likeTerm OR Error_Message__c LIKE :likeTerm)'
      );
    }
    if (attributeFilter0 != null) {
      conditions.add(
        'Id IN (SELECT Workflow_Instance__c FROM Workflow_Search_Attribute__c WHERE Key_Value__c = :attributeFilter0)'
      );
    }
    if (attributeFilter1 != null) {
      conditions.add(
        'Id IN (SELECT Workflow_Instance__c FROM Workflow_Search_Attribute__c WHERE Key_Value__c = :attributeFilter1)'
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
    if (attributeFilter0 != null || attributeFilter1 != null) {
      conditions.add('Id IN :filterInstanceIds');
    }
    return String.join(conditions, ' AND ');
  }

  // Query criteria for the filtered-instance list and the workflow-stat rollup. Field-based
  // (@AuraEnabled properties) so the LWC and tests populate it by assignment; a wide
  // constructor would re-introduce the long parameter list this wrapper removes. Unset
  // fields default to null, reproducing the previous shorter overloads.
  public class InstanceQuery {
    @AuraEnabled
    public String workflowName;
    @AuraEnabled
    public String status;
    @AuraEnabled
    public String searchTerm;
    @AuraEnabled
    public String failureCategory;
    @AuraEnabled
    public Integer limitSize;
    @AuraEnabled
    public Integer offsetSize;
    @AuraEnabled
    public String cacheBuster;
    @AuraEnabled
    public String attributesFilterJson;
  }

  // Runs the filtered-instance SOQL for getFilteredInstances. The bind tokens
  // (:workflowName, :status, :failureCategory emitted by buildWhereClause, and
  // :limitSize / :offsetSize in the ORDER BY) resolve against this method's local
  // scope, so the caller passes the clamped page bounds in.
  private static List<Workflow_Instance__c> queryFilteredInstances(
    InstanceQuery criteria,
    Integer limitSize,
    Integer offsetSize
  ) {
    String workflowName = criteria.workflowName;
    String status = criteria.status;
    String failureCategory = criteria.failureCategory;

    InstanceFilter f = new InstanceFilter();
    f.workflowName = workflowName;
    f.status = status;
    f.searchTerm = criteria.searchTerm;
    f.failureCategory = failureCategory;

    String query =
      'SELECT Id, Name, Workflow_Name__c, Status__c, Correlation_Key__c, CreatedDate, LastModifiedDate, Error_Message__c, Async_Job_Id__c, Sleep_Until__c, Deadline_At__c, Failure_Category__c ' +
      'FROM Workflow_Instance__c' +
      buildWhereClause(f) +
      ' ORDER BY CreatedDate DESC LIMIT :limitSize OFFSET :offsetSize';

    return Database.query(query, AccessLevel.SYSTEM_MODE);
  }

  @AuraEnabled(cacheable=true)
  public static List<Map<String, Object>> getFilteredInstances(
    InstanceQuery criteria
  ) {
    checkAuthorization();
    resolveMatchingAttributes(criteria.attributesFilterJson);

    Integer limitSize = clampListLimit(criteria.limitSize);
    Integer offsetSize = clampListOffset(criteria.offsetSize);
    List<Workflow_Instance__c> instances = queryFilteredInstances(
      criteria,
      limitSize,
      offsetSize
    );

    Set<Id> pageIds = new Set<Id>();
    for (Workflow_Instance__c inst : instances) {
      pageIds.add(inst.Id);
    }
    Set<Id> activeCronIds = new Set<Id>();
    Set<Id> activeAsyncIds = new Set<Id>();
    loadActiveJobIds(instances, activeCronIds, activeAsyncIds);
    Set<Id> instancesWithStepTimeout = queryInstancesWithStepTimeout(pageIds);
    Set<Id> instancesWithPendingStep = queryInstancesWithPendingStep(pageIds);

    Long nowMs = Datetime.now().getTime();
    List<Map<String, Object>> results = new List<Map<String, Object>>();
    for (Workflow_Instance__c inst : instances) {
      String waitingOn = computeWaitingOn(inst, activeCronIds, activeAsyncIds);
      Long idleMinutes = TERMINAL_STATUSES.contains(inst.Status__c)
        ? null
        : Math.max(0L, (nowMs - inst.LastModifiedDate.getTime()) / 60000L);
      StallSignals sig = new StallSignals();
      sig.hasStepTimeout = instancesWithStepTimeout.contains(inst.Id);
      sig.hasPendingStep = instancesWithPendingStep.contains(inst.Id);
      sig.idleMinutes = idleMinutes;
      sig.thresholdMinutes = WorkflowEngine.staleThresholdMinutes;
      Boolean stalled = computeStalled(inst, waitingOn, sig);

      Map<String, Object> m = buildInstanceRow(inst, waitingOn, idleMinutes);
      m.put('stalled', stalled);
      m.put('Failure_Category__c', inst.Failure_Category__c);
      results.add(m);
    }
    return results;
  }

  // cacheBuster is unused in Apex; it only varies the client-side cache key so a
  // dashboard refresh re-queries instead of serving a stale cached list (mirrors
  // getFilteredInstances).
  // Query criteria shared by the stalled-instance list and the stalled count. Field-based
  // (@AuraEnabled properties) so the LWC and tests populate it by assignment. getStalledCount
  // ignores the pagination fields (limitSize/offsetSize/cacheBuster); getStalledInstances uses
  // them. Unset fields default to null, reproducing the previous shorter overloads.
  public class StalledQuery {
    @AuraEnabled
    public String workflowName;
    @AuraEnabled
    public String searchTerm;
    @AuraEnabled
    public Integer thresholdMinutes;
    @AuraEnabled
    public Integer limitSize;
    @AuraEnabled
    public Integer offsetSize;
    @AuraEnabled
    public String cacheBuster;
    @AuraEnabled
    public String attributesFilterJson;
  }

  @AuraEnabled(cacheable=true)
  public static List<Map<String, Object>> getStalledInstances(
    StalledQuery criteria
  ) {
    checkAuthorization();
    // Local named to match the :workflowName bind token emitted by buildStalledWhereClause,
    // which resolves against this method's scope.
    String workflowName = criteria.workflowName;
    String searchTerm = criteria.searchTerm;
    Integer threshold = (criteria.thresholdMinutes == null)
      ? WorkflowEngine.staleThresholdMinutes
      : criteria.thresholdMinutes;
    stalledCutoff = Datetime.now().addMinutes(-threshold);

    resolveMatchingAttributesForStalled(criteria.attributesFilterJson);

    Integer limitSize = clampListLimit(criteria.limitSize);
    Integer offsetSize = criteria.offsetSize;
    if (offsetSize == null || offsetSize < 0) {
      offsetSize = 0;
    }

    String query =
      'SELECT Id, Name, Workflow_Name__c, Status__c, Correlation_Key__c, CreatedDate, LastModifiedDate, Error_Message__c, Async_Job_Id__c, Sleep_Until__c, Deadline_At__c ' +
      'FROM Workflow_Instance__c WHERE ' +
      buildStalledWhereClause(workflowName, searchTerm) +
      ' ORDER BY LastModifiedDate ASC LIMIT :STALLED_CANDIDATE_CAP';

    List<Workflow_Instance__c> candidates = Database.query(
      query,
      AccessLevel.SYSTEM_MODE
    );

    // Filter to genuinely stalled rows FIRST, then paginate, so the in-memory
    // job-liveness filter (which SOQL cannot express) never returns a short page
    // that would make the LWC stop paging before later stalled rows are reached.
    List<StalledCandidate> stalled = filterStalledCandidates(
      candidates,
      threshold
    );
    List<Map<String, Object>> stalledRows = new List<Map<String, Object>>();
    for (StalledCandidate sc : stalled) {
      Map<String, Object> row = buildInstanceRow(
        sc.inst,
        sc.waitingOn,
        sc.idleMinutes
      );
      row.put('stalled', true);
      stalledRows.add(row);
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
  public static Map<String, Object> getStalledCount(StalledQuery criteria) {
    checkAuthorization();
    // Local named to match the :workflowName bind token emitted by buildStalledWhereClause,
    // which resolves against this method's scope.
    String workflowName = criteria.workflowName;
    String searchTerm = criteria.searchTerm;
    Integer threshold = (criteria.thresholdMinutes == null)
      ? WorkflowEngine.staleThresholdMinutes
      : criteria.thresholdMinutes;
    stalledCutoff = Datetime.now().addMinutes(-threshold);

    resolveMatchingAttributesForStalled(criteria.attributesFilterJson);

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

    Integer count = filterStalledCandidates(candidates, threshold).size();
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
      } catch (Exception ignored) {
      }
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

  // Clamps a caller-supplied page size to [1, 100], defaulting blank/non-positive to 50.
  private static Integer clampListLimit(Integer limitSize) {
    if (limitSize == null || limitSize <= 0) {
      return 50;
    }
    return limitSize > 100 ? 100 : limitSize;
  }

  // Clamps a caller-supplied offset to [0, 2000], defaulting blank/negative to 0.
  private static Integer clampListOffset(Integer offsetSize) {
    if (offsetSize == null || offsetSize < 0) {
      return 0;
    }
    return offsetSize > 2000 ? 2000 : offsetSize;
  }

  // True when the string is plausibly a 15/18-char CronTrigger (08e) or
  // AsyncApexJob (707) id.
  private static Boolean isJobIdShaped(String jobIdStr) {
    return (jobIdStr.length() == 15 || jobIdStr.length() == 18) &&
      (jobIdStr.startsWith('08e') || jobIdStr.startsWith('707'));
  }

  // Collects the active cron/async job ids referenced by the given instances into the
  // supplied (initially empty) sets. Shared by the filtered/stalled list and count paths.
  private static void loadActiveJobIds(
    List<Workflow_Instance__c> instances,
    Set<Id> activeCronIds,
    Set<Id> activeAsyncIds
  ) {
    Set<Id> cronIds = new Set<Id>();
    Set<Id> asyncIds = new Set<Id>();
    for (Workflow_Instance__c inst : instances) {
      collectJobId(inst.Async_Job_Id__c, cronIds, asyncIds);
    }
    activeCronIds.addAll(queryActiveCronIds(cronIds));
    activeAsyncIds.addAll(queryActiveAsyncIds(asyncIds));
  }

  // Builds the display row shared by the filtered and stalled instance lists. The caller
  // adds the 'stalled' flag (and getFilteredInstances also adds Failure_Category__c, which
  // the stalled query does not select), so neither is included here.
  private static Map<String, Object> buildInstanceRow(
    Workflow_Instance__c inst,
    String waitingOn,
    Long idleMinutes
  ) {
    return new Map<String, Object>{
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
      'idleMinutes' => idleMinutes
    };
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
      return classifyActiveJobWait(
        inst.Async_Job_Id__c,
        activeCronIds,
        activeAsyncIds
      );
    }
    if (inst.Sleep_Until__c != null) {
      return 'Watchdog';
    }
    return null;
  }

  // Maps a Suspended instance's job id to what it is waiting on, using the pre-queried
  // active-job id sets. A live scheduled cron → 'Scheduled Job', a live queueable →
  // 'Delayed Queueable'; anything else (dead job, non-job id, cast failure) → 'Watchdog'.
  private static String classifyActiveJobWait(
    String jobIdStr,
    Set<Id> activeCronIds,
    Set<Id> activeAsyncIds
  ) {
    if (!isJobIdShaped(jobIdStr)) {
      return 'Watchdog';
    }
    try {
      Id jobId = (Id) jobIdStr;
      if (
        jobId.getSobjectType() == CronTrigger.SObjectType &&
        activeCronIds.contains(jobId)
      ) {
        return 'Scheduled Job';
      }
      if (
        jobId.getSobjectType() == AsyncApexJob.SObjectType &&
        activeAsyncIds.contains(jobId)
      ) {
        return 'Delayed Queueable';
      }
      return 'Watchdog';
    } catch (Exception ex) {
      return 'Watchdog';
    }
  }

  // Per-instance signals feeding computeStalled, bundled so the check takes a single
  // context object instead of a long parameter list.
  private class StallSignals {
    Boolean hasStepTimeout;
    Boolean hasPendingStep;
    Long idleMinutes;
    Integer thresholdMinutes;
  }

  private static Boolean computeStalled(
    Workflow_Instance__c inst,
    String waitingOn,
    StallSignals sig
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
    if (sig.hasStepTimeout) {
      return false;
    }
    // Signal/approval/child-completion waits park a Pending step-exec row;
    // exclude them so only true orphans (no resume mechanism at all) are flagged.
    if (sig.hasPendingStep) {
      return false;
    }
    return sig.idleMinutes > sig.thresholdMinutes;
  }

  // A candidate that passed the in-memory stalled check, carrying the derived display
  // values so callers can build rows without recomputing (and re-querying) job liveness.
  private class StalledCandidate {
    Workflow_Instance__c inst;
    String waitingOn;
    Long idleMinutes;

    StalledCandidate(
      Workflow_Instance__c inst,
      String waitingOn,
      Long idleMinutes
    ) {
      this.inst = inst;
      this.waitingOn = waitingOn;
      this.idleMinutes = idleMinutes;
    }
  }

  // Shared stalled-detection for the stalled list and count: resolves job liveness once
  // for the candidate set, then returns those genuinely stalled. Step-timeout and
  // pending-step instances are already excluded by the stalled WHERE-clause anti-joins,
  // so those signals are false here.
  private static List<StalledCandidate> filterStalledCandidates(
    List<Workflow_Instance__c> candidates,
    Integer threshold
  ) {
    Set<Id> activeCronIds = new Set<Id>();
    Set<Id> activeAsyncIds = new Set<Id>();
    loadActiveJobIds(candidates, activeCronIds, activeAsyncIds);

    Long nowMs = Datetime.now().getTime();
    List<StalledCandidate> stalled = new List<StalledCandidate>();
    for (Workflow_Instance__c inst : candidates) {
      String waitingOn = computeWaitingOn(inst, activeCronIds, activeAsyncIds);
      Long idleMinutes = Math.max(
        0L,
        (nowMs - inst.LastModifiedDate.getTime()) / 60000L
      );
      StallSignals sig = new StallSignals();
      sig.hasStepTimeout = false;
      sig.hasPendingStep = false;
      sig.idleMinutes = idleMinutes;
      sig.thresholdMinutes = threshold;
      if (computeStalled(inst, waitingOn, sig)) {
        stalled.add(new StalledCandidate(inst, waitingOn, idleMinutes));
      }
    }
    return stalled;
  }

  // Reuses InstanceQuery (the getFilteredInstances criteria); this rollup reads only
  // workflowName/status/searchTerm/attributesFilterJson and ignores the pagination and
  // failureCategory fields.
  @AuraEnabled
  public static Map<String, Integer> getWorkflowStats(InstanceQuery criteria) {
    checkAuthorization();
    resolveMatchingAttributes(criteria.attributesFilterJson);

    Map<String, Integer> results = new Map<String, Integer>{
      'total' => 0,
      'active' => 0,
      'completed' => 0,
      'failed' => 0
    };

    // Locals named to match the :workflowName / :status bind tokens emitted by
    // buildWhereClause, which resolve against this method's scope.
    String workflowName = criteria.workflowName;
    String status = criteria.status;
    String searchTerm = criteria.searchTerm;

    InstanceFilter f = new InstanceFilter();
    f.workflowName = workflowName;
    f.status = status;
    f.searchTerm = searchTerm;

    String query =
      'SELECT Status__c, COUNT(Id) cnt FROM Workflow_Instance__c' +
      buildWhereClause(f) +
      ' GROUP BY Status__c';

    for (AggregateResult ar : Database.query(query, AccessLevel.SYSTEM_MODE)) {
      bucketWorkflowStat(
        results,
        (String) ar.get('Status__c'),
        (Integer) ar.get('cnt')
      );
    }
    return results;
  }

  // Adds a per-status aggregate count into the total plus its active/completed/failed
  // bucket (statuses outside the three buckets still count toward total only).
  private static void bucketWorkflowStat(
    Map<String, Integer> results,
    String stat,
    Integer count
  ) {
    results.put('total', results.get('total') + count);
    if (isActiveStat(stat)) {
      results.put('active', results.get('active') + count);
    } else if (stat == 'Completed' || stat == 'ContinuedAsNew') {
      results.put('completed', results.get('completed') + count);
    } else if (isFailedStat(stat)) {
      results.put('failed', results.get('failed') + count);
    }
  }

  private static Boolean isActiveStat(String stat) {
    return stat == 'Pending' ||
      stat == 'Running' ||
      stat == 'Suspended' ||
      stat == 'Compensating' ||
      stat == 'Cancelling' ||
      stat == 'Paused';
  }

  private static Boolean isFailedStat(String stat) {
    return stat == 'Failed' ||
      stat == 'CompensationFailed' ||
      stat == 'Compensated' ||
      stat == 'Cancelled';
  }

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
    Workflow_Instance__c instance = loadInstanceDetailRecord(instanceId);

    List<Workflow_Step_Execution__c> steps = [
      SELECT
        Id,
        Step_Name__c,
        Status__c,
        Input__c,
        Output__c,
        Retry_Count__c,
        Error_Details__c,
        CPU_Time_Ms__c,
        SOQL_Query_Count__c,
        Heap_Size_Bytes__c,
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

    List<Workflow_Search_Attribute__c> attributes = [
      SELECT Key__c, Value__c
      FROM Workflow_Search_Attribute__c
      WHERE Workflow_Instance__c = :instanceId
      WITH SYSTEM_MODE
      ORDER BY Key__c ASC
    ];

    // Breadcrumbs are queried newest-first (to keep the most recent 1000 under the LIMIT)
    // then reversed back to ascending order for chronological UI presentation.
    List<Workflow_Log__c> breadcrumbs = toChronological(
      [
        SELECT
          Id,
          Level__c,
          Message__c,
          Correlation_Key__c,
          Fire_Time__c,
          CreatedDate
        FROM Workflow_Log__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Log_Type__c = :StepContext.LOG_TYPE_BREADCRUMB
        WITH SYSTEM_MODE
        ORDER BY Fire_Time__c DESC, CreatedDate DESC
        LIMIT 1000
      ]
    );

    List<String> pendingCompensations = parsePendingCompensations(instance);

    return new Map<String, Object>{
      'instance' => instance,
      'steps' => steps,
      'children' => children,
      'successor' => successors.isEmpty() ? null : successors[0],
      'waitingOn' => computeDetailWaitingOn(instance),
      'pendingCompensationCount' => pendingCompensations.size(),
      'pendingCompensations' => pendingCompensations,
      'payloadFiles' => payloadFiles,
      'attributes' => attributes,
      'breadcrumbs' => breadcrumbs
    };
  }

  private static Workflow_Instance__c loadInstanceDetailRecord(Id instanceId) {
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
    return instanceList[0];
  }

  // Detail-view "waiting on" resolution. Unlike computeWaitingOn (which uses pre-queried
  // active-job id sets for a page of instances), this checks the single instance's job
  // liveness directly, since the detail view loads one record.
  private static String computeDetailWaitingOn(Workflow_Instance__c instance) {
    if (instance.Status__c != 'Suspended') {
      return null;
    }
    if (String.isNotBlank(instance.Async_Job_Id__c)) {
      return classifyDetailJobWait(instance.Async_Job_Id__c);
    }
    if (instance.Sleep_Until__c != null) {
      return 'Watchdog';
    }
    return null;
  }

  private static String classifyDetailJobWait(String jobIdStr) {
    if (!isJobIdShaped(jobIdStr)) {
      return 'Watchdog';
    }
    try {
      Id jobId = (Id) jobIdStr;
      if (jobId.getSobjectType() == CronTrigger.SObjectType) {
        return isCronJobActive(jobId) ? 'Scheduled Job' : 'Watchdog';
      }
      if (jobId.getSobjectType() == AsyncApexJob.SObjectType) {
        return isAsyncJobActive(jobId) ? 'Delayed Queueable' : 'Watchdog';
      }
      return null;
    } catch (Exception ex) {
      return 'Watchdog';
    }
  }

  private static Boolean isCronJobActive(Id jobId) {
    return ![
        SELECT Id
        FROM CronTrigger
        WHERE
          Id = :jobId
          AND State IN ('WAITING', 'ACQUIRED', 'QUEUED', 'EXECUTING')
        WITH SYSTEM_MODE
        LIMIT 1
      ]
      .isEmpty();
  }

  private static Boolean isAsyncJobActive(Id jobId) {
    return ![
        SELECT Id
        FROM AsyncApexJob
        WHERE
          Id = :jobId
          AND Status IN ('Queued', 'Holding', 'Preparing', 'Processing')
        WITH SYSTEM_MODE
        LIMIT 1
      ]
      .isEmpty();
  }

  // Derives the un-run remainder of the LIFO compensation stack so a stalled
  // ("rollback incomplete") saga can show, at a glance, how many and which forward
  // steps still have un-reversed side effects — no manual JSON inspection required.
  // The stack is presented top-of-stack first (next to be compensated).
  private static List<String> parsePendingCompensations(
    Workflow_Instance__c instance
  ) {
    List<String> pendingCompensations = new List<String>();
    if (String.isBlank(instance.Compensation_Stack__c)) {
      return pendingCompensations;
    }
    try {
      List<String> stack = (List<String>) JSON.deserialize(
        instance.Compensation_Stack__c,
        List<String>.class
      );
      for (Integer i = stack.size() - 1; i >= 0; i--) {
        pendingCompensations.add(stack[i]);
      }
    } catch (Exception ignored) {
    }
    return pendingCompensations;
  }

  private static List<Workflow_Log__c> toChronological(
    List<Workflow_Log__c> breadcrumbs
  ) {
    List<Workflow_Log__c> chronological = new List<Workflow_Log__c>();
    for (Integer i = breadcrumbs.size() - 1; i >= 0; i--) {
      chronological.add(breadcrumbs[i]);
    }
    return chronological;
  }

  /**
   * Raised internally when the precise source-scan strategy approaches a governor
   * limit. It is thrown *before* the (uncatchable) platform LimitException would fire,
   * so the caller can degrade gracefully to the lightweight ApexTypeImplementor index.
   */
  @TestVisible
  private class DefinitionScanLimitException extends Exception {
  }

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
    String searchTerm
  ) {
    return startBulkCancel(
      new Map<String, Object>{
        'workflowName' => workflowName,
        'status' => status,
        'searchTerm' => searchTerm,
        'runCompensations' => false
      }
    );
  }

  @AuraEnabled
  public static Map<String, Object> cancelMatchingInstancesWithCompensations(
    String workflowName,
    String status,
    String searchTerm
  ) {
    return startBulkCancel(
      new Map<String, Object>{
        'workflowName' => workflowName,
        'status' => status,
        'searchTerm' => searchTerm,
        'runCompensations' => true
      }
    );
  }

  // Shared bulk-cancel launcher. The filter map already carries the operator's
  // workflowName/status/searchTerm plus the runCompensations flag; the BulkCancelWorkflow
  // instance reads it to page and cancel the matching set asynchronously.
  private static Map<String, Object> startBulkCancel(
    Map<String, Object> filter
  ) {
    checkAuthorization();
    try {
      String workflowName = (String) filter.get('workflowName');
      String status = (String) filter.get('status');
      String searchTerm = (String) filter.get('searchTerm');
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
      throw new AuraHandledException(ex.getMessage());
    }
  }

  /**
   * Operator action to resume a failed instance past a failed step by supplying
   * that step's resolved output and resuming forward execution.
   */
  @AuraEnabled
  public static void resumePastStepInstance(
    Id instanceId,
    String stepName,
    String suppliedOutputJson
  ) {
    checkAuthorization();
    if (
      !FeatureManagement.checkPermission('Workflow_Step_Skip') &&
      !currentUserHasModifyAllData()
    ) {
      AuraHandledException ex = new AuraHandledException(
        'Unauthorized: skipping a step requires the "Workflow_Step_Skip" permission.'
      );
      ex.setMessage(
        'Unauthorized: skipping a step requires the "Workflow_Step_Skip" permission.'
      );
      throw ex;
    }
    try {
      WorkflowEngine.resumePastStep(instanceId, stepName, suppliedOutputJson);
    } catch (Exception ex) {
      AuraHandledException aex = new AuraHandledException(ex.getMessage());
      aex.setMessage(ex.getMessage());
      throw aex;
    }
  }

  @AuraEnabled
  public static Id compensateWorkflow(Id instanceId) {
    checkAuthorization();
    try {
      return WorkflowEngine.compensate(instanceId);
    } catch (Exception ex) {
      throw new AuraHandledException(ex.getMessage());
    }
  }

  // Request wrapper for cancelWorkflow so the runCompensations flag is an @AuraEnabled
  // property rather than a Boolean method parameter (the LWC populates it from the
  // cancel modal's dataset).
  public class CancelRequest {
    @AuraEnabled
    public Id instanceId;
    @AuraEnabled
    public Boolean runCompensations;
  }

  @AuraEnabled
  public static void cancelWorkflow(CancelRequest req) {
    checkAuthorization();
    try {
      WorkflowEngine.cancel(req.instanceId, req.runCompensations);
    } catch (Exception ex) {
      throw new AuraHandledException(ex.getMessage());
    }
  }

  // Request wrapper for submitApproval: keeps the single @AuraEnabled endpoint (the LWC
  // wraps its existing fields) while moving the approved flag off the parameter list.
  public class ApprovalRequest {
    @AuraEnabled
    public Id instanceId;
    @AuraEnabled
    public String approvalKey;
    @AuraEnabled
    public Boolean approved;
    @AuraEnabled
    public String comments;
  }

  @AuraEnabled
  public static void submitApproval(ApprovalRequest req) {
    checkAuthorization();
    // Enforce the approval gate's designated role BEFORE recording the decision, so a
    // dashboard admin cannot approve a gate they were not assigned to. Thrown before the
    // try/catch below so the specific message is not flattened into a generic one.
    enforceApprovalRole(req.instanceId, req.approvalKey);
    try {
      Map<String, Object> payload = new Map<String, Object>{
        'approved' => req.approved,
        'comments' => req.comments,
        // Record the immutable User Id (and username) as the authoritative approver
        // identity for the audit trail; the display name alone is mutable and not unique.
        'approverId' => UserInfo.getUserId(),
        'approverUsername' => UserInfo.getUserName(),
        'approver' => UserInfo.getName()
      };
      String payloadJson = JSON.serialize(payload);
      String signalName = 'Approve:' + req.approvalKey;

      WorkflowEngine.signal(
        String.valueOf(req.instanceId),
        signalName,
        payloadJson
      );
    } catch (Exception ex) {
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
    // A non-blank role is only ever returned for a matched, still-pending gate, so
    // checking the role alone reproduces the previous "gateFound && role" guard.
    String requiredRole = findRequiredApprovalRole(instanceId, approvalKey);
    if (
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

  // Returns the approvalRole designated by the most recent pending approval gate whose
  // key matches approvalKey (which may be null/blank when the gate designates no role),
  // or null when no pending gate matches. Stops at the first matching gate, mirroring
  // the previous inline scan.
  private static String findRequiredApprovalRole(
    Id instanceId,
    String approvalKey
  ) {
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
          return (String) state.get('approvalRole');
        }
      } catch (Exception ignored) {
      }
    }
    return null;
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
      Workflow_Instance__c latestWatchdog = watchdogInstances.isEmpty()
        ? null
        : watchdogInstances[0];

      // Total scheduled jobs. The bound is well above the platform ceiling on
      // CronTrigger rows (scheduled Apex is capped at 100), so it never truncates the
      // real count; it only satisfies the "queries must be bounded" rule.
      Integer scheduledJobsCount = [
        SELECT COUNT()
        FROM CronTrigger
        WITH SYSTEM_MODE
        LIMIT 50000
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

      Map<String, Object> config = new Map<String, Object>{
        'Use_Dynamic_Scheduling__c' => WorkflowEngine.useDynamicScheduling,
        'Watchdog_Delay_Minutes__c' => WorkflowEngine.watchdogDelayMinutes
      };

      List<Map<String, Object>> pausedDefs = new List<Map<String, Object>>();
      try {
        pausedDefs = getPausedDefinitions();
      } catch (Exception ignored) {
      }

      Map<String, Object> result = new Map<String, Object>{
        'isRunning' => isWatchdogRunning(watchdogInstances),
        'latestJob' => latestWatchdog,
        'recentJobs' => watchdogInstances,
        'scheduledJobsCount' => scheduledJobsCount,
        'sleepingInstances' => sleepingInstances,
        'pendingTimeouts' => pendingTimeouts,
        'config' => config,
        'pausedDefinitions' => pausedDefs
      };
      result.putAll(readAsyncLimits());
      return result;
    } catch (Exception ex) {
      throw new AuraHandledException(ex.getMessage());
    }
  }

  private static Boolean isWatchdogRunning(
    List<Workflow_Instance__c> watchdogInstances
  ) {
    if (watchdogInstances.isEmpty()) {
      return false;
    }
    String status = watchdogInstances[0].Status__c;
    return status == 'Pending' || status == 'Running' || status == 'Suspended';
  }

  // Reads the async-apex org limits into the dashboard's status keys. Missing limits
  // (e.g. no elastic-executions limit on this org) leave their defaults in place.
  private static Map<String, Object> readAsyncLimits() {
    Map<String, System.OrgLimit> limitsMap = System.OrgLimits.getMap();
    Map<String, Object> result = new Map<String, Object>{
      'dailyAsyncValue' => 0,
      'dailyAsyncLimit' => 0,
      'hasElasticLimit' => false,
      'elasticAsyncValue' => 0,
      'elasticAsyncLimit' => 0
    };
    if (limitsMap.containsKey('DailyAsyncApexExecutions')) {
      System.OrgLimit limitObj = limitsMap.get('DailyAsyncApexExecutions');
      result.put('dailyAsyncValue', limitObj.getValue());
      result.put('dailyAsyncLimit', limitObj.getLimit());
    }
    if (limitsMap.containsKey('DailyAsyncApexElasticExecutions')) {
      System.OrgLimit limitObj = limitsMap.get(
        'DailyAsyncApexElasticExecutions'
      );
      result.put('hasElasticLimit', true);
      result.put('elasticAsyncValue', limitObj.getValue());
      result.put('elasticAsyncLimit', limitObj.getLimit());
    }
    return result;
  }

  @AuraEnabled
  public static void enqueueWatchdog() {
    checkAuthorization();
    try {
      WorkflowWatchdog.bootstrap();
    } catch (Exception ex) {
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

    VersionDrainAccumulator acc = new VersionDrainAccumulator();

    Integer totalCount = [
      SELECT COUNT()
      FROM Workflow_Instance__c
      WHERE Workflow_Name__c = :workflowName
      WITH SYSTEM_MODE
    ];

    if (totalCount <= 40000) {
      accumulateVersionDrainByScan(workflowName, acc);
    } else {
      accumulateVersionDrainByAggregate(workflowName, acc);
    }

    return acc.toRows();
  }

  // Accumulates per-version (non-terminal / failed / clean-terminal) instance counts for
  // getVersionDrain and renders the sorted display rows. Centralizing the status-bucketing
  // keeps the two collection strategies (full scan vs. aggregate) from duplicating it.
  private class VersionDrainAccumulator {
    Map<String, Integer> nonTerminal = new Map<String, Integer>();
    Map<String, Integer> failed = new Map<String, Integer>();
    Map<String, Integer> terminal = new Map<String, Integer>();
    Map<String, Integer> versionKeyToInt = new Map<String, Integer>();

    void ensureVersion(String verKey, Integer verInt) {
      if (!nonTerminal.containsKey(verKey)) {
        nonTerminal.put(verKey, 0);
        failed.put(verKey, 0);
        terminal.put(verKey, 0);
        versionKeyToInt.put(verKey, verInt);
      }
    }

    void bucket(String verKey, String stat, Integer count) {
      if (NON_TERMINAL_STATUSES.contains(stat)) {
        nonTerminal.put(verKey, nonTerminal.get(verKey) + count);
      } else if (RECOVERABLE_TERMINAL_STATUSES.contains(stat)) {
        failed.put(verKey, failed.get(verKey) + count);
      } else {
        terminal.put(verKey, terminal.get(verKey) + count);
      }
    }

    List<Map<String, Object>> toRows() {
      // Sort version keys numerically (null sorts last)
      List<String> sortedKeys = new List<String>(nonTerminal.keySet());
      sortedKeys.sort();
      Integer nullKeyIdx = sortedKeys.indexOf('null');
      if (nullKeyIdx != -1) {
        sortedKeys.remove(nullKeyIdx);
        sortedKeys.add('null');
      }

      List<Map<String, Object>> rows = new List<Map<String, Object>>();
      for (String verKey : sortedKeys) {
        Integer nt = nonTerminal.get(verKey);
        Integer fl = failed.get(verKey);
        Integer tm = terminal.get(verKey);
        rows.add(
          new Map<String, Object>{
            'version' => versionKeyToInt.get(verKey),
            'nonTerminalCount' => nt,
            'failedCount' => fl,
            'terminalCount' => tm,
            'totalCount' => nt +
            fl +
            tm,
            'safeToRetire' => nt == 0 &&
            fl == 0
          }
        );
      }
      return rows;
    }
  }

  // Small definitions: a single full row scan buckets every instance by version + status.
  private static void accumulateVersionDrainByScan(
    String workflowName,
    VersionDrainAccumulator acc
  ) {
    for (Workflow_Instance__c inst : [
      SELECT Definition_Version__c, Status__c
      FROM Workflow_Instance__c
      WHERE Workflow_Name__c = :workflowName
      WITH SYSTEM_MODE
    ]) {
      Decimal verDecimal = inst.Definition_Version__c;
      Integer ver = verDecimal == null ? null : verDecimal.intValue();
      String verKey = ver == null ? 'null' : String.valueOf(ver);
      acc.ensureVersion(verKey, ver);
      acc.bucket(verKey, inst.Status__c, 1);
    }
  }

  // Large definitions: avoid materializing every row. Discover the observed versions via
  // two bounded queries, then bucket each version's status counts with a SINGLE GROUP BY
  // aggregate over just those versions (previously one aggregate per version in a loop).
  private static void accumulateVersionDrainByAggregate(
    String workflowName,
    VersionDrainAccumulator acc
  ) {
    Set<Decimal> versionDecimals = new Set<Decimal>();
    Boolean hasNullVersion = discoverDrainVersions(
      workflowName,
      versionDecimals
    );

    for (Decimal ver : versionDecimals) {
      Integer verInt = ver == null ? null : ver.intValue();
      acc.ensureVersion(String.valueOf(verInt), verInt);
    }

    if (!versionDecimals.isEmpty()) {
      for (AggregateResult ar : [
        SELECT Definition_Version__c ver, Status__c, COUNT(Id) cnt
        FROM Workflow_Instance__c
        WHERE
          Workflow_Name__c = :workflowName
          AND Definition_Version__c IN :versionDecimals
        WITH SYSTEM_MODE
        GROUP BY Definition_Version__c, Status__c
      ]) {
        Decimal verDecimal = (Decimal) ar.get('ver');
        Integer verInt = verDecimal == null ? null : verDecimal.intValue();
        acc.bucket(
          String.valueOf(verInt),
          (String) ar.get('Status__c'),
          (Integer) ar.get('cnt')
        );
      }
    }

    if (hasNullVersion) {
      acc.ensureVersion('null', null);
      for (AggregateResult ar : [
        SELECT Status__c, COUNT(Id) cnt
        FROM Workflow_Instance__c
        WHERE Workflow_Name__c = :workflowName AND Definition_Version__c = NULL
        WITH SYSTEM_MODE
        GROUP BY Status__c
      ]) {
        acc.bucket(
          'null',
          (String) ar.get('Status__c'),
          (Integer) ar.get('cnt')
        );
      }
    }
  }

  // Populates versionDecimals with the non-null Definition_Version__c values observed in
  // the active/failed slice (up to 5000) and the most recent 10000 runs; returns true if
  // any null-version instance was seen.
  private static Boolean discoverDrainVersions(
    String workflowName,
    Set<Decimal> versionDecimals
  ) {
    Boolean hasNullVersion = false;
    for (Workflow_Instance__c inst : [
      SELECT Definition_Version__c
      FROM Workflow_Instance__c
      WHERE
        Workflow_Name__c = :workflowName
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
    return hasNullVersion;
  }

  // ── Unrouted-signal dashboard methods ─────────────────────────────────────

  // Query criteria for the unrouted-signal list. Field-based (@AuraEnabled properties) so the
  // LWC and tests populate it by assignment. cacheBuster only varies the client-side cache key
  // and is unused in Apex.
  public class UnroutedQuery {
    @AuraEnabled
    public String searchTerm;
    @AuraEnabled
    public Integer limitSize;
    @AuraEnabled
    public Integer offsetSize;
    @AuraEnabled
    public String cacheBuster;
  }

  @AuraEnabled(cacheable=true)
  public static List<Map<String, Object>> getUnroutedSignals(
    UnroutedQuery criteria
  ) {
    checkAuthorization();

    String searchTerm = criteria.searchTerm;
    Integer limitSize = criteria.limitSize;
    Integer offsetSize = criteria.offsetSize;

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
      // Bound the scan well above any realistic paused-definition count (one row per
      // paused definition) so the result is never truncated; satisfies the bounded-query
      // rule without altering the set the dashboard shows.
      List<Workflow_Pause_State__c> pauseRecords = [
        SELECT Workflow_Name__c, Reason__c, CreatedById, CreatedDate
        FROM Workflow_Pause_State__c
        WITH SYSTEM_MODE
        ORDER BY CreatedDate ASC
        LIMIT 50000
      ];

      if (pauseRecords.isEmpty()) {
        return new List<Map<String, Object>>();
      }

      ParkedCounts parked = countParkedByDefinition(pauseRecords);

      List<Map<String, Object>> result = new List<Map<String, Object>>();
      for (Workflow_Pause_State__c r : pauseRecords) {
        result.add(
          new Map<String, Object>{
            'workflowName' => r.Workflow_Name__c,
            'reason' => r.Reason__c,
            'pausedAt' => r.CreatedDate,
            'parkedCount' => parked.forRecord(r)
          }
        );
      }
      return result;
    } catch (Exception ex) {
      throw new AuraHandledException(ex.getMessage());
    }
  }

  // Parked (Paused-status) instance counts per definition, plus the org-wide total used
  // when a wildcard ('*') pause is present.
  private class ParkedCounts {
    Map<String, Integer> countByDef = new Map<String, Integer>();
    Integer totalParked = 0;

    Integer forRecord(Workflow_Pause_State__c r) {
      if (r.Workflow_Name__c == '*') {
        return totalParked;
      }
      // Workflow_Name__c is a case-insensitive external id but an Apex Map key is
      // case-sensitive, so look up by the same lower-cased key used when building the map.
      String key = r.Workflow_Name__c == null
        ? null
        : r.Workflow_Name__c.toLowerCase();
      return countByDef.containsKey(key) ? countByDef.get(key) : 0;
    }
  }

  private static ParkedCounts countParkedByDefinition(
    List<Workflow_Pause_State__c> pauseRecords
  ) {
    Set<String> pausedNames = new Set<String>();
    Boolean wildcardPaused = false;
    for (Workflow_Pause_State__c r : pauseRecords) {
      pausedNames.add(r.Workflow_Name__c);
      if (r.Workflow_Name__c == '*') {
        wildcardPaused = true;
      }
    }

    List<AggregateResult> counts = wildcardPaused
      ? queryParkedCountsAll()
      : queryParkedCountsFor(pausedNames);

    ParkedCounts parked = new ParkedCounts();
    for (AggregateResult ar : counts) {
      String name = (String) ar.get('Workflow_Name__c');
      // Grouped COUNT(Id) is returned as Integer in this org (see getWorkflowStats);
      // a Decimal cast throws TypeException as soon as a definition has parked rows.
      Integer cnt = (Integer) ar.get('cnt');
      // Normalize the key to lower case (mirrored in ParkedCounts.forRecord) so a pause
      // record created with different casing than its instances still resolves its count.
      parked.countByDef.put(name == null ? null : name.toLowerCase(), cnt);
      parked.totalParked += cnt;
    }
    return parked;
  }

  private static List<AggregateResult> queryParkedCountsAll() {
    return [
      SELECT Workflow_Name__c, COUNT(Id) cnt
      FROM Workflow_Instance__c
      WHERE Status__c = 'Paused'
      WITH SYSTEM_MODE
      GROUP BY Workflow_Name__c
    ];
  }

  private static List<AggregateResult> queryParkedCountsFor(
    Set<String> pausedNames
  ) {
    return [
      SELECT Workflow_Name__c, COUNT(Id) cnt
      FROM Workflow_Instance__c
      WHERE Status__c = 'Paused' AND Workflow_Name__c IN :pausedNames
      WITH SYSTEM_MODE
      GROUP BY Workflow_Name__c
    ];
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
      // Bounded well above any realistic governed-workflow count (one row per durable
      // Concurrency_State__c counter) so the result set is never truncated.
      List<Concurrency_State__c> states = [
        SELECT Workflow_Definition__c, In_Flight_Count__c
        FROM Concurrency_State__c
        WITH SYSTEM_MODE
        ORDER BY Workflow_Definition__c ASC
        LIMIT 50000
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
      throw new AuraHandledException(ex.getMessage());
    }
  }

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

    Datetime since = resolveWindowStart(timeWindow);
    List<Workflow_Step_Execution__c> steps = queryFailedSteps(
      workflowName,
      since
    );

    List<StepFailureGroup> sortedSteps = groupFailuresByStep(steps);
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

  // Resolves the start of a recognized trend window (blank/unknown → null = "all time").
  private static Datetime resolveWindowStart(String timeWindow) {
    if (
      String.isBlank(timeWindow) || !TREND_WINDOW_HOURS.containsKey(timeWindow)
    ) {
      return null;
    }
    return Datetime.now().addHours(-TREND_WINDOW_HOURS.get(timeWindow));
  }

  private static List<Workflow_Step_Execution__c> queryFailedSteps(
    String workflowName,
    Datetime since
  ) {
    if (since != null) {
      return [
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
    }
    return [
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

  private static List<StepFailureGroup> groupFailuresByStep(
    List<Workflow_Step_Execution__c> steps
  ) {
    Map<String, StepFailureGroup> stepGroups = new Map<String, StepFailureGroup>();
    for (Workflow_Step_Execution__c se : steps) {
      String stepName = String.isBlank(se.Step_Name__c)
        ? 'Unknown Step'
        : se.Step_Name__c;
      StepFailureGroup stepGroup = stepGroups.get(stepName);
      if (stepGroup == null) {
        stepGroup = new StepFailureGroup(stepName);
        stepGroups.put(stepName, stepGroup);
      }
      stepGroup.addFailure(se);
    }
    List<StepFailureGroup> sortedSteps = stepGroups.values();
    sortedSteps.sort();
    return sortedSteps;
  }

  @TestVisible
  private static String getNormalizedSignature(String errorDetails) {
    if (String.isBlank(errorDetails)) {
      return 'Unknown Error';
    }
    String normalized = errorDetails.split('\n')[0];
    if (String.isBlank(normalized)) {
      normalized = 'Unknown Error';
    }

    // Normalize UUIDs
    normalized = normalized.replaceAll(
      '\\b[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}\\b',
      '[UUID]'
    );

    // Normalize Datetimes
    normalized = normalized.replaceAll(
      '\\b\\d{4}-\\d{2}-\\d{2}[T ]\\d{2}:\\d{2}:\\d{2}(?:\\.\\d+)?(?:Z|[+-]\\d{2}:?\\d{2})?\\b',
      '[DATETIME]'
    );

    // Normalize Dates
    normalized = normalized.replaceAll('\\b\\d{4}-\\d{2}-\\d{2}\\b', '[DATE]');

    // Normalize Salesforce IDs containing at least one digit
    normalized = normalized.replaceAll(
      '\\b(?=[a-zA-Z0-9]*[0-9])[a-zA-Z0-9]{15,18}\\b',
      '[ID]'
    );

    // Normalize standalone numbers
    normalized = normalized.replaceAll('\\b\\d+\\b', '[NUM]');

    normalized = normalized.trim();
    if (normalized.length() > 255) {
      normalized = normalized.substring(0, 252) + '...';
    }

    return normalized;
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

  @AuraEnabled
  public static void injectSignal(
    Id instanceId,
    String signalName,
    String payloadJson
  ) {
    checkAuthorization();
    validateSignalInjectionPermission();

    if (instanceId == null) {
      throw auraError('Instance ID is required.');
    }
    if (String.isBlank(signalName)) {
      throw auraError('Signal name is required.');
    }
    requireInjectableInstance(instanceId);

    Map<String, Object> payloadMap = parseInjectionPayload(payloadJson);
    payloadMap.put('operatorId', UserInfo.getUserId());
    payloadMap.put('operatorUsername', UserInfo.getUserName());
    payloadMap.put('operator', UserInfo.getName());

    try {
      WorkflowEngine.signal(
        String.valueOf(instanceId),
        signalName,
        JSON.serialize(payloadMap)
      );
    } catch (Exception ex) {
      throw auraError(ex.getMessage());
    }
  }

  // Builds an AuraHandledException whose getMessage() returns the supplied text (the
  // explicit setMessage is required so the specific message survives to the client
  // instead of the generic "Script-thrown exception").
  private static AuraHandledException auraError(String message) {
    AuraHandledException ex = new AuraHandledException(message);
    ex.setMessage(message);
    return ex;
  }

  private static void validateSignalInjectionPermission() {
    if (
      !FeatureManagement.checkPermission('Workflow_Signal_Injection') &&
      !currentUserHasModifyAllData()
    ) {
      throw auraError(
        'Unauthorized: this action requires the "Workflow_Signal_Injection" permission.'
      );
    }
  }

  private static void requireInjectableInstance(Id instanceId) {
    List<Workflow_Instance__c> instances = [
      SELECT Status__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
      WITH SYSTEM_MODE
      LIMIT 1
    ];
    if (instances.isEmpty()) {
      throw auraError('Workflow instance not found.');
    }
    if (instances[0].Status__c != 'Suspended') {
      throw auraError(
        'Signal injection is only allowed on Suspended instances.'
      );
    }
  }

  private static Map<String, Object> parseInjectionPayload(String payloadJson) {
    if (payloadJson != null && payloadJson.length() > 250000) {
      throw auraError('Payload size exceeds maximum allowed limit of 250KB.');
    }
    if (String.isBlank(payloadJson)) {
      return new Map<String, Object>();
    }
    Object parsed = deserializePayloadObject(payloadJson);
    if (parsed instanceof Map<String, Object>) {
      return (Map<String, Object>) parsed;
    }
    throw auraError(
      'Invalid payload JSON: Payload JSON must be a JSON object (e.g., {"key": "value"}).'
    );
  }

  private static Object deserializePayloadObject(String payloadJson) {
    try {
      return JSON.deserializeUntyped(payloadJson);
    } catch (Exception ex) {
      throw auraError('Invalid payload JSON: ' + ex.getMessage());
    }
  }
}
