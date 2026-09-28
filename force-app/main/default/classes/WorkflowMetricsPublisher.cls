/**
 * @description Publishes the engine-health snapshot (issue #127) as
 * Workflow_Metrics__e events. The watchdog heartbeat calls it once for each
 * sweep, so it uses no scheduled-job slot.
 *
 * Contract:
 * - Toggle: Revenant_Config__mdt.Publish_Metrics_Events__c (default off).
 *   Off costs 0 SOQL and 0 DML.
 * - Window: (previous sweep, snapshot time]. With no earlier sweep stamp,
 *   the window is one watchdog cadence.
 * - Chunks: a large snapshot uses more than one event. All chunks have the
 *   same Snapshot_Id__c.
 * - No silent drop: when a cap drops data, each chunk has Is_Truncated__c
 *   and one Warn row goes to Workflow_Log__c. A skipped snapshot writes one
 *   Warn row when the DML budget permits.
 * - Fire-and-forget: it never throws. It keeps DML_RESERVE DML statements
 *   and rows free, so the liveness stamp and the step commit can finish. It
 *   does not start when CPU time or heap is more than PRESSURE_PERCENT.
 */
public inherited sharing class WorkflowMetricsPublisher {
  /** @description Log_Type__c of the metrics log rows. */
  public static final String LOG_TYPE = 'WorkflowMetrics';
  /**
   * @description DML statements and rows to keep free after the publish:
   * the liveness stamp (one) and its own reserve.
   */
  public static final Integer DML_RESERVE = WatchdogLiveness.DML_RESERVE + 1;

  /** @description Skip when CPU time or heap is more than this percent. */
  public static final Integer PRESSURE_PERCENT = 50;

  // Maximum characters in one Metrics_Json__c value. The field holds 131,072.
  @TestVisible
  private static Integer chunkCharBudget = 100000;
  // Maximum events for one snapshot.
  @TestVisible
  private static Integer maxChunks = 10;
  // The events given to EventBus.publish. Test context only.
  @TestVisible
  private static List<Workflow_Metrics__e> publishedEvents = new List<Workflow_Metrics__e>();
  @TestVisible
  private static Boolean throwTestException = false;
  @TestVisible
  private static Boolean forceDmlBudgetExhausted = false;
  @TestVisible
  private static Boolean forceGovernorPressure = false;

  /**
   * @description Publishes one snapshot when the toggle is on. Does not
   * throw.
   * @param snapshotAt Snapshot time. The heartbeat gives its sweep time.
   */
  public static void publishSnapshot(Datetime snapshotAt) {
    if (!WorkflowEngine.publishMetricsEvents || snapshotAt == null) {
      return;
    }
    // Check first, so a low budget also saves the queries. With no DML
    // budget, the log row also cannot fit.
    if (!hasDmlBudget(1, 1)) {
      return;
    }
    if (hasGovernorPressure()) {
      log(
        false,
        'Snapshot skipped: CPU time or heap is more than ' +
          PRESSURE_PERCENT +
          '% of the limit. Snapshot time: ' +
          snapshotAt
      );
      return;
    }
    try {
      Datetime windowStart = resolveWindowStart(snapshotAt);
      WorkflowMetricsCollector.Result collected = WorkflowMetricsCollector.collect(
        windowStart,
        snapshotAt
      );
      if (collected == null) {
        log(
          false,
          'Snapshot skipped: the query budget is too low. Snapshot time: ' +
          snapshotAt
        );
        return;
      }
      WorkflowMetricsSnapshot.ChunkPlan plan = WorkflowMetricsSnapshot.chunk(
        collected.rows,
        chunkCharBudget,
        maxChunks
      );
      Boolean truncated = collected.truncated || plan.truncated;
      List<Workflow_Metrics__e> events = buildEvents(
        plan.chunks,
        windowStart,
        snapshotAt,
        truncated
      );
      if (!hasDmlBudget(1, events.size())) {
        log(
          false,
          'Snapshot skipped: the DML budget is too low. Snapshot time: ' +
          snapshotAt
        );
        return;
      }
      dispatch(events);
      // Is_Truncated__c carries the signal. The log row is added when the
      // DML budget permits.
      if (truncated) {
        log(false, truncationMessage(events[0], collected, plan));
      }
    } catch (Exception ex) {
      log(true, 'Snapshot publish failed: ' + ex.getMessage());
    }
  }

  /**
   * @description Start of the window: the previous sweep time. When no
   * earlier stamp exists, snapshot time minus one cadence.
   * @param snapshotAt Snapshot time.
   * @return The window start (not included).
   */
  @TestVisible
  private static Datetime resolveWindowStart(Datetime snapshotAt) {
    Watchdog_Liveness__c stamp = Watchdog_Liveness__c.getOrgDefaults();
    Datetime lastSweep = stamp == null ? null : stamp.Last_Sweep_At__c;
    if (lastSweep != null && lastSweep < snapshotAt) {
      return lastSweep;
    }
    return snapshotAt.addMinutes(
      -WatchdogLiveness.normalizeCadence(WorkflowEngine.watchdogDelayMinutes)
    );
  }

  private static List<Workflow_Metrics__e> buildEvents(
    List<String> chunks,
    Datetime windowStart,
    Datetime snapshotAt,
    Boolean truncated
  ) {
    String snapshotId = UUID.randomUUID().toString();
    List<Workflow_Metrics__e> events = new List<Workflow_Metrics__e>();
    for (Integer i = 0; i < chunks.size(); i++) {
      events.add(
        new Workflow_Metrics__e(
          Snapshot_Id__c = snapshotId,
          Snapshot_At__c = snapshotAt,
          Window_Start__c = windowStart,
          Chunk_Index__c = i + 1,
          Chunk_Count__c = chunks.size(),
          Is_Truncated__c = truncated,
          Schema_Version__c = WorkflowMetricsSnapshot.SCHEMA_VERSION,
          Metrics_Json__c = chunks[i]
        )
      );
    }
    return events;
  }

  private static String truncationMessage(
    Workflow_Metrics__e first,
    WorkflowMetricsCollector.Result collected,
    WorkflowMetricsSnapshot.ChunkPlan plan
  ) {
    List<String> parts = new List<String>{
      'Snapshot ' +
      first.Snapshot_Id__c +
      ' is truncated.'
    };
    parts.addAll(collected.notes);
    if (plan.truncated) {
      parts.add(
        plan.droppedRows +
          ' definitions dropped at the cap of ' +
          maxChunks +
          ' chunks.'
      );
    }
    return String.join(parts, ' ');
  }

  // CPU time and heap have no reserve check in the sweep. Over the limit,
  // Apex throws a LimitException and cannot catch it. The snapshot uses the
  // JSON heap and CPU, so it runs only below PRESSURE_PERCENT.
  private static Boolean hasGovernorPressure() {
    return forceGovernorPressure ||
      Limits.getCpuTime() * 100 >
      Limits.getLimitCpuTime() * PRESSURE_PERCENT ||
      Limits.getHeapSize() * 100 >
      Limits.getLimitHeapSize() * PRESSURE_PERCENT;
  }

  // EventBus.publish uses one DML statement and one DML row for each event.
  // Over the limit, Apex throws a LimitException and cannot catch it.
  private static Boolean hasDmlBudget(Integer statements, Integer rows) {
    return !forceDmlBudgetExhausted &&
      Limits.getDmlStatements() + statements + DML_RESERVE <=
      Limits.getLimitDmlStatements() &&
      Limits.getDmlRows() + rows + DML_RESERVE <= Limits.getLimitDmlRows();
  }

  private static void dispatch(List<Workflow_Metrics__e> events) {
    if (Test.isRunningTest() && throwTestException) {
      throw new WorkflowEngine.WorkflowException(
        'Simulated EventBus.publish failure'
      );
    }
    List<Database.SaveResult> results = EventBus.publish(events);
    if (Test.isRunningTest()) {
      publishedEvents.addAll(events);
    }
    Integer failed = 0;
    String firstError = null;
    for (Database.SaveResult result : results) {
      if (!result.isSuccess()) {
        failed++;
        if (firstError == null && !result.getErrors().isEmpty()) {
          firstError = result.getErrors()[0].getMessage();
        }
      }
    }
    if (failed > 0) {
      log(
        true,
        failed +
          ' of ' +
          events.size() +
          ' metrics events failed to publish: ' +
          firstError
      );
    }
  }

  // Writes one log row when the DML budget permits. Does not throw.
  private static void log(Boolean isError, String message) {
    if (!hasDmlBudget(1, 1)) {
      return;
    }
    WorkflowLog.ErrorEntry entry = new WorkflowLog.ErrorEntry(
      LOG_TYPE,
      message
    );
    if (isError) {
      WorkflowLog.error(entry);
    } else {
      WorkflowLog.warn(entry);
    }
  }
}
