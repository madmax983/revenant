@IsTest
public inherited sharing class StepContextTestBuilder {
  private Id workflowInstanceIdVal;
  private String workflowNameVal;
  private String stepNameVal;
  private String inputJsonVal;
  private String previousStepOutputVal;
  private String stepStateJsonVal;
  private String workflowInputJsonVal;
  private ExecState exec = new ExecState();
  private Map<String, Object> capturedValues = new Map<String, Object>();
  private List<StepContext.Signal> pendingSignals = new List<StepContext.Signal>();

  private static Integer fakeIdSequence = 0;
  private static Map<SObjectType, String> keyPrefixCache = new Map<SObjectType, String>();

  // Holder for the scalar execution-context fields, grouped to keep the
  // builder's field footprint small while preserving identical behavior.
  private class ExecState {
    private Integer workflowVersionVal = 1;
    private Integer stepVisitVal = 0;
    private Datetime previousRunAtVal;
    private Boolean timeoutResumeVal = false;
    private Integer attemptVal = 1;
    private Integer maxAttemptsVal = 1;
  }

  /**
   * @description Sets the workflow instance Id the built StepContext reports.
   * @param val The workflow instance Id, or null to auto-generate a fake Id at build.
   * @return This builder for chaining.
   */
  public StepContextTestBuilder workflowInstanceId(Id val) {
    this.workflowInstanceIdVal = val;
    return this;
  }

  /**
   * @description Sets the workflow definition name the built StepContext reports.
   * @param val The workflow name.
   * @return This builder for chaining.
   */
  public StepContextTestBuilder workflowName(String val) {
    this.workflowNameVal = val;
    return this;
  }

  /**
   * @description Sets the current step name the built StepContext reports.
   * @param val The step name.
   * @return This builder for chaining.
   */
  public StepContextTestBuilder stepName(String val) {
    this.stepNameVal = val;
    return this;
  }

  /**
   * @description Sets the step input as a raw JSON string.
   * @param val The step input JSON.
   * @return This builder for chaining.
   */
  public StepContextTestBuilder inputJson(String val) {
    this.inputJsonVal = val;
    return this;
  }

  /**
   * @description Sets the step input from an object, serializing it to JSON.
   * @param val The step input object, or null.
   * @return This builder for chaining.
   */
  public StepContextTestBuilder input(Object val) {
    this.inputJsonVal = (val == null) ? null : JSON.serialize(val);
    return this;
  }

  /**
   * @description Sets the previous step's output, accepting a raw JSON string
   * as-is or serializing any other object to JSON.
   * @param val The previous step output as a String or serializable object, or null.
   * @return This builder for chaining.
   */
  public StepContextTestBuilder previousStepOutput(Object val) {
    if (val == null) {
      this.previousStepOutputVal = null;
    } else if (val instanceof String) {
      this.previousStepOutputVal = (String) val;
    } else {
      this.previousStepOutputVal = JSON.serialize(val);
    }
    return this;
  }

  /**
   * @description Sets the durable per-step state as a raw JSON string.
   * @param val The step state JSON.
   * @return This builder for chaining.
   */
  public StepContextTestBuilder stepStateJson(String val) {
    this.stepStateJsonVal = val;
    return this;
  }

  /**
   * @description Sets the durable per-step state from an object, serializing it to JSON.
   * @param val The step state object, or null.
   * @return This builder for chaining.
   */
  public StepContextTestBuilder stepState(Object val) {
    this.stepStateJsonVal = (val == null) ? null : JSON.serialize(val);
    return this;
  }

  /**
   * @description Sets the originating workflow input as a raw JSON string.
   * @param val The workflow input JSON.
   * @return This builder for chaining.
   */
  public StepContextTestBuilder workflowInputJson(String val) {
    this.workflowInputJsonVal = val;
    return this;
  }

  /**
   * @description Sets the originating workflow input from an object, serializing it to JSON.
   * @param val The workflow input object, or null.
   * @return This builder for chaining.
   */
  public StepContextTestBuilder workflowInput(Object val) {
    this.workflowInputJsonVal = (val == null) ? null : JSON.serialize(val);
    return this;
  }

  /**
   * @description Sets the workflow definition version the built StepContext reports.
   * @param val The workflow version number.
   * @return This builder for chaining.
   */
  public StepContextTestBuilder workflowVersion(Integer val) {
    this.exec.workflowVersionVal = val;
    return this;
  }

  /**
   * @description Sets the visit count for the current step (how many times it has run).
   * @param val The step visit count.
   * @return This builder for chaining.
   */
  public StepContextTestBuilder stepVisit(Integer val) {
    this.exec.stepVisitVal = val;
    return this;
  }

  /**
   * @description Sets the timestamp of the step's previous run, used for timeout math.
   * @param val The previous run timestamp.
   * @return This builder for chaining.
   */
  public StepContextTestBuilder previousRunAt(Datetime val) {
    this.exec.previousRunAtVal = val;
    return this;
  }

  /**
   * @description Marks the built context as a timeout-triggered resume.
   * @return This builder for chaining.
   */
  public StepContextTestBuilder timeoutResume() {
    this.exec.timeoutResumeVal = true;
    return this;
  }

  /**
   * @description Sets the current retry attempt number for the step.
   * @param val The attempt number (1-based).
   * @return This builder for chaining.
   */
  public StepContextTestBuilder attempt(Integer val) {
    this.exec.attemptVal = val;
    return this;
  }

  /**
   * @description Sets the maximum retry attempts allowed for the step.
   * @param val The maximum attempt count.
   * @return This builder for chaining.
   */
  public StepContextTestBuilder maxAttempts(Integer val) {
    this.exec.maxAttemptsVal = val;
    return this;
  }

  /**
   * @description Queues a pending signal to be exposed to the built StepContext's
   * signal source; nulls are ignored.
   * @param signal The signal to make available to the step, or null to ignore.
   * @return This builder for chaining.
   */
  public StepContextTestBuilder addSignal(StepContext.Signal signal) {
    if (signal != null) {
      this.pendingSignals.add(signal);
    }
    return this;
  }

  /**
   * @description Seeds a captured effectively-once value under the given key,
   * round-tripped through JSON to mirror the engine's serialization boundary.
   * @param key The capture key.
   * @param value The value to capture, or null.
   * @return This builder for chaining.
   */
  public StepContextTestBuilder once(String key, Object value) {
    if (value == null) {
      this.capturedValues.put(key, null);
    } else {
      // Normalize values through a JSON round-trip to guarantee 100% behavioral fidelity with the engine's serialization boundaries.
      this.capturedValues.put(
        key,
        JSON.deserializeUntyped(JSON.serialize(value))
      );
    }
    return this;
  }

  private static Id generateFakeId(SObjectType sObjectType) {
    String keyPrefix = keyPrefixCache.get(sObjectType);
    if (keyPrefix == null) {
      keyPrefix = sObjectType.getDescribe(SObjectDescribeOptions.DEFERRED)
        .getKeyPrefix();
      keyPrefixCache.put(sObjectType, keyPrefix);
    }
    fakeIdSequence++;
    String suffix = String.valueOf(fakeIdSequence).leftPad(12, '0');
    return Id.valueOf(keyPrefix + suffix);
  }

  private class StaticSignalSource implements StepContext.SignalSource {
    private List<StepContext.Signal> signals;
    /**
     * @description Wraps a fixed list of signals as an in-memory signal source,
     * defaulting null to empty and sorting for deterministic ordering.
     * @param signals The signals to serve, or null for none.
     */
    public StaticSignalSource(List<StepContext.Signal> signals) {
      this.signals = (signals != null)
        ? signals
        : new List<StepContext.Signal>();
      this.signals.sort();
    }
    /**
     * @description Returns the pending signals matching the given name, or all
     * signals when the name is null.
     * @param signalName The signal name to filter by, or null for all signals.
     * @return The matching signals in sorted order.
     */
    public List<StepContext.Signal> getPendingSignals(String signalName) {
      if (signalName == null) {
        return this.signals;
      }
      List<StepContext.Signal> filtered = new List<StepContext.Signal>();
      for (StepContext.Signal s : this.signals) {
        if (s.name != null && s.name.equalsIgnoreCase(signalName)) {
          filtered.add(s);
        }
      }
      return filtered;
    }
    /**
     * @description Returns the most recent signal with the given name.
     * @param signalName The signal name to look up.
     * @return The latest matching signal, or null if none match.
     */
    public StepContext.Signal getLatestSignal(String signalName) {
      List<StepContext.Signal> matches = getPendingSignals(signalName);
      if (matches.isEmpty()) {
        return null;
      }
      matches.sort();
      return matches[matches.size() - 1];
    }
    /**
     * @description Reports whether the signal read was capped; always false for
     * this static in-memory source.
     * @return False, since the fixed test source never caps reads.
     */
    public Boolean readWasCapped() {
      return false;
    }
  }

  private List<StepContext.Signal> finalizeSignals() {
    List<StepContext.Signal> finalSignals = new List<StepContext.Signal>();
    for (StepContext.Signal sig : this.pendingSignals) {
      if (sig.signalId == null) {
        Id sigId = generateFakeId(Workflow_Signal__c.SObjectType);
        StepContext.Signal rebuilt = new StepContext.Signal(
            sigId,
            sig.name,
            sig.payload
          )
          .withCreatedDate(sig.createdDate);
        if (sig.isClaimed()) {
          rebuilt.asClaimed();
        }
        finalSignals.add(rebuilt);
      } else {
        finalSignals.add(sig);
      }
    }
    return finalSignals;
  }

  /**
   * @description Assembles the configured StepContext entirely in memory (0 DML,
   * 0 SOQL), supplying defaults for unset fields and wiring the static signal source.
   * @return The fully-constructed StepContext for step-level unit testing.
   */
  public StepContext build() {
    Id instanceId = (this.workflowInstanceIdVal != null)
      ? this.workflowInstanceIdVal
      : generateFakeId(Workflow_Instance__c.SObjectType);
    StaticSignalSource source = new StaticSignalSource(finalizeSignals());

    StepContext.Builder ctxBuilder = new StepContext.Builder()
      .instanceId(instanceId)
      .workflowName(
        this.workflowNameVal != null ? this.workflowNameVal : 'TestWorkflow'
      )
      .stepName(this.stepNameVal != null ? this.stepNameVal : 'TestStep')
      .inputJson(this.inputJsonVal)
      .previousStepOutput(this.previousStepOutputVal)
      .stepStateJson(this.stepStateJsonVal)
      .workflowInputJson(this.workflowInputJsonVal)
      .workflowVersion(this.exec.workflowVersionVal)
      .stepVisit(this.exec.stepVisitVal)
      .signalSource(source)
      .previousRunAt(this.exec.previousRunAtVal)
      .capturedValuesMap(new Map<String, Object>(this.capturedValues))
      .attempt(this.exec.attemptVal)
      .maxAttempts(this.exec.maxAttemptsVal);
    if (this.exec.timeoutResumeVal) {
      ctxBuilder.markTimeoutResume();
    }
    return ctxBuilder.build();
  }
}
