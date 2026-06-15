public inherited sharing class StepContext {
  public Id workflowInstanceId { get; set; }
  public String workflowName { get; set; }
  public String stepName { get; set; }
  public String inputJson { get; set; }
  public String previousStepOutput { get; set; }
  public String stepStateJson { get; set; }
  public String workflowInputJson { get; set; }
  public Integer workflowVersion { get; set; }

  // 0-based sequence of this visit to `stepName` within this instance: the count
  // of already-completed executions of the step when this context was built. It
  // stays constant across retries/re-drives/resumes of the current (not yet
  // completed) visit, and increments only when the engine loops back to the same
  // step for a fresh visit. Populated by the engine; defaults to 0.
  private Integer stepVisit = 0;

  /**
   * A stable, read-only idempotency key for this logical step execution.
   *
   * The engine guarantees only at-least-once execution: execute() (and
   * compensate()) may run more than once for the same logical step on transient
   * RetryPolicy/WorkflowRetryJob retries, on operator re-drive, and on
   * at-least-once Workflow_Event__e resumes. Forward this key to a non-idempotent
   * external system (e.g. as a Stripe `Idempotency-Key` header) to get
   * effective-once side effects despite that contract.
   *
   * Guarantees:
   * - Stable across every re-execution of the same step VISIT: retries,
   *   re-drives, and resumes of the current (not-yet-completed) visit all observe
   *   the identical key. It is derived from `workflowInstanceId` + `stepName` +
   *   the visit sequence, never from the per-attempt, append-only
   *   Workflow_Step_Execution__c record Id.
   * - Distinct per (instance, step): different steps in one instance, the same
   *   step in two different instances, and the same step name across two parallel
   *   fan-out branch instances (different Parent_Instance__c, hence different
   *   `workflowInstanceId`) each observe a different key.
   * - Distinct per visit: when a workflow loops back to the same step in the same
   *   instance (the engine inserts a fresh execution for each transition), each
   *   completed visit observes a different key, so distinct side effects in
   *   loop/polling workflows are not wrongly deduped as retries.
   * - For compensate(), the engine builds the context with stepName
   *   "<step>_Compensate", so the compensation key is automatically stable for a
   *   given forward step yet distinct from that step's own forward key.
   */
  public String idempotencyKey {
    get {
      return deriveIdempotencyKey(
        this.workflowInstanceId,
        this.stepName,
        this.stepVisit
      );
    }
  }

  @TestVisible
  private static Double mockQueryRowsFraction = null;
  @TestVisible
  private static Double mockAsyncExecutionsFraction = null;

  public StepContext(
    Id workflowInstanceId,
    String workflowName,
    String stepName,
    String inputJson,
    String previousStepOutput,
    String stepStateJson,
    String workflowInputJson
  ) {
    this(
      workflowInstanceId,
      workflowName,
      stepName,
      inputJson,
      previousStepOutput,
      stepStateJson,
      workflowInputJson,
      1
    );
  }

  public StepContext(
    Id workflowInstanceId,
    String workflowName,
    String stepName,
    String inputJson,
    String previousStepOutput,
    String stepStateJson,
    String workflowInputJson,
    Integer workflowVersion
  ) {
    this(
      workflowInstanceId,
      workflowName,
      stepName,
      inputJson,
      previousStepOutput,
      stepStateJson,
      workflowInputJson,
      workflowVersion,
      0
    );
  }

  public StepContext(
    Id workflowInstanceId,
    String workflowName,
    String stepName,
    String inputJson,
    String previousStepOutput,
    String stepStateJson,
    String workflowInputJson,
    Integer workflowVersion,
    Integer stepVisit
  ) {
    this.workflowInstanceId = workflowInstanceId;
    this.workflowName = workflowName;
    this.stepName = stepName;
    this.inputJson = inputJson;
    this.previousStepOutput = previousStepOutput;
    this.stepStateJson = stepStateJson;
    this.workflowInputJson = workflowInputJson;
    this.workflowVersion = workflowVersion;
    this.stepVisit = (stepVisit != null && stepVisit > 0) ? stepVisit : 0;
  }

  /**
   * Checks if the current transaction is approaching governor limits.
   * Returns true if any monitored limit (CPU, SOQL, DML statements, DML rows, or Heap size) is > 80% consumed.
   */
  public Boolean shouldYield() {
    // CPU Time
    if (
      Limits.getLimitCpuTime() > 0 &&
      ((Double) Limits.getCpuTime() / Limits.getLimitCpuTime()) > 0.80
    ) {
      return true;
    }
    // SOQL Queries
    if (
      Limits.getLimitQueries() > 0 &&
      ((Double) Limits.getQueries() / Limits.getLimitQueries()) > 0.80
    ) {
      return true;
    }
    // SOQL Query Rows
    Double queryRowsFraction = mockQueryRowsFraction != null
      ? mockQueryRowsFraction
      : (Limits.getLimitQueryRows() > 0
          ? ((Double) Limits.getQueryRows() / Limits.getLimitQueryRows())
          : 0.0);
    if (queryRowsFraction > 0.80) {
      return true;
    }
    // DML Statements
    if (
      Limits.getLimitDmlStatements() > 0 &&
      ((Double) Limits.getDmlStatements() / Limits.getLimitDmlStatements()) >
      0.80
    ) {
      return true;
    }
    // DML Rows
    if (
      Limits.getLimitDmlRows() > 0 &&
      ((Double) Limits.getDmlRows() / Limits.getLimitDmlRows()) > 0.80
    ) {
      return true;
    }
    // Heap Size
    if (
      Limits.getLimitHeapSize() > 0 &&
      ((Double) Limits.getHeapSize() / Limits.getLimitHeapSize()) > 0.80
    ) {
      return true;
    }
    // Daily Async Apex Executions Limit (accounts for Beta Elastic Limits if enabled)
    Double asyncFraction = mockAsyncExecutionsFraction;
    if (asyncFraction == null) {
      Map<String, System.OrgLimit> limitsMap = System.OrgLimits.getMap();
      if (limitsMap.containsKey('DailyAsyncApexExecutions')) {
        System.OrgLimit dailyLimitObj = limitsMap.get(
          'DailyAsyncApexExecutions'
        );
        Integer limitValue = dailyLimitObj.getValue();
        Integer maxLimit = dailyLimitObj.getLimit();

        if (limitsMap.containsKey('DailyAsyncApexElasticExecutions')) {
          System.OrgLimit elasticLimitObj = limitsMap.get(
            'DailyAsyncApexElasticExecutions'
          );
          maxLimit = elasticLimitObj.getLimit();
        }

        if (maxLimit > 0) {
          asyncFraction = (Double) limitValue / maxLimit;
        }
      }
    }
    if (asyncFraction != null && asyncFraction > 0.80) {
      return true;
    }
    return false;
  }

  /**
   * Derives the idempotency key from logical (instance, step, visit) identity
   * only. SHA-256 keeps it opaque, uniform-length, and safe to forward verbatim
   * as an external idempotency token.
   */
  private static String deriveIdempotencyKey(
    Id instanceId,
    String stepName,
    Integer stepVisit
  ) {
    String basis =
      (instanceId == null ? '' : String.valueOf(instanceId)) +
      '::' +
      (stepName == null ? '' : stepName) +
      '::' +
      String.valueOf(stepVisit == null ? 0 : stepVisit);
    Blob digest = Crypto.generateDigest('SHA-256', Blob.valueOf(basis));
    return EncodingUtil.convertToHex(digest);
  }
}
