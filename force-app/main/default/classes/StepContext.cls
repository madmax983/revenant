public inherited sharing class StepContext {
  public Id workflowInstanceId { get; set; }
  public String workflowName { get; set; }
  public String stepName { get; set; }
  public String inputJson { get; set; }
  public String previousStepOutput { get; set; }
  public String stepStateJson { get; set; }
  public String workflowInputJson { get; set; }
  public Integer workflowVersion { get; set; }

  @TestVisible
  private static Double mockQueryRowsFraction = null;
  @TestVisible
  private static Double mockAsyncExecutionsFraction = null;

  /**
   * Read-only view of an inbound signal that targets this workflow instance.
   * Carries the author-interpreted name and payload string; the internal record
   * id is exposed so the engine can tie consumption to the step's transition.
   */
  public class Signal {
    public Id signalId { get; private set; }
    public String name { get; private set; }
    public String payload { get; private set; }
    private Boolean present;

    public Signal(Id signalId, String name, String payload) {
      this.signalId = signalId;
      this.name = name;
      this.payload = payload;
      this.present = true;
    }

    private Signal() {
      this.present = false;
    }

    /** True when this represents a real pending signal (not the empty result). */
    public Boolean isPresent() {
      return present;
    }
  }

  /**
   * Supplies pending signals on demand so a step that never reads signals pays
   * no query/heap cost. Implemented by the engine; resolved lazily on first
   * signal access.
   */
  public interface SignalSource {
    List<Signal> getPendingSignals();
  }

  // Pending (unconsumed) signals targeting this instance, in arrival order.
  // Loaded lazily from signalSource on first access.
  private List<Signal> pendingSignals;
  private SignalSource signalSource;
  private Boolean signalsLoaded = false;
  // Snapshot signals the step actually matched (saw a payload for). Only these
  // drive engine-managed consumption -- a name that was probed but found absent
  // must NOT consume a same-name signal that arrives later.
  private Set<Id> matchedSignalIds = new Set<Id>();
  private Set<String> matchedNames = new Set<String>();

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
      (List<Signal>) null
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
    List<Signal> pendingSignals
  ) {
    this.workflowInstanceId = workflowInstanceId;
    this.workflowName = workflowName;
    this.stepName = stepName;
    this.inputJson = inputJson;
    this.previousStepOutput = previousStepOutput;
    this.stepStateJson = stepStateJson;
    this.workflowInputJson = workflowInputJson;
    this.workflowVersion = workflowVersion;
    // An explicit list is already resolved -- no lazy loading needed.
    this.pendingSignals = (pendingSignals != null)
      ? pendingSignals
      : new List<Signal>();
    this.signalsLoaded = true;
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
    SignalSource signalSource
  ) {
    this.workflowInstanceId = workflowInstanceId;
    this.workflowName = workflowName;
    this.stepName = stepName;
    this.inputJson = inputJson;
    this.previousStepOutput = previousStepOutput;
    this.stepStateJson = stepStateJson;
    this.workflowInputJson = workflowInputJson;
    this.workflowVersion = workflowVersion;
    // Defer loading until a signal accessor is actually called.
    this.signalSource = signalSource;
  }

  // Resolves pending signals lazily so a step that never touches signals pays
  // no query or heap cost for unrelated unconsumed signals on the instance.
  private List<Signal> pending() {
    if (!signalsLoaded) {
      List<Signal> loaded = (signalSource != null)
        ? signalSource.getPendingSignals()
        : null;
      this.pendingSignals = (loaded != null) ? loaded : new List<Signal>();
      this.signalsLoaded = true;
    }
    return this.pendingSignals;
  }

  /**
   * Returns the pending (unconsumed) signals targeting this instance, in
   * deterministic arrival order. Never null. Reading the full list marks every
   * pending signal observed, so the engine consumes them when the step completes.
   */
  public List<Signal> getSignals() {
    for (Signal s : pending()) {
      markMatched(s);
    }
    return pending().clone();
  }

  /**
   * Returns the pending signals matching the given name, in arrival order.
   * Never null. Marks the name observed.
   */
  public List<Signal> getSignals(String signalName) {
    List<Signal> matches = new List<Signal>();
    for (Signal s : pending()) {
      if (s.name == signalName) {
        markMatched(s);
        matches.add(s);
      }
    }
    return matches;
  }

  /**
   * Returns the most recent (last-arriving) pending signal matching the given
   * name, or a clean empty result (isPresent() == false, payload == null) when
   * none is pending. Never returns null. Marks the name observed.
   */
  public Signal getSignal(String signalName) {
    Signal latest = null;
    for (Signal s : pending()) {
      if (s.name == signalName) {
        latest = s;
      }
    }
    if (latest != null) {
      markMatched(latest);
      return latest;
    }
    return new Signal();
  }

  /** True when at least one pending signal matches the given name. Marks observed. */
  public Boolean hasSignal(String signalName) {
    Boolean found = false;
    for (Signal s : pending()) {
      if (s.name == signalName) {
        markMatched(s);
        found = true;
      }
    }
    return found;
  }

  /**
   * Ids of the pending signals the step observed during execution. The engine
   * marks these consumed at the step's successful (COMPLETE) transition. When a
   * name is observed, every pending signal of that name is included so that
   * at-least-once redelivered duplicates do not reappear to a later step.
   */
  /** Ids of the snapshot signals the step actually matched (saw a payload for). */
  public Set<Id> getConsumedSignalIds() {
    return matchedSignalIds.clone();
  }

  /**
   * Names of the signals the step actually matched. The engine re-queries
   * still-Received signals filtered to these names at the step's successful
   * transition, so a same-name at-least-once duplicate delivered while the step
   * was executing is consumed too -- while a name that was only probed absent
   * never consumes a signal that arrives afterwards.
   */
  public Set<String> getConsumedSignalNames() {
    return matchedNames.clone();
  }

  // Records a snapshot signal the step matched, so consumption is scoped to
  // signals the step actually saw rather than every name it probed.
  private void markMatched(Signal s) {
    if (s != null && s.name != null) {
      matchedNames.add(s.name);
      if (s.signalId != null) {
        matchedSignalIds.add(s.signalId);
      }
    }
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
}
