/**
 * @description Tests the read tracking of StepSignals: the probed names and
 * the full read. Strict determinism mode uses them to find an input that
 * arrives while a step runs.
 */
@IsTest
private class StepSignalsProbeTest {
  private static StepSignals seeded() {
    StepSignals signals = new StepSignals(null);
    signals.seedPendingSignals(
      new List<StepContext.Signal>{ new StepContext.Signal(null, 'Go', 'p') }
    );
    return signals;
  }

  @IsTest
  static void aNamedLookupIsProbedWhetherOrNotASignalIsPending() {
    StepSignals signals = seeded();
    signals.getSignal('GO');
    signals.hasSignal('Absent');
    signals.getSignals('Other');

    Assert.areEqual(
      new Set<String>{ 'go', 'absent', 'other' },
      signals.getProbedSignalNames(),
      'Each looked-up name is kept in lower case'
    );
    Assert.isFalse(signals.hasReadAllSignals(), 'No full read happened');
  }

  @IsTest
  static void aBlankNameIsNotProbed() {
    StepSignals signals = seeded();
    signals.getSignal(null);
    signals.hasSignal('');
    signals.getSignals(' ');

    Assert.isTrue(
      signals.getProbedSignalNames().isEmpty(),
      'A blank name matches nothing, so it is not probed'
    );
  }

  @IsTest
  static void theFullListReadIsRecorded() {
    StepSignals signals = seeded();
    signals.getSignals();

    Assert.isTrue(signals.hasReadAllSignals(), 'The full read is recorded');
  }

  @IsTest
  static void aChildOutcomeLookupProbesTheChildSignalNames() {
    StepSignals signals = seeded();
    signals.getChildOutcome('K1');

    Assert.isTrue(
      signals.getProbedSignalNames()
        .containsAll(new Set<String>{ 'childcompleted:k1', 'childfailed:k1' }),
      'A child lookup probes both outcome names'
    );
    Assert.isFalse(
      signals.hasReadAllSignals(),
      'A child lookup is not a full read'
    );
  }

  @IsTest
  static void theReturnedSetIsACopy() {
    StepSignals signals = seeded();
    signals.hasSignal('Go');
    signals.getProbedSignalNames().add('x');

    Assert.areEqual(
      new Set<String>{ 'go' },
      signals.getProbedSignalNames(),
      'A caller cannot change the tracking'
    );
  }
}
