/**
 * @description Best-effort step-log (breadcrumb) persistence for the Revenant
 * engine. After a step outcome is handled, this class writes the step's
 * breadcrumb logs as `Workflow_Log__c` records, but only when the remaining SOQL
 * and DML governor budgets can absorb them without risking the durable
 * checkpoint; otherwise the breadcrumbs are dropped. Extracted from
 * `WorkflowEngine`; the engine's outcome handlers call
 * {@link WorkflowBreadcrumbs#persistStepBreadcrumbs}. All SOQL and DML run in
 * system mode.
 */
public inherited sharing class WorkflowBreadcrumbs {
  /**
   * @description DML-statement headroom reserved for the checkpoint so
   * breadcrumb inserts never consume the last statements. @TestVisible so a test
   * can tighten the reserve to exercise budget exhaustion.
   */
  @TestVisible
  private static Integer breadcrumbDmlStatementReserve = 10;
  /**
   * @description DML-row headroom reserved for the checkpoint so breadcrumb
   * inserts never consume the last rows. @TestVisible for budget-exhaustion
   * tests.
   */
  @TestVisible
  private static Integer breadcrumbDmlRowReserve = 20;
  /**
   * @description SOQL-query headroom reserved for the checkpoint so breadcrumb
   * accounting never consumes the last queries. @TestVisible for
   * budget-exhaustion tests.
   */
  @TestVisible
  private static Integer breadcrumbSoqlReserve = 5;

  /**
   * @description Persists the step's breadcrumb logs when the SOQL and DML
   * budgets allow, dropping them best-effort otherwise so observability never
   * jeopardizes the durable checkpoint.
   * @param outcome the step outcome bundle carrying instance, step exec and
   * context
   */
  public static void persistStepBreadcrumbs(
    WorkflowEngine.StepOutcomeContext outcome
  ) {
    Workflow_Instance__c instance = outcome.instance;
    Workflow_Step_Execution__c stepExec = outcome.stepExec;
    StepContext context = outcome.context;
    if (context == null || stepExec == null || instance == null) {
      return;
    }
    List<StepContext.Breadcrumb> crumbs = context.logger().getBreadcrumbs();
    if (crumbs == null || crumbs.isEmpty()) {
      return;
    }

    // Keep breadcrumbs from exhausting checkpoint SOQL (best-effort observability log drop)
    if (
      Limits.getQueries() + breadcrumbSoqlReserve > Limits.getLimitQueries()
    ) {
      // SOQL budget exhausted; drop best-effort breadcrumbs rather than risk the checkpoint.
      return;
    }

    Integer dynamicRowReserve = computeBreadcrumbRowReserve(outcome);

    // Keep breadcrumbs from exhausting checkpoint DML (best-effort observability log drop)
    if (breadcrumbDmlBudgetExceeded(crumbs.size(), dynamicRowReserve)) {
      // DML budget exhausted; drop best-effort breadcrumbs rather than risk the checkpoint.
      return;
    }

    if (stepExec.Id == null) {
      WorkflowStepExecStore.saveStepExec(stepExec);
    }

    insertBreadcrumbLogs(outcome, crumbs);
  }

  /**
   * @description Reports whether inserting the breadcrumbs would breach the
   * DML-statement or DML-row governor limits once the checkpoint's reserves are
   * accounted for.
   * @param crumbCount number of breadcrumb rows to insert
   * @param dynamicRowReserve extra rows the checkpoint may insert
   * @return true when the breadcrumbs would exceed a DML budget
   */
  private static Boolean breadcrumbDmlBudgetExceeded(
    Integer crumbCount,
    Integer dynamicRowReserve
  ) {
    return Limits.getDmlStatements() + 1 + breadcrumbDmlStatementReserve >
      Limits.getLimitDmlStatements() ||
      Limits.getDmlRows() + crumbCount + breadcrumbDmlRowReserve +
      dynamicRowReserve > Limits.getLimitDmlRows();
  }

  /**
   * @description Best-effort estimate of the extra DML rows the checkpoint may
   * insert, used to decide whether breadcrumb logs fit within the remaining DML
   * budget.
   * @param outcome the step outcome bundle
   * @return the estimated reserve row count
   */
  private static Integer computeBreadcrumbRowReserve(
    WorkflowEngine.StepOutcomeContext outcome
  ) {
    StepResult result = outcome.result;
    if (result == null) {
      return 0;
    }
    Integer dynamicRowReserve = 0;
    dynamicRowReserve += reserveForChildRequests(
      result.directive().childRequests
    );
    dynamicRowReserve += reserveForParallelSteps(result, outcome.stepExec);
    if (result.directive().outboundEvents != null) {
      dynamicRowReserve += result.directive().outboundEvents.size();
    }
    dynamicRowReserve += computeSignalCleanupRowReserve(outcome);
    return dynamicRowReserve;
  }

  /**
   * @description Reserve for the child-instance DML a start-child directive may
   * perform, including offloaded input payloads.
   * @param childRequests the child requests from the step directive
   * @return the estimated reserve row count
   */
  private static Integer reserveForChildRequests(
    List<StepResult.ChildRequest> childRequests
  ) {
    Integer reserve = 0;
    if (childRequests == null) {
      return reserve;
    }
    for (StepResult.ChildRequest req : childRequests) {
      reserve += 3;
      if (String.isNotBlank(req.inputJson) && req.inputJson.length() > 100000) {
        reserve += 2; // ContentVersion + ContentDocumentLink
      }
    }
    return reserve;
  }

  /**
   * @description Reserve for the parallel step-execution DML a split directive
   * may perform, including offloaded parallel input payloads.
   * @param result the step result carrying the directive
   * @param stepExec the current step execution (source of fallback payload)
   * @return the estimated reserve row count
   */
  private static Integer reserveForParallelSteps(
    StepResult result,
    Workflow_Step_Execution__c stepExec
  ) {
    Integer reserve = 0;
    if (result.directive().parallelStepNames == null) {
      return reserve;
    }
    for (String ps : result.directive().parallelStepNames) {
      reserve += 1;
      String inputPayload = result.directive().parallelInputJson != null
        ? result.directive().parallelInputJson
        : stepExec.Output__c;
      if (String.isNotBlank(inputPayload) && inputPayload.length() > 100000) {
        reserve += 2; // ContentVersion + ContentDocumentLink
      }
    }
    return reserve;
  }

  /**
   * @description Reserve for the signal-cleanup DML the checkpoint performs when
   * the step consumes signals (COMPLETE / SPLIT / FAIL). Only reached with a
   * non-null result (guarded by the caller).
   * @param outcome the step outcome bundle
   * @return the estimated reserve row count
   */
  private static Integer computeSignalCleanupRowReserve(
    WorkflowEngine.StepOutcomeContext outcome
  ) {
    StepResult result = outcome.result;
    StepContext context = outcome.context;
    Workflow_Instance__c instance = outcome.instance;
    Boolean willConsumeSignals = (result.directive().action ==
    StepResult.ActionType.COMPLETE ||
    result.directive().action == StepResult.ActionType.SPLIT ||
    result.directive().action == StepResult.ActionType.FAIL);
    if (!willConsumeSignals) {
      return 0;
    }
    Set<String> matchedNames = context.signals().getConsumedSignalNames();
    if (matchedNames == null || matchedNames.isEmpty()) {
      return 0;
    }
    Boolean isParallel =
      String.isNotBlank(instance.Current_Step__c) &&
      instance.Current_Step__c.contains(',');
    Boolean runDuplicateCleanup =
      !isParallel && !context.signals().signalReadWasCapped();
    if (runDuplicateCleanup) {
      return reserveForDuplicateCleanup(instance, context, matchedNames);
    }
    return reserveForConsumedSignals(context);
  }

  /**
   * @description Reserve for the duplicate-signal cleanup DML on a serial step,
   * counting Received matches and any claimed Processing rows.
   * @param instance the running instance
   * @param context the step context carrying claimed signal ids
   * @param matchedNames the consumed signal names
   * @return the estimated reserve row count
   */
  private static Integer reserveForDuplicateCleanup(
    Workflow_Instance__c instance,
    StepContext context,
    Set<String> matchedNames
  ) {
    Integer reserve = [
      SELECT COUNT()
      FROM Workflow_Signal__c
      WHERE
        Workflow_Instance__c = :instance.Id
        AND Status__c = 'Received'
        AND Signal_Name__c IN :matchedNames
      WITH SYSTEM_MODE
    ];
    Set<Id> claimedIds = context.signals().getClaimedSignalIds();
    if (claimedIds != null && !claimedIds.isEmpty()) {
      reserve += [
        SELECT COUNT()
        FROM Workflow_Signal__c
        WHERE Id IN :claimedIds AND Status__c = 'Processing'
        WITH SYSTEM_MODE
      ];
    }
    return reserve;
  }

  /**
   * @description Reserve for the consumed-signal cleanup DML, counting the
   * claimed and consumed rows still in a Received or Processing state.
   * @param context the step context carrying consumed and claimed signal ids
   * @return the estimated reserve row count
   */
  private static Integer reserveForConsumedSignals(StepContext context) {
    Set<Id> consumedIds = context.signals().getConsumedSignalIds();
    Set<Id> claimedIds = context.signals().getClaimedSignalIds();
    Set<Id> allIds = new Set<Id>();
    if (consumedIds != null) {
      allIds.addAll(consumedIds);
    }
    if (claimedIds != null) {
      allIds.addAll(claimedIds);
    }
    if (allIds.isEmpty()) {
      return 0;
    }
    return [
      SELECT COUNT()
      FROM Workflow_Signal__c
      WHERE Id IN :allIds AND Status__c IN ('Received', 'Processing')
      WITH SYSTEM_MODE
    ];
  }

  /**
   * @description Inserts the breadcrumb logs as `Workflow_Log__c` records
   * correlated to the step execution.
   * @param outcome the step outcome bundle carrying instance and step exec
   * @param crumbs the breadcrumbs to persist
   */
  private static void insertBreadcrumbLogs(
    WorkflowEngine.StepOutcomeContext outcome,
    List<StepContext.Breadcrumb> crumbs
  ) {
    Workflow_Instance__c instance = outcome.instance;
    Workflow_Step_Execution__c stepExec = outcome.stepExec;
    List<Workflow_Log__c> logsToInsert = new List<Workflow_Log__c>();
    for (StepContext.Breadcrumb b : crumbs) {
      logsToInsert.add(
        new Workflow_Log__c(
          Workflow_Instance__c = instance.Id,
          Workflow_Name__c = instance.Workflow_Name__c,
          Correlation_Key__c = stepExec.Id,
          Log_Type__c = StepContext.LOG_TYPE_BREADCRUMB,
          Level__c = (b.level != null) ? b.level.name() : 'INFO',
          Message__c = b.message,
          Fire_Time__c = b.timestamp
        )
      );
    }
    Database.insert(logsToInsert, true, AccessLevel.SYSTEM_MODE);
  }
}
