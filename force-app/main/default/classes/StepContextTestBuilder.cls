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

  public StepContextTestBuilder workflowInstanceId(Id val) {
    this.workflowInstanceIdVal = val;
    return this;
  }

  public StepContextTestBuilder workflowName(String val) {
    this.workflowNameVal = val;
    return this;
  }

  public StepContextTestBuilder stepName(String val) {
    this.stepNameVal = val;
    return this;
  }

  public StepContextTestBuilder inputJson(String val) {
    this.inputJsonVal = val;
    return this;
  }

  public StepContextTestBuilder input(Object val) {
    this.inputJsonVal = (val == null) ? null : JSON.serialize(val);
    return this;
  }

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

  public StepContextTestBuilder stepStateJson(String val) {
    this.stepStateJsonVal = val;
    return this;
  }

  public StepContextTestBuilder stepState(Object val) {
    this.stepStateJsonVal = (val == null) ? null : JSON.serialize(val);
    return this;
  }

  public StepContextTestBuilder workflowInputJson(String val) {
    this.workflowInputJsonVal = val;
    return this;
  }

  public StepContextTestBuilder workflowInput(Object val) {
    this.workflowInputJsonVal = (val == null) ? null : JSON.serialize(val);
    return this;
  }

  public StepContextTestBuilder workflowVersion(Integer val) {
    this.exec.workflowVersionVal = val;
    return this;
  }

  public StepContextTestBuilder stepVisit(Integer val) {
    this.exec.stepVisitVal = val;
    return this;
  }

  public StepContextTestBuilder previousRunAt(Datetime val) {
    this.exec.previousRunAtVal = val;
    return this;
  }

  public StepContextTestBuilder timeoutResume() {
    this.exec.timeoutResumeVal = true;
    return this;
  }

  public StepContextTestBuilder attempt(Integer val) {
    this.exec.attemptVal = val;
    return this;
  }

  public StepContextTestBuilder maxAttempts(Integer val) {
    this.exec.maxAttemptsVal = val;
    return this;
  }

  public StepContextTestBuilder addSignal(StepContext.Signal signal) {
    if (signal != null) {
      this.pendingSignals.add(signal);
    }
    return this;
  }

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
    public StaticSignalSource(List<StepContext.Signal> signals) {
      this.signals = (signals != null)
        ? signals
        : new List<StepContext.Signal>();
      this.signals.sort();
    }
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
    public StepContext.Signal getLatestSignal(String signalName) {
      List<StepContext.Signal> matches = getPendingSignals(signalName);
      if (matches.isEmpty()) {
        return null;
      }
      matches.sort();
      return matches[matches.size() - 1];
    }
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
