/**
 * Shared @IsTest fixtures for the StepContext capture/replay tests: fake
 * CaptureProducer and SignalSource implementations extracted from StepContextTest
 * so its child-outcome and capture-once coverage can live in a sibling @IsTest
 * class without duplicating these data builders. Behavior is identical to the
 * originals; only the enclosing type and access modifiers changed.
 */
@IsTest
public class StepContextTestData {
  public class StringProducer implements CaptureProducer {
    public String value;
    public Integer callCount = 0;
    public StringProducer(String value) {
      this.value = value;
    }
    public Object produce() {
      callCount++;
      return value;
    }
  }

  public class ObjectProducer implements CaptureProducer {
    private Object value;
    public ObjectProducer(Object value) {
      this.value = value;
    }
    public Object produce() {
      return this.value;
    }
  }

  public class MapSignalSource implements StepContext.SignalSource {
    private final Map<String, StepContext.Signal> signals;
    public MapSignalSource(Map<String, StepContext.Signal> signals) {
      this.signals = signals;
    }
    public List<StepContext.Signal> getPendingSignals(String name) {
      if (String.isBlank(name)) {
        return signals.values();
      }
      StepContext.Signal s = signals.get(name.toLowerCase());
      return s != null
        ? new List<StepContext.Signal>{ s }
        : new List<StepContext.Signal>();
    }
    public StepContext.Signal getLatestSignal(String name) {
      if (String.isBlank(name)) {
        return null;
      }
      return signals.get(name.toLowerCase());
    }
    public Boolean readWasCapped() {
      return false;
    }
  }
}
