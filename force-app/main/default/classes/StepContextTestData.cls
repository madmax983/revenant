/**
 * Shared @IsTest fixtures for the StepContext capture/replay tests: fake
 * CaptureProducer and SignalSource implementations extracted from StepContextTest
 * so its child-outcome and capture-once coverage can live in a sibling @IsTest
 * class without duplicating these data builders. Behavior is identical to the
 * originals; only the enclosing type and access modifiers changed.
 */
@IsTest
public class StepContextTestData {
  /**
   * @description Fake CaptureProducer that returns a fixed String and counts how
   * many times it was invoked, so tests can assert once() runs the producer at
   * most once.
   */
  public class StringProducer implements CaptureProducer {
    public String value;
    public Integer callCount = 0;
    /**
     * @description Constructs the producer with the value to return.
     * @param value The String to produce.
     */
    public StringProducer(String value) {
      this.value = value;
    }
    /**
     * @description Returns the fixed value, incrementing the invocation count.
     * @return The configured String value.
     */
    public Object produce() {
      callCount++;
      return value;
    }
  }

  /**
   * @description Fake CaptureProducer that returns an arbitrary object value,
   * used to exercise capture-once round-tripping of non-String payloads.
   */
  public class ObjectProducer implements CaptureProducer {
    private Object value;
    /**
     * @description Constructs the producer with the value to return.
     * @param value The object to produce.
     */
    public ObjectProducer(Object value) {
      this.value = value;
    }
    /**
     * @description Returns the configured object value.
     * @return The configured object value.
     */
    public Object produce() {
      return this.value;
    }
  }

  /**
   * @description In-memory SignalSource backed by a name-keyed map, letting
   * StepContext signal tests supply pending signals with zero DML or SOQL.
   */
  public class MapSignalSource implements StepContext.SignalSource {
    private final Map<String, StepContext.Signal> signals;
    /**
     * @description Constructs the source from a lower-cased name to signal map.
     * @param signals The pending signals keyed by lower-cased name.
     */
    public MapSignalSource(Map<String, StepContext.Signal> signals) {
      this.signals = signals;
    }
    /**
     * @description Returns pending signals for the name, or all signals when the
     * name is blank.
     * @param name The signal name to match, or blank for all.
     * @return The matching pending signals.
     */
    public List<StepContext.Signal> getPendingSignals(String name) {
      if (String.isBlank(name)) {
        return signals.values();
      }
      StepContext.Signal s = signals.get(name.toLowerCase());
      return s != null
        ? new List<StepContext.Signal>{ s }
        : new List<StepContext.Signal>();
    }
    /**
     * @description Returns the single signal mapped to the name, or null.
     * @param name The signal name to match.
     * @return The matching signal, or null when absent or the name is blank.
     */
    public StepContext.Signal getLatestSignal(String name) {
      if (String.isBlank(name)) {
        return null;
      }
      return signals.get(name.toLowerCase());
    }
    /**
     * @description Never caps reads in this in-memory fixture.
     * @return Always false.
     */
    public Boolean readWasCapped() {
      return false;
    }
  }
}
