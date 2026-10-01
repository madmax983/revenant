/**
 * @description Pure in-memory latency statistics for WorkflowLatencyService: end-to-end
 * duration extraction and percentile selection, and the per-step median-wall-clock ranking
 * derived from step-execution CreatedDate deltas. Salesforce SOQL has no
 * PERCENTILE function, so the bounded row set is reduced here in Apex. Split out of
 * WorkflowLatencyService (mirroring the WorkflowFailureBreakdownService →
 * WorkflowFailureSignatureService split) so each class stays focused: the service does auth +
 * bounded SOQL, this class does the arithmetic. Stateless and read-only — no SOQL, no DML.
 */
public inherited sharing class WorkflowLatencyStats {
  // Placeholder surfaced for a step execution with a blank Step_Name__c.
  private static final String UNNAMED_STEP = '(unnamed)';

  /**
   * @description Extracts the end-to-end wall-clock duration in milliseconds
   * (Terminal_At__c − CreatedDate) for every instance that has both timestamps, ascending-
   * sorted so percentiles can be selected by index.
   * @param instances The sampled terminal instances.
   * @return The ascending-sorted list of durations in milliseconds (possibly empty).
   */
  public static List<Long> sortedDurations(
    List<Workflow_Instance__c> instances
  ) {
    List<Long> durations = new List<Long>();
    for (Workflow_Instance__c inst : instances) {
      if (inst.Terminal_At__c != null && inst.CreatedDate != null) {
        durations.add(
          inst.Terminal_At__c.getTime() - inst.CreatedDate.getTime()
        );
      }
    }
    durations.sort();
    return durations;
  }

  /**
   * @description Nearest-rank percentile over an ascending-sorted list of durations (ms):
   * rank = ceil(pct/100 × N), clamped to [1, N], returning the value at that 1-based rank.
   * Nearest-rank (not interpolated) is chosen so every reported percentile is an actually-
   * observed duration.
   * @param sorted The ascending-sorted durations in milliseconds.
   * @param pct The percentile to select (e.g. 50, 95, 99).
   * @return The selected duration in milliseconds, or null for an empty list.
   */
  public static Long percentile(List<Long> sorted, Integer pct) {
    Integer n = sorted.size();
    if (n == 0) {
      return null;
    }
    Integer rank = (Integer) Math.ceil((Decimal.valueOf(pct) / 100) * n);
    // Clamp to a valid 1-based rank in [1, N].
    rank = Math.min(Math.max(rank, 1), n);
    return sorted[rank - 1];
  }

  /**
   * @description Maximum of an ascending-sorted duration list (its last element).
   * @param sorted The ascending-sorted durations in milliseconds.
   * @return The largest duration in milliseconds, or null for an empty list.
   */
  public static Long maxDuration(List<Long> sorted) {
    return sorted.isEmpty() ? null : sorted[sorted.size() - 1];
  }

  /**
   * @description Ranks step names by their median wall-clock delta (slowest first, ties
   * broken by name). A step is timed from its CreatedDate to the next step's CreatedDate.
   * The last step is timed to its instance's Terminal_At__c. Fan-out siblings (rows with
   * the same CreatedDate in one instance) cannot be timed one by one, so they get no sample.
   * Wall-clock deltas include durable waits. Negative deltas are ignored. If the scan was
   * capped, the last instance may be cut short, so its last row gets no terminal delta.
   * @param stepExecs Step-execution rows for the sampled instances, ordered by instance then
   *        CreatedDate ascending.
   * @param instances The sampled terminal instances (source of Terminal_At__c).
   * @param scanCapped True if the step scan hit its row cap.
   * @return One serializable row per ranked step: stepName, medianMs, sampleCount.
   */
  public static List<Map<String, Object>> rankStepsByMedianWallClock(
    List<Workflow_Step_Execution__c> stepExecs,
    List<Workflow_Instance__c> instances,
    Boolean scanCapped
  ) {
    Map<Id, Datetime> terminalById = new Map<Id, Datetime>();
    for (Workflow_Instance__c inst : instances) {
      terminalById.put(inst.Id, floorToSecond(inst.Terminal_At__c));
    }
    // A capped scan can cut the last instance short. Its last row is then not a final step.
    if (scanCapped == true && !stepExecs.isEmpty()) {
      terminalById.remove(stepExecs[stepExecs.size() - 1].Workflow_Instance__c);
    }
    Map<String, List<Long>> deltasByStep = collectStepDeltas(
      groupStepsByInstance(stepExecs),
      terminalById
    );

    List<StepMedian> ranked = new List<StepMedian>();
    for (String stepName : deltasByStep.keySet()) {
      List<Long> deltas = deltasByStep.get(stepName);
      deltas.sort();
      ranked.add(new StepMedian(stepName, median(deltas), deltas.size()));
    }
    ranked.sort(); // slowest median first, ties by name

    List<Map<String, Object>> rows = new List<Map<String, Object>>();
    for (StepMedian sm : ranked) {
      rows.add(sm.toRow());
    }
    return rows;
  }

  /**
   * @description Detects parallel fan-out: two adjacent rows of one instance that share a
   * CreatedDate were inserted together. CreatedDate has one-second precision, so two very
   * fast serial steps can match too; the ranking is then only marked approximate.
   * @param stepExecs Step-execution rows ordered by instance then CreatedDate ascending.
   * @return True if any instance has fan-out siblings.
   */
  public static Boolean hasFanOut(List<Workflow_Step_Execution__c> stepExecs) {
    for (Integer i = 1; i < stepExecs.size(); i++) {
      if (sameBatch(stepExecs[i - 1], stepExecs[i])) {
        return true;
      }
    }
    return false;
  }

  // True if both rows belong to one instance and share a CreatedDate.
  private static Boolean sameBatch(
    Workflow_Step_Execution__c a,
    Workflow_Step_Execution__c b
  ) {
    return a.Workflow_Instance__c == b.Workflow_Instance__c &&
      a.CreatedDate != null &&
      a.CreatedDate == b.CreatedDate;
  }

  // Buckets step-execution rows by their owning instance, preserving the query's ascending
  // CreatedDate order within each bucket.
  private static Map<Id, List<Workflow_Step_Execution__c>> groupStepsByInstance(
    List<Workflow_Step_Execution__c> stepExecs
  ) {
    Map<Id, List<Workflow_Step_Execution__c>> byInstance = new Map<Id, List<Workflow_Step_Execution__c>>();
    for (Workflow_Step_Execution__c se : stepExecs) {
      if (!byInstance.containsKey(se.Workflow_Instance__c)) {
        byInstance.put(
          se.Workflow_Instance__c,
          new List<Workflow_Step_Execution__c>()
        );
      }
      byInstance.get(se.Workflow_Instance__c).add(se);
    }
    return byInstance;
  }

  // Computes per-step-name lists of deltas (ms) from the per-instance ordered step rows.
  private static Map<String, List<Long>> collectStepDeltas(
    Map<Id, List<Workflow_Step_Execution__c>> byInstance,
    Map<Id, Datetime> terminalById
  ) {
    Map<String, List<Long>> deltasByStep = new Map<String, List<Long>>();
    for (Id instanceId : byInstance.keySet()) {
      addInstanceDeltas(
        byInstance.get(instanceId),
        terminalById.get(instanceId),
        deltasByStep
      );
    }
    return deltasByStep;
  }

  // Adds one instance's step deltas into the per-step-name accumulator. Fan-out siblings are
  // skipped. The last step is timed to the instance's terminal time.
  private static void addInstanceDeltas(
    List<Workflow_Step_Execution__c> ordered,
    Datetime terminalAt,
    Map<String, List<Long>> deltasByStep
  ) {
    for (Integer i = 0; i < ordered.size(); i++) {
      if (isSibling(ordered, i)) {
        continue;
      }
      Long delta = (i + 1 < ordered.size())
        ? deltaMillis(ordered[i].CreatedDate, ordered[i + 1].CreatedDate)
        : deltaMillis(ordered[i].CreatedDate, terminalAt);
      if (delta == null) {
        continue;
      }
      String stepName = stepNameOf(ordered[i]);
      if (!deltasByStep.containsKey(stepName)) {
        deltasByStep.put(stepName, new List<Long>());
      }
      deltasByStep.get(stepName).add(delta);
    }
  }

  // True if row i shares its CreatedDate with a neighbor (a fan-out sibling).
  private static Boolean isSibling(
    List<Workflow_Step_Execution__c> ordered,
    Integer i
  ) {
    return (i > 0 && sameBatch(ordered[i - 1], ordered[i])) ||
      (i + 1 < ordered.size() && sameBatch(ordered[i], ordered[i + 1]));
  }

  // CreatedDate has one-second precision. Terminal_At__c is cut to match it.
  private static Datetime floorToSecond(Datetime value) {
    return value == null
      ? null
      : Datetime.newInstance(value.getTime() - Math.mod(value.getTime(), 1000));
  }

  // Milliseconds from start to end, or null if either is unset or the span is negative.
  private static Long deltaMillis(Datetime started, Datetime ended) {
    if (started == null || ended == null) {
      return null;
    }
    Long delta = ended.getTime() - started.getTime();
    return delta < 0 ? null : delta;
  }

  // Display name for a step, substituting a placeholder for a blank Step_Name__c.
  private static String stepNameOf(Workflow_Step_Execution__c se) {
    return String.isBlank(se.Step_Name__c) ? UNNAMED_STEP : se.Step_Name__c;
  }

  // Median over an ascending-sorted list of durations (ms): the middle value for an odd count,
  // the mean of the two middle values for an even count. Returns null for an empty list.
  private static Long median(List<Long> sorted) {
    Integer n = sorted.size();
    if (n == 0) {
      return null;
    }
    if (Math.mod(n, 2) == 1) {
      return sorted[n / 2];
    }
    return (sorted[n / 2 - 1] + sorted[n / 2]) / 2;
  }

  // Per-step median holder; orders slowest-median-first so the panel surfaces the bottleneck
  // step first, with null medians last and ties broken by step name.
  private class StepMedian implements Comparable {
    private String stepName;
    private Long medianMs;
    private Integer sampleCount;

    private StepMedian(String stepName, Long medianMs, Integer sampleCount) {
      this.stepName = stepName;
      this.medianMs = medianMs;
      this.sampleCount = sampleCount;
    }

    // Serializable display row for this ranked step.
    private Map<String, Object> toRow() {
      return new Map<String, Object>{
        'stepName' => this.stepName,
        'medianMs' => this.medianMs,
        'sampleCount' => this.sampleCount
      };
    }

    /**
     * @description Orders step medians slowest-first: higher median wall-clock first, null
     * medians last, ties broken by step name.
     * @param other The other StepMedian to compare against.
     * @return A negative, zero, or positive value per the Comparable contract.
     */
    public Integer compareTo(Object other) {
      StepMedian that = (StepMedian) other;
      if (this.medianMs == that.medianMs) {
        return this.stepName.compareTo(that.stepName);
      }
      if (this.medianMs == null) {
        return 1;
      }
      if (that.medianMs == null) {
        return -1;
      }
      return this.medianMs > that.medianMs ? -1 : 1;
    }
  }
}
