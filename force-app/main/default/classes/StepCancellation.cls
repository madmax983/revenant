/**
 * @description Cooperative cancel state of one step run (issue #143). Backs
 * `StepContext.isCancellationRequested()`. It reads its source only when
 * necessary:
 *
 * - It keeps a `true` answer. It does not read again.
 * - It keeps a `false` answer for `maxAgeMillis`.
 * - It does not read when the SOQL queries left are not more than the reserve.
 *
 * With no source (for example in `compensate()`), the answer is `false`.
 */
public inherited sharing class StepCancellation {
  /** Milliseconds that the no-argument check keeps a `false` answer. */
  public static final Integer DEFAULT_MAX_AGE_MILLIS = 1000;

  // Minimum SOQL queries that a check keeps free for the engine after execute().
  private static final Integer MIN_SOQL_RESERVE = 20;

  // Test override of the reserve. Null means the computed reserve.
  @TestVisible
  private static Integer soqlReserve;

  private StepContext.CancellationSource source;
  private Integer defaultMaxAgeMillis;
  private Boolean requested = false;
  private Long lastReadMillis;

  /**
   * @description Makes the cancel state.
   * @param source The status reader, or null for "never cancelled".
   * @param defaultMaxAgeMillis The age for the no-argument check. Null means
   * DEFAULT_MAX_AGE_MILLIS. A negative value means 0.
   */
  public StepCancellation(
    StepContext.CancellationSource source,
    Integer defaultMaxAgeMillis
  ) {
    this.source = source;
    this.defaultMaxAgeMillis = Math.max(
      0,
      defaultMaxAgeMillis ?? DEFAULT_MAX_AGE_MILLIS
    );
  }

  /**
   * @description Checks with the default age.
   * @return True when a cancel is requested.
   */
  public Boolean isRequested() {
    return isRequested(null);
  }

  /**
   * @description Checks with the given age. Reads the source one time at most.
   * @param maxAgeMillis Milliseconds that a `false` answer stays valid. Null
   * means the default age. A negative value means 0.
   * @return True when a cancel is requested.
   */
  public Boolean isRequested(Integer maxAgeMillis) {
    if (this.requested || this.source == null || !hasSoqlHeadroom()) {
      return this.requested;
    }
    Long now = System.currentTimeMillis();
    Integer maxAge = Math.max(0, maxAgeMillis ?? this.defaultMaxAgeMillis);
    if (this.lastReadMillis != null && now - this.lastReadMillis < maxAge) {
      return false;
    }
    this.lastReadMillis = now;
    this.requested = this.source.isCancellationRequested() == true;
    return this.requested;
  }

  /**
   * @description Tells if a check in this run gave `true`.
   * @return True when the step saw a cancel.
   */
  public Boolean wasObserved() {
    return this.requested;
  }

  /**
   * @description The SOQL queries that a check keeps free: 20, or 20% of the
   * limit when that is more. At 20%, `shouldYield()` also gives true.
   * @return The reserve.
   */
  @TestVisible
  private static Integer reserve() {
    return soqlReserve ??
      Math.max(MIN_SOQL_RESERVE, Limits.getLimitQueries() / 5);
  }

  private static Boolean hasSoqlHeadroom() {
    return Limits.getLimitQueries() - Limits.getQueries() > reserve();
  }
}
