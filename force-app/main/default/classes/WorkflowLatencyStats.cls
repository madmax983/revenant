/**
 * @description Pure in-memory latency statistics for WorkflowLatencyService: end-to-end
 * duration extraction and percentile selection, and the per-step median-wall-clock ranking
 * derived from consecutive step-execution CreatedDate deltas. Salesforce SOQL has no
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
   * broken by name). Each consecutive CreatedDate delta between a step and its successor
   * within an instance is attributed to the earlier step; the final step in an instance has
   * no successor and so contributes no delta. Wall-clock deltas include durable waits.
   * @param stepExecs Step-execution rows for the sampled instances, ordered by instance then
   *        CreatedDate ascending.
   * @return One serializable row per ranked step: stepName, medianMs, sampleCount.
   */
  public static List<Map<String, Object>> rankStepsByMedianWallClock(
    List<Workflow_Step_Execution__c> stepExecs
  ) {
    Map<String, List<Long>> deltasByStep = collectStepDeltas(
      groupStepsByInstance(stepExecs)
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

  // Computes per-step-name lists of consecutive CreatedDate deltas (ms) from the per-instance
  // ordered step rows.
  private static Map<String, List<Long>> collectStepDeltas(
    Map<Id, List<Workflow_Step_Execution__c>> byInstance
  ) {
    Map<String, List<Long>> deltasByStep = new Map<String, List<Long>>();
    for (List<Workflow_Step_Execution__c> ordered : byInstance.values()) {
      addInstanceDeltas(ordered, deltasByStep);
    }
    return deltasByStep;
  }

  // Adds one instance's consecutive step deltas into the per-step-name accumulator.
  private static void addInstanceDeltas(
    List<Workflow_Step_Execution__c> ordered,
    Map<String, List<Long>> deltasByStep
  ) {
    for (Integer i = 0; i < ordered.size() - 1; i++) {
      Long delta = deltaMillis(ordered[i], ordered[i + 1]);
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

  // Milliseconds between two steps' CreatedDate values, or null if either is unset.
  private static Long deltaMillis(
    Workflow_Step_Execution__c earlier,
    Workflow_Step_Execution__c later
  ) {
    if (earlier.CreatedDate == null || later.CreatedDate == null) {
      return null;
    }
    return later.CreatedDate.getTime() - earlier.CreatedDate.getTime();
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
