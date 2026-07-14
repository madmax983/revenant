/**
 * @description Prior-execution index for named change markers (patches), split
 * out of StepCaptures. Loads (once per context) the instance's earlier step
 * executions to resolve the patch-decision inputs: which visits already completed
 * (so a re-execution keeps its prior branch) and any __patch: decisions already
 * recorded, plus the instance CreatedDate and calling-class LastModifiedDate used
 * to decide a brand-new marker. Owns all SOQL for that index.
 */
public inherited sharing class StepExecutionIndex {
  /** Prior __patch: decisions recorded by earlier steps in this instance. */
  private Map<String, Boolean> patchDecisionsCache = new Map<String, Boolean>();
  /** Per-visit completion markers ("<step>:<visit>") from prior executions. */
  private Set<String> completedStepsCache = new Set<String>();
  /** True once the prior-execution index has been loaded. */
  private Boolean hasLoadedExecutions = false;
  /** The instance's CreatedDate, resolved lazily for patch decisions. */
  private DateTime instanceCreatedDate = null;
  /** The calling class's LastModifiedDate, resolved lazily for patch decisions. */
  private DateTime classLastModified = null;

  /** The owning StepContext, for the step's identity fields. */
  private final StepContext ctx;
  /** The step's 0-based visit sequence within the instance. */
  private final Integer stepVisit;

  @TestVisible
  private static DateTime mockInstanceCreatedDate = null;
  @TestVisible
  private static DateTime mockClassLastModified = null;

  /**
   * @description Constructs the prior-execution index bound to its owning context.
   * @param ctx The owning StepContext supplying the step's identity fields.
   * @param stepVisit The step's 0-based visit sequence within the instance.
   */
  public StepExecutionIndex(StepContext ctx, Integer stepVisit) {
    this.ctx = ctx;
    this.stepVisit = stepVisit;
  }

  /**
   * @description Loads (once) the prior-execution index for this instance:
   * completed visits and recorded patch decisions, plus the instance/class dates.
   * @param targetClassName The calling class name whose LastModifiedDate anchors
   * patch date comparisons.
   */
  public void loadExecutions(String targetClassName) {
    if (hasLoadedExecutions || ctx.workflowInstanceId == null) {
      return;
    }
    Set<Id> targetIds = collectTargetExecutionIds();
    List<Workflow_Step_Execution__c> executions = queryExecutions(targetIds);
    resolveInstanceCreatedDate(executions);
    resolveClassLastModified(targetClassName);
    StepExecutionParse.ParseResult parsed = StepExecutionParse.parse(
      executions,
      StepExecutionParse.resolveCapturePayloads(executions)
    );
    completedStepsCache.addAll(parsed.completedSteps);
    patchDecisionsCache.putAll(parsed.patchDecisions);
    hasLoadedExecutions = true;
  }

  /**
   * @description Resolves the patch decision for a change id: a prior recorded
   * decision when present, else the first-time decision computed from the loaded
   * index. Must be called after loadExecutions().
   * @param changeId The patch/change id.
   * @param introducedAt Optional patch introduction date.
   * @return The patch decision (true = active/new branch).
   */
  public Boolean decisionFor(String changeId, DateTime introducedAt) {
    return patchDecisionsCache.containsKey(changeId)
      ? patchDecisionsCache.get(changeId)
      : firstPatchDecision(introducedAt);
  }

  // Computes the patch decision the first time it is reached in this instance
  // (no prior recorded decision). An already-completed visit is a re-execution
  // (false); otherwise a brand-new instance defaults to true unless it predates
  // the patch introduction / class deployment, or dates were unresolvable while
  // earlier steps already completed.
  private Boolean firstPatchDecision(DateTime introducedAt) {
    if (completedStepsCache.contains(ctx.stepName + ':' + this.stepVisit)) {
      return false;
    }
    DateTime comparisonDate = introducedAt != null
      ? introducedAt
      : classLastModified;
    if (
      instanceCreatedDate != null &&
      comparisonDate != null &&
      instanceCreatedDate < comparisonDate
    ) {
      return false;
    }
    if (
      !completedStepsCache.isEmpty() &&
      (instanceCreatedDate == null ||
      comparisonDate == null)
    ) {
      return false;
    }
    return true;
  }

  // Steps 1 & 2: the first+last execution id per other step name, plus the
  // current step name's executions bounded by stepVisit + 2 (queried separately
  // to ensure correct visit counts).
  private Set<Id> collectTargetExecutionIds() {
    Set<Id> targetIds = new Set<Id>();
    for (AggregateResult ar : [
      SELECT Step_Name__c, MIN(Id) minId, MAX(Id) maxId
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c = :ctx.workflowInstanceId
      WITH SYSTEM_MODE
      GROUP BY Step_Name__c
    ]) {
      if ((String) ar.get('Step_Name__c') == ctx.stepName) {
        continue;
      }
      Id minId = (Id) ar.get('minId');
      Id maxId = (Id) ar.get('maxId');
      if (minId != null) {
        targetIds.add(minId);
      }
      if (maxId != null) {
        targetIds.add(maxId);
      }
    }
    Integer currentStepLimit = this.stepVisit + 2;
    for (Workflow_Step_Execution__c e : [
      SELECT Id
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :ctx.workflowInstanceId
        AND Step_Name__c = :ctx.stepName
      WITH SYSTEM_MODE
      ORDER BY CreatedDate ASC, Id ASC
      LIMIT :currentStepLimit
    ]) {
      targetIds.add(e.Id);
    }
    return targetIds;
  }

  // Step 3: the final sorted list of step executions by id.
  private List<Workflow_Step_Execution__c> queryExecutions(Set<Id> targetIds) {
    if (targetIds.isEmpty()) {
      return new List<Workflow_Step_Execution__c>();
    }
    return [
      SELECT
        Step_Name__c,
        Status__c,
        Captured_Values__c,
        Workflow_Instance__r.CreatedDate
      FROM Workflow_Step_Execution__c
      WHERE Id IN :targetIds
      WITH SYSTEM_MODE
      ORDER BY CreatedDate ASC, Id ASC
    ];
  }

  /**
   * @description Resolves the instance's CreatedDate for patch date comparisons,
   * preferring the test mock, then a joined execution row, then a direct query.
   * @param executions The loaded step executions (their joined instance date).
   */
  private void resolveInstanceCreatedDate(
    List<Workflow_Step_Execution__c> executions
  ) {
    if (Test.isRunningTest() && mockInstanceCreatedDate != null) {
      this.instanceCreatedDate = mockInstanceCreatedDate;
      return;
    }
    if (!executions.isEmpty()) {
      this.instanceCreatedDate = executions[0].Workflow_Instance__r.CreatedDate;
      return;
    }
    List<Workflow_Instance__c> instances = [
      SELECT CreatedDate
      FROM Workflow_Instance__c
      WHERE Id = :ctx.workflowInstanceId
      WITH SYSTEM_MODE
      LIMIT 1
    ];
    if (!instances.isEmpty()) {
      this.instanceCreatedDate = instances[0].CreatedDate;
    }
  }

  /**
   * @description Resolves the calling class's LastModifiedDate for patch date
   * comparisons, preferring the test mock.
   * @param targetClassName The calling class name to look up.
   */
  private void resolveClassLastModified(String targetClassName) {
    if (Test.isRunningTest() && mockClassLastModified != null) {
      this.classLastModified = mockClassLastModified;
      return;
    }
    List<ApexClass> classes = [
      SELECT LastModifiedDate
      FROM ApexClass
      WHERE Name = :targetClassName
      WITH SYSTEM_MODE
      LIMIT 1
    ];
    if (!classes.isEmpty()) {
      this.classLastModified = classes[0].LastModifiedDate;
    }
  }
}
