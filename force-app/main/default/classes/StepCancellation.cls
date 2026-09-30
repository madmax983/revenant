/**
 * @description Cooperative cancel state of one step run (issue #143). Backs
 * `StepContext.isCancellationRequested()`. It reads its source only when
 * necessary:
 *
 * - A `true` answer stays `true`. No more reads.
 * - A `false` answer stays valid for `maxAgeMillis`.
 * - No read when fewer than `soqlReserve` SOQL queries remain.
 *
 * With no source (for example in `compensate()`), the answer is `false`.
 */
public inherited sharing class StepCancellation {
  /** Age in milliseconds that the no-argument check reuses a `false` answer. */
  public static final Integer DEFAULT_MAX_AGE_MILLIS = 1000;

  // SOQL queries that a check keeps free for the engine after execute().
  @TestVisible
  private static Integer soqlReserve = 20;

  private StepContext.CancellationSource source;
  private Integer defaultMaxAgeMillis;
  private Boolean requested = false;
  private Long lastReadMillis;

  /**
   * @description Makes the cancel state.
   * @param source The status reader, or null for "never cancelled".
   * @param defaultMaxAgeMillis The age for the no-argument check. Null means
   * DEFAULT_MAX_AGE_MILLIS.
   */
  public StepCancellation(
    StepContext.CancellationSource source,
    Integer defaultMaxAgeMillis
  ) {
    this.source = source;
    this.defaultMaxAgeMillis = defaultMaxAgeMillis ?? DEFAULT_MAX_AGE_MILLIS;
  }

  /**
   * @description Checks with the default age.
   * @return True when a cancel is requested.
   */
  public Boolean isRequested() {
    return isRequested(this.defaultMaxAgeMillis);
  }

  /**
   * @description Checks with the given age. Reads the source at most one time.
   * @param maxAgeMillis The age that a `false` answer stays valid. Null or a
   * negative value means 0.
   * @return True when a cancel is requested.
   */
  public Boolean isRequested(Integer maxAgeMillis) {
    if (this.requested || this.source == null || !hasSoqlHeadroom()) {
      return this.requested;
    }
    Long now = System.currentTimeMillis();
    Integer maxAge = Math.max(0, maxAgeMillis ?? 0);
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

  private static Boolean hasSoqlHeadroom() {
    return Limits.getLimitQueries() - Limits.getQueries() >= soqlReserve;
  }
}
