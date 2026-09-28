/**
 * @description Step-history guard (issue #112). Stops an instance before its
 * step history hits the query-row or heap limit. The runner calls it after
 * admission and before the first full-history read. It does one `COUNT()`
 * with `LIMIT`. The guard does not change closed step rows or the
 * compensation stack. See docs/step-history-guard.md.
 */
public inherited sharing class WorkflowStepHistoryGuard {
  /** @description Log_Type__c of the warning row. */
  public static final String LOG_TYPE = 'StepHistoryWarning';

  /** @description Default warn threshold (rows). */
  public static final Integer DEFAULT_WARN = 5000;

  /**
   * @description Default ceiling (rows). Below it, the full-history reads of
   * one hop use max approximately 30,000 of the 50,000 query rows.
   */
  public static final Integer DEFAULT_CEILING = 10000;

  /** @description Highest value the engine accepts for a threshold. */
  public static final Integer MAX_THRESHOLD = 10000;

  // Fire_Key__c prefix. The key is unique, so one warning row per instance.
  private static final String FIRE_KEY_PREFIX = 'StepHistoryWarn:';

  // Max open rows the halt closes. Each active step has max one open row.
  private static final Integer OPEN_ROW_CAP = 200;

  // Statuses the guard can fail from. Another path owns each other status.
  private static final Set<String> HALTABLE_STATUSES = new Set<String>{
    'Pending',
    'Running',
    'Suspended'
  };

  /** @description Result of a history check. */
  public enum Verdict {
    OK,
    WARN,
    HALT
  }

  /** @description Effective thresholds. 0 means the check is off. */
  public class Thresholds {
    /** @description Warn threshold in rows, or 0 (off). */
    public Integer warn;
    /** @description Ceiling in rows, or 0 (off). */
    public Integer ceiling;

    /**
     * @description Makes a threshold pair.
     * @param warn Warn threshold, or 0.
     * @param ceiling Ceiling, or 0.
     */
    public Thresholds(Integer warn, Integer ceiling) {
      this.warn = warn;
      this.ceiling = ceiling;
    }
  }

  /**
   * @description Makes effective thresholds from the configured values. Blank
   * or negative uses the default. 0 turns the check off. The max is
   * MAX_THRESHOLD. A warn value that is not below the ceiling becomes half the
   * ceiling. Thus a ceiling of 1 gives no warning.
   * @param warnRaw Configured warn value.
   * @param ceilingRaw Configured ceiling value.
   * @return The effective thresholds.
   */
  public static Thresholds resolve(Integer warnRaw, Integer ceilingRaw) {
    Integer warn = normalize(warnRaw, DEFAULT_WARN);
    Integer ceiling = normalize(ceilingRaw, DEFAULT_CEILING);
    if (warn > 0 && ceiling > 0 && warn >= ceiling) {
      warn = ceiling / 2;
    }
    return new Thresholds(warn, ceiling);
  }

  /**
   * @description Compares a row count with the thresholds.
   * @param count Step rows on the instance.
   * @param t Effective thresholds.
   * @return HALT at the ceiling, WARN at the warn threshold, else OK.
   */
  public static Verdict evaluate(Integer count, Thresholds t) {
    if (t.ceiling > 0 && count >= t.ceiling) {
      return Verdict.HALT;
    }
    if (t.warn > 0 && count >= t.warn) {
      return Verdict.WARN;
    }
    return Verdict.OK;
  }

  /**
   * @description Returns true for an engine workflow. The guard never fails
   * one. A failed watchdog stops the engine.
   * @param workflowName Workflow name, with or without a namespace.
   * @return True when the workflow is exempt.
   */
  public static Boolean isExempt(String workflowName) {
    return String.isNotBlank(workflowName) &&
      (WorkflowPauseGate.isReserved(workflowName) ||
      WorkflowPauseGate.isReserved(workflowName.substringAfterLast('.')));
  }

  /**
   * @description Counts the step rows of the instance and applies the
   * verdict. On WARN it sets ctx.stepHistoryWarning and does no DML. On HALT
   * it closes the open rows of the active steps and fails the instance.
   * @param ctx Run context with instanceId, instance and activeStepName.
   * @return True when the caller must stop the delivery.
   */
  public static Boolean check(WorkflowStepRunner.RunStepContext ctx) {
    if (isExempt(ctx.instance.Workflow_Name__c)) {
      return false;
    }
    Thresholds t = resolve(
      WorkflowEngine.stepHistoryWarnThreshold,
      WorkflowEngine.stepHistoryCeiling
    );
    Integer cap = t.ceiling > 0 ? t.ceiling : t.warn;
    if (cap == 0) {
      return false; // Both checks off: no SOQL.
    }
    Id instanceId = ctx.instanceId;
    // COUNT() uses one query row and no heap. LIMIT stops the scan at the cap.
    Integer count = [
      SELECT COUNT()
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c = :instanceId
      WITH SYSTEM_MODE
      LIMIT :cap
    ];
    Verdict verdict = evaluate(count, t);
    if (verdict == Verdict.HALT) {
      halt(ctx, t.ceiling);
      return true;
    }
    if (verdict == Verdict.WARN) {
      ctx.stepHistoryWarning = warningMessage(count, t.ceiling);
    }
    return false;
  }

  /**
   * @description Writes the warning row that check() kept on the context.
   * Call it after the step outcome. An insert of a second row for the same
   * instance fails on the unique Fire_Key__c. The code ignores this failure.
   * @param ctx Run context.
   */
  public static void recordWarning(WorkflowStepRunner.RunStepContext ctx) {
    if (
      String.isBlank(ctx.stepHistoryWarning) ||
      Limits.getDmlStatements() >= Limits.getLimitDmlStatements()
    ) {
      return; // No warning, or no DML statement left: try on the next hop.
    }
    Database.insert(
      new Workflow_Log__c(
        Log_Type__c = LOG_TYPE,
        Level__c = 'Warn',
        Message__c = ctx.stepHistoryWarning,
        Fire_Key__c = fireKey(ctx.instanceId),
        Fire_Time__c = Datetime.now(),
        Workflow_Instance__c = ctx.instanceId,
        Workflow_Name__c = ctx.instance.Workflow_Name__c,
        Correlation_Key__c = ctx.instance.Correlation_Key__c
      ),
      false,
      AccessLevel.SYSTEM_MODE
    );
  }

  /**
   * @description Returns the Fire_Key__c of the warning row of an instance.
   * @param instanceId Instance Id.
   * @return The key.
   */
  public static String fireKey(Id instanceId) {
    return FIRE_KEY_PREFIX + String.valueOf(instanceId);
  }

  /**
   * @description Returns the instances that have a warning row. One SOQL.
   * @param instanceIds Instance Ids, for example one dashboard page.
   * @return The Ids that have a warning.
   */
  public static Set<Id> warnedInstanceIds(Set<Id> instanceIds) {
    Set<Id> warned = new Set<Id>();
    if (instanceIds == null || instanceIds.isEmpty()) {
      return warned;
    }
    Set<String> keys = new Set<String>();
    for (Id instanceId : instanceIds) {
      keys.add(fireKey(instanceId));
    }
    Integer cap = keys.size();
    for (Workflow_Log__c row : [
      SELECT Workflow_Instance__c
      FROM Workflow_Log__c
      WHERE Fire_Key__c IN :keys
      WITH SYSTEM_MODE
      LIMIT :cap
    ]) {
      warned.add(row.Workflow_Instance__c);
    }
    return warned;
  }

  /**
   * @description Returns the warning of one instance for the detail pane.
   * @param instanceId Instance Id.
   * @return A map with message and createdDate, or null.
   */
  public static Map<String, Object> describeWarning(Id instanceId) {
    String key = fireKey(instanceId);
    List<Workflow_Log__c> rows = [
      SELECT Message__c, CreatedDate
      FROM Workflow_Log__c
      WHERE Fire_Key__c = :key
      WITH SYSTEM_MODE
      LIMIT 1
    ];
    if (rows.isEmpty()) {
      return null;
    }
    return new Map<String, Object>{
      'message' => rows[0].Message__c,
      'createdDate' => rows[0].CreatedDate
    };
  }

  // Blank or negative uses the default. Clamp to MAX_THRESHOLD.
  private static Integer normalize(Integer raw, Integer defaultValue) {
    if (raw == null || raw < 0) {
      return defaultValue;
    }
    return Math.min(raw, MAX_THRESHOLD);
  }

  // Lock the instance first (the admission lock order). A parallel sibling or
  // an operator can finish the instance after this delivery loaded it.
  private static void halt(
    WorkflowStepRunner.RunStepContext ctx,
    Integer ceiling
  ) {
    Id instanceId = ctx.instanceId;
    List<Workflow_Instance__c> locked = [
      SELECT Id, Status__c, Current_Step__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
      WITH SYSTEM_MODE
      LIMIT 1
      FOR UPDATE
    ];
    if (locked.isEmpty() || !HALTABLE_STATUSES.contains(locked[0].Status__c)) {
      return;
    }
    List<String> activeSteps = activeSteps(
      locked[0].Current_Step__c,
      ctx.activeStepName
    );
    String message =
      'Step history reached ' +
      ceiling +
      ' rows (the ceiling). Change this workflow to use Continue-As-New.';
    closeOpenRows(instanceId, activeSteps, message);

    WorkflowEngine.FailInstanceRequest req = new WorkflowEngine.FailInstanceRequest();
    req.instanceId = instanceId;
    // A stale named delivery can carry a step that is not active.
    req.stepName = activeSteps.contains(ctx.activeStepName)
      ? ctx.activeStepName
      : String.join(activeSteps, ',');
    req.errorMessage = message;
    req.failureCategory = WorkflowEngine.CAT_STEP_HISTORY_LIMIT;
    // Error routing causes a loop: the error step cannot run past this guard.
    req.skipErrorRouting = true;
    WorkflowEngine.failWorkflowInstance(req);
  }

  // The active step names. A parallel step is a comma list.
  private static List<String> activeSteps(String currentStep, String fallback) {
    List<String> steps = new List<String>();
    String source = String.isNotBlank(currentStep) ? currentStep : fallback;
    if (String.isBlank(source)) {
      return steps;
    }
    for (String step : source.split(',')) {
      if (String.isNotBlank(step)) {
        steps.add(step.trim());
      }
    }
    return steps;
  }

  // Close the open rows of the active steps, as each failure path does, and
  // abort the scheduled jobs. Else a stale timeout fails a compensating saga.
  // Closed rows do not change. The guard inserts and deletes no row.
  private static void closeOpenRows(
    Id instanceId,
    List<String> activeSteps,
    String message
  ) {
    WorkflowOrchestratorEnqueue.abortScheduledJobs(instanceId);
    if (activeSteps.isEmpty()) {
      return;
    }
    List<Workflow_Step_Execution__c> open = [
      SELECT Id
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :instanceId
        AND Step_Name__c IN :activeSteps
        AND Status__c IN ('Pending', 'Running', 'Retrying')
      WITH SYSTEM_MODE
      LIMIT :OPEN_ROW_CAP
      FOR UPDATE
    ];
    for (Workflow_Step_Execution__c row : open) {
      row.Status__c = 'Failed';
      row.Timeout_At__c = null;
      row.Error_Details__c = message;
    }
    if (!open.isEmpty()) {
      Database.update(open, true, AccessLevel.SYSTEM_MODE);
    }
  }

  private static String warningMessage(Integer count, Integer ceiling) {
    String limitText = ceiling > 0
      ? 'At ' + ceiling + ' rows the engine fails this instance. '
      : 'A large history can hit the query-row and heap limits. ';
    return 'Step history reached ' +
      count +
      ' rows. ' +
      limitText +
      'Change this workflow to use Continue-As-New.';
  }
}
