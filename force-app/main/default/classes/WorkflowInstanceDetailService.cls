/**
 * @description Loads the full detail view for one workflow instance: the record, its
 * steps, children, successor, search attributes, breadcrumb log, pending compensations,
 * and resolved payload download descriptors. Extracted from WorkflowDashboardController;
 * all SOQL runs WITH SYSTEM_MODE and payload resolution is delegated to
 * WorkflowPayloadService.
 */
public inherited sharing class WorkflowInstanceDetailService {
  /** @description Max step rows in the detail window (newest first). */
  public static final Integer MAX_STEP_ROWS = 500;

  /** @description Newest rows that carry Input, Output and error text. */
  public static final Integer LONG_TEXT_ROWS = 50;

  // Upper bound of the step row count. COUNT() uses one query row.
  private static final Integer STEP_COUNT_CAP = 50000;

  /**
   * @description Loads the full detail view for one instance.
   * @param instanceId The workflow instance to load details for.
   * @return A map of the instance detail sections consumed by the detail LWC.
   */
  public static Map<String, Object> loadDetails(Id instanceId) {
    WorkflowDashboardSupport.checkAuthorization();
    if (instanceId == null) {
      AuraHandledException ex = new AuraHandledException(
        'instanceId is required.'
      );
      ex.setMessage('instanceId is required.');
      throw ex;
    }
    Workflow_Instance__c instance = loadInstanceDetailRecord(instanceId);

    Integer stepCount = [
      SELECT COUNT()
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c = :instanceId
      WITH SYSTEM_MODE
      LIMIT :STEP_COUNT_CAP
    ];
    List<Workflow_Step_Execution__c> steps = loadStepWindow(instanceId);
    // Derive the awaited-signal descriptor from the parked step state BEFORE payload
    // resolution mutates (and may truncate) the step Output fields for display; the
    // service rehydrates any offloaded output itself through WorkflowPayloadOffload.
    Map<String, Object> waitDescriptor = WorkflowWaitDescriptorService.describeSignalWait(
      instance,
      steps
    );

    Map<String, Object> payloadFiles = WorkflowPayloadService.resolvePayloadsInBulk(
      instance,
      steps
    );

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
      // The window holds the newest MAX_STEP_ROWS rows (issue #261).
      'stepsTruncated' => stepCount > MAX_STEP_ROWS,
      'stepCount' => stepCount,
      'children' => children,
      'successor' => successors.isEmpty() ? null : successors[0],
      'waitingOn' => computeDetailWaitingOn(instance),
      'waitDescriptor' => waitDescriptor,
      'pendingCompensationCount' => pendingCompensations.size(),
      'pendingCompensations' => pendingCompensations,
      'payloadFiles' => payloadFiles,
      'attributes' => attributes,
      'breadcrumbs' => breadcrumbs,
      // Stored-versus-live steps for a DefinitionChanged park (issue #89), else null.
      'definitionChange' => WorkflowDefinitionChangeService.describe(instance),
      // Issue #119: true when hold accepts this instance.
      'holdable' => WorkflowInstanceHold.isHoldable(instance),
      // Step-history warning (issue #112), else null.
      'stepHistoryWarning' => WorkflowStepHistoryGuard.describeWarning(
        instanceId
      )
    };
  }

  // Reads the newest MAX_STEP_ROWS rows without long text. Then reads the long
  // text for the newest LONG_TEXT_ROWS rows and the latest parked (Pending) row.
  // Returns the rows in ascending order. A row with no long text has null fields.
  private static List<Workflow_Step_Execution__c> loadStepWindow(
    Id instanceId
  ) {
    Integer maxRows = MAX_STEP_ROWS;
    List<Workflow_Step_Execution__c> newest = [
      SELECT
        Id,
        Step_Name__c,
        Status__c,
        Retry_Count__c,
        CPU_Time_Ms__c,
        SOQL_Query_Count__c,
        Heap_Size_Bytes__c,
        CreatedDate
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c = :instanceId
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC, Id DESC
      LIMIT :maxRows
    ];
    Set<Id> windowIds = new Set<Id>();
    Set<Id> textIds = new Set<Id>();
    for (Integer i = 0; i < newest.size(); i++) {
      windowIds.add(newest[i].Id);
      if (i < LONG_TEXT_ROWS) {
        textIds.add(newest[i].Id);
      }
    }
    // The wait descriptor needs the parked row, even when it is older.
    List<Workflow_Step_Execution__c> parked = [
      SELECT Id
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c = :instanceId AND Status__c = 'Pending'
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC, Id DESC
      LIMIT 1
    ];
    Id parkedId = parked.isEmpty() ? null : parked[0].Id;
    if (parkedId != null) {
      textIds.add(parkedId);
    }
    Map<Id, Workflow_Step_Execution__c> withText = new Map<Id, Workflow_Step_Execution__c>(
      [
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
        WHERE Id IN :textIds
        WITH SYSTEM_MODE
      ]
    );

    List<Workflow_Step_Execution__c> steps = new List<Workflow_Step_Execution__c>();
    if (parkedId != null && !windowIds.contains(parkedId)) {
      steps.add(withText.get(parkedId));
    }
    for (Integer i = newest.size() - 1; i >= 0; i--) {
      Workflow_Step_Execution__c row = withText.get(newest[i].Id);
      if (row == null) {
        row = newest[i];
        row.Input__c = null;
        row.Output__c = null;
        row.Error_Details__c = null;
      }
      steps.add(row);
    }
    return steps;
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
        Progress__c,
        Definition_Fingerprint__c,
        Definition_Shape__c,
        Held__c,
        Held_At__c,
        Hold_Reason__c
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

  // Detail-view "waiting on" resolution. Unlike the list path (which uses pre-queried
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
    if (!WorkflowDashboardSupport.isJobIdShaped(jobIdStr)) {
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
}
