/**
 * @description Unit tests for the cooperative cancel accessor (issue #143):
 * `StepContext.isCancellationRequested()` and its cache in `StepCancellation`.
 * All tests run in memory with a counting source (0 SOQL, 0 DML).
 */
@IsTest
private class StepCancellationTest {
  private static final Integer ONE_HOUR_MILLIS = 3600000;

  /**
   * @description Source stub. It gives a fixed answer and counts the reads.
   */
  private class CountingSource implements StepContext.CancellationSource {
    private Boolean answer;
    private Integer reads = 0;

    /**
     * @description Makes a source that gives the same answer each time.
     * @param answer The answer to give.
     */
    public CountingSource(Boolean answer) {
      this.answer = answer;
    }

    /**
     * @description Counts the read and gives the answer.
     * @return The fixed answer.
     */
    public Boolean isCancellationRequested() {
      this.reads++;
      return this.answer;
    }
  }

  private static StepContext contextWith(CountingSource source) {
    return new StepContext.Builder()
      .stepName('LoopStep')
      .cancellationSource(source)
      .build();
  }

  @IsTest
  static void noSourceGivesFalseWithNoQuery() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Integer queriesBefore = Limits.getQueries();
      StepContext ctx = new StepContext.Builder().stepName('X').build();

      Assert.isFalse(ctx.isCancellationRequested());
      Assert.isFalse(ctx.isCancellationRequested(0));
      Assert.isFalse(ctx.wasCancellationObserved());
      Assert.areEqual(queriesBefore, Limits.getQueries(), 'No SOQL');
    }
  }

  @IsTest
  static void trueIsKeptWithNoSecondRead() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      CountingSource source = new CountingSource(true);
      StepContext ctx = contextWith(source);

      Assert.isTrue(ctx.isCancellationRequested(0));
      Assert.isTrue(ctx.isCancellationRequested(0));
      Assert.isTrue(ctx.isCancellationRequested());
      Assert.areEqual(1, source.reads, 'A true answer stays true');
      Assert.isTrue(ctx.wasCancellationObserved());
    }
  }

  @IsTest
  static void falseIsCachedWithinMaxAge() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      CountingSource source = new CountingSource(false);
      StepContext ctx = contextWith(source);

      Assert.isFalse(ctx.isCancellationRequested(ONE_HOUR_MILLIS));
      Assert.isFalse(ctx.isCancellationRequested(ONE_HOUR_MILLIS));
      Assert.areEqual(1, source.reads, 'The second call uses the cache');
      Assert.isFalse(ctx.wasCancellationObserved());
    }
  }

  @IsTest
  static void zeroMaxAgeReadsEachCall() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      CountingSource source = new CountingSource(false);
      StepContext ctx = contextWith(source);

      ctx.isCancellationRequested(ONE_HOUR_MILLIS);
      ctx.isCancellationRequested(0);
      ctx.isCancellationRequested(0);
      Assert.areEqual(3, source.reads, 'Age 0 always reads');
    }
  }

  @IsTest
  static void negativeMaxAgeReadsEachCall() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      CountingSource source = new CountingSource(false);
      StepContext ctx = contextWith(source);

      ctx.isCancellationRequested(-5);
      ctx.isCancellationRequested(-5);
      Assert.areEqual(2, source.reads, 'A negative age means 0');
    }
  }

  @IsTest
  static void nullMaxAgeUsesDefault() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      CountingSource source = new CountingSource(false);
      StepContext ctx = contextWith(source);

      ctx.isCancellationRequested(null);
      ctx.isCancellationRequested(null);
      Assert.areEqual(1, source.reads, 'Null means the default age');
    }
  }

  @IsTest
  static void defaultMaxAgeCachesFalse() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      CountingSource source = new CountingSource(false);
      StepContext ctx = contextWith(source);

      ctx.isCancellationRequested();
      ctx.isCancellationRequested();
      Assert.areEqual(
        1,
        source.reads,
        'The no-argument call reuses a false answer for the default age'
      );
      Assert.areEqual(1000, StepCancellation.DEFAULT_MAX_AGE_MILLIS);
    }
  }

  @IsTest
  static void builderSetsDefaultMaxAge() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      CountingSource source = new CountingSource(false);
      StepContext ctx = new StepContext.Builder()
        .stepName('LoopStep')
        .cancellationSource(source)
        .cancellationMaxAgeMillis(0)
        .build();

      ctx.isCancellationRequested();
      ctx.isCancellationRequested();
      Assert.areEqual(2, source.reads, 'Default age 0 reads each call');
    }
  }

  @IsTest
  static void lowSoqlHeadroomSkipsRead() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      CountingSource source = new CountingSource(true);
      StepContext ctx = contextWith(source);
      StepCancellation.soqlReserve = Limits.getLimitQueries() + 1;

      Assert.isFalse(ctx.isCancellationRequested(0));
      Assert.areEqual(0, source.reads, 'No read without SOQL headroom');
      Assert.isFalse(ctx.wasCancellationObserved());
    }
  }

  @IsTest
  static void exactReserveSkipsRead() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      CountingSource source = new CountingSource(true);
      StepContext ctx = contextWith(source);
      StepCancellation.soqlReserve =
        Limits.getLimitQueries() - Limits.getQueries();

      Assert.isFalse(ctx.isCancellationRequested(0));
      Assert.areEqual(0, source.reads, 'The reserve stays free');
    }
  }

  @IsTest
  static void reserveIsTwentyOrAFifthOfTheLimit() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Assert.areEqual(
        Math.max(20, Limits.getLimitQueries() / 5),
        StepCancellation.reserve()
      );
    }
  }

  @IsTest
  static void lowHeadroomKeepsAnEarlierTrue() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      CountingSource source = new CountingSource(true);
      StepContext ctx = contextWith(source);
      Assert.isTrue(ctx.isCancellationRequested(0));

      StepCancellation.soqlReserve = Limits.getLimitQueries() + 1;
      Assert.isTrue(ctx.isCancellationRequested(0));
      Assert.areEqual(1, source.reads);
    }
  }

  @IsTest
  static void accessorDoesNoDml() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Integer dmlBefore = Limits.getDmlStatements();
      StepContext ctx = contextWith(new CountingSource(true));

      ctx.isCancellationRequested(0);
      Assert.areEqual(dmlBefore, Limits.getDmlStatements(), 'No DML');
    }
  }
}
