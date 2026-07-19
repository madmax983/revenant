/**
 * Time-zone support for the cron evaluator, lifted out of WorkflowCronEvaluator
 * so that class stays under its aggregate complexity budget.
 *
 * Two responsibilities live here:
 *   - The supported-zone allow-list and its validation/listing, backing the
 *     editor's time-zone picker and the save/sweep validation gates.
 *   - The zone-aware fire-time walk: project `now` into the target zone's
 *     wall-clock "space" (a pseudo-GMT DateTime whose Gmt fields ARE the local
 *     Y/M/D/H/M), reuse WorkflowCronEvaluator's exact UTC walk there, then
 *     resolve the matched local wall clock back to a real UTC instant with DST
 *     gap/overlap policy via CronMath.resolveLocalToUtc.
 *
 * A blank/UTC zone never reaches here — WorkflowCronEvaluator keeps the exact-GMT
 * path for that case — so the pre-existing behavior stays byte-identical.
 */
public inherited sharing class WorkflowCronZones {
  // Curated set of supported IANA time-zone ids. Salesforce's
  // TimeZone.getTimeZone returns GMT for an unknown id rather than failing, so
  // a supplied zone is validated against this explicit allow-list instead. The
  // same set backs the editor's time-zone picker (WorkflowScheduleController).
  private static final Set<String> SUPPORTED_ZONES = new Set<String>{
    'UTC',
    'Pacific/Honolulu',
    'America/Anchorage',
    'America/Los_Angeles',
    'America/Phoenix',
    'America/Denver',
    'America/Chicago',
    'America/New_York',
    'America/Sao_Paulo',
    'Europe/London',
    'Europe/Paris',
    'Europe/Berlin',
    'Europe/Madrid',
    'Europe/Moscow',
    'Africa/Johannesburg',
    'Asia/Dubai',
    'Asia/Kolkata',
    'Asia/Singapore',
    'Asia/Shanghai',
    'Asia/Tokyo',
    'Australia/Sydney',
    'Pacific/Auckland'
  };

  /**
   * @description Whether a schedule time zone is usable. A blank/null zone means UTC and is
   * always valid (it preserves the pre-existing exact-GMT behavior). A non-blank zone must
   * be one of the supported IANA ids: Salesforce's TimeZone API silently falls back to GMT
   * for an unknown id, so validation is an explicit allow-list check rather than a round-trip.
   * @param zoneId The candidate IANA time-zone id, or blank/null for UTC.
   * @return True if the zone is blank (UTC) or a supported IANA id, otherwise false.
   */
  public static Boolean isZoneSupported(String zoneId) {
    if (String.isBlank(zoneId)) {
      return true;
    }
    return SUPPORTED_ZONES.contains(zoneId);
  }

  /**
   * @description The supported IANA time-zone ids offered by the editor's time-zone picker,
   * sorted alphabetically for a stable combobox ordering.
   * @return The sorted list of supported IANA time-zone ids.
   */
  public static List<String> listZones() {
    List<String> zones = new List<String>(SUPPORTED_ZONES);
    zones.sort();
    return zones;
  }

  /**
   * @description Most-recent fire instant at or before `now` for a cron interpreted in the
   * given zone (blank/null = UTC). See resolve() for the DST policy.
   * @param cronExpr The 5-field cron expression to evaluate.
   * @param now The UTC reference instant.
   * @param zoneId The IANA time-zone id, or blank/null for UTC.
   * @return The resolved UTC fire instant, or null.
   */
  public static DateTime previous(
    String cronExpr,
    DateTime now,
    String zoneId
  ) {
    ResolveRequest req = new ResolveRequest();
    req.cronExpr = cronExpr;
    req.now = now;
    req.forward = false;
    req.zoneId = zoneId;
    return resolve(req);
  }

  /**
   * @description Next fire instant at or after `now` for a cron interpreted in the given zone
   * (blank/null = UTC). See resolve() for the DST policy.
   * @param cronExpr The 5-field cron expression to evaluate.
   * @param now The UTC reference instant.
   * @param zoneId The IANA time-zone id, or blank/null for UTC.
   * @return The resolved UTC fire instant, or null.
   */
  public static DateTime next(String cronExpr, DateTime now, String zoneId) {
    ResolveRequest req = new ResolveRequest();
    req.cronExpr = cronExpr;
    req.now = now;
    req.forward = true;
    req.zoneId = zoneId;
    return resolve(req);
  }

  // Resolves a zone-aware request. A blank/null zone routes to the exact-GMT
  // walk (byte-identical to the pre-existing behavior). A non-blank zone projects
  // `now` into the zone's wall clock, runs the exact UTC walk in that space, then
  // resolves the matched local wall clock to a UTC instant with DST gap/overlap
  // policy via CronMath.resolveLocalToUtc.
  private static DateTime resolve(ResolveRequest req) {
    if (String.isBlank(req.zoneId)) {
      return req.forward
        ? WorkflowCronEvaluator.nextFireTime(req.cronExpr, req.now)
        : WorkflowCronEvaluator.previousFireTime(req.cronExpr, req.now);
    }
    if (req.now == null) {
      return null;
    }
    DateTime localNow = DateTime.valueOfGmt(
      req.now.format('yyyy-MM-dd HH:mm:ss', req.zoneId)
    );
    if (req.forward) {
      return resolveForwardHit(req, localNow);
    }
    return resolveBackwardHit(req, localNow);
  }

  // Backward-search resolver. The naive walk projects `now` to a single local
  // wall clock and runs the pure-UTC previous-fire walk there, then resolves the
  // matched local wall clock to a UTC instant. That single projection is faithful
  // everywhere EXCEPT inside a fall-back overlap's SECOND (post-transition)
  // occurrence: there the repeated local hour's cron windows already fired at
  // their EARLIER (pre-transition) UTC occurrence — which is < now — but the
  // post-transition projection makes those windows look "future", so the naive
  // walk skips them (to an earlier window, or even the prior day). The overlap
  // candidate walk recovers the true most-recent fire by enumerating the repeated
  // hour's cron windows, resolving each to its EARLIEST UTC occurrence (the same
  // fire-once policy the corrKey/Fire_Key depend on, per CronMath.resolveLocalToUtc)
  // and keeping the latest such instant that is at or before now. The later of the
  // two candidates is returned; both are real fires <= now, so the result is the
  // most-recent fire window at or before now.
  private static DateTime resolveBackwardHit(
    ResolveRequest req,
    DateTime localNow
  ) {
    DateTime localHit = WorkflowCronEvaluator.previousFireTime(
      req.cronExpr,
      localNow
    );
    if (localHit == null) {
      return null;
    }
    DateTime naiveUtc = CronMath.resolveLocalToUtc(req.zoneId, localHit);
    DateTime overlapUtc = overlapFallBackHit(req, localNow);
    if (overlapUtc != null && (naiveUtc == null || overlapUtc > naiveUtc)) {
      return overlapUtc;
    }
    return naiveUtc;
  }

  /**
   * @description Recovers the most-recent fire instant hidden by a fall-back overlap when
   * `now` sits in the repeated hour's SECOND (post-transition) occurrence. When `now`'s local
   * hour is a fall-back-repeated hour, this walks that local hour's cron windows, resolves each
   * to its EARLIEST UTC occurrence (the pre-transition instant chosen by
   * CronMath.resolveLocalToUtc so a window fires exactly once), and returns the latest such
   * instant that is at or before `now` (truncated to the minute). Returns null when `now`'s
   * local hour is not a fall-back-repeated hour (all normal days, spring days, and instants
   * outside the overlap hour), leaving the naive backward walk's result untouched. The
   * at-or-before-now filter guarantees the returned instant never exceeds `now` and never
   * returns a repeated-hour window that has not yet fired at its earliest occurrence.
   * @param req The zone-aware resolve request (cron, now, zoneId).
   * @param localNow `now` projected into the zone's wall clock as a pseudo-GMT DateTime.
   * @return The latest earliest-UTC repeated-hour fire at or before now, or null when
   * `now`'s local hour is not a fall-back-repeated hour.
   */
  private static DateTime overlapFallBackHit(
    ResolveRequest req,
    DateTime localNow
  ) {
    // The local hour containing `now`, as a pseudo-GMT wall clock (H:00 local).
    DateTime hourStartLocal = DateTime.newInstanceGmt(
      localNow.yearGmt(),
      localNow.monthGmt(),
      localNow.dayGmt(),
      localNow.hourGmt(),
      0,
      0
    );
    if (!isFallBackRepeatedHour(req.zoneId, hourStartLocal)) {
      return null;
    }
    return latestRepeatedHourFire(req, hourStartLocal);
  }

  /**
   * @description True when the given local hour is the SECOND (repeated) occurrence of a
   * fall-back overlap: its earliest UTC occurrence and the instant exactly one DST hour later
   * both render to the same local wall clock. Normal hours, spring-gap hours, and hours outside
   * an overlap render to distinct wall clocks one hour apart and return false.
   * @param zoneId The IANA time-zone id.
   * @param hourStartLocal The local hour start (H:00) as a pseudo-GMT DateTime.
   * @return True when the local hour is a fall-back-repeated hour, otherwise false.
   */
  private static Boolean isFallBackRepeatedHour(
    String zoneId,
    DateTime hourStartLocal
  ) {
    DateTime earliestHour = CronMath.resolveLocalToUtc(zoneId, hourStartLocal);
    if (earliestHour == null) {
      return false;
    }
    return wallClockRendersTo(earliestHour.addHours(1), zoneId, hourStartLocal);
  }

  /**
   * @description Walks the cron windows within a single repeated local hour from H:59
   * downwards, resolves each to its EARLIEST UTC occurrence (the fire-once instant per
   * CronMath.resolveLocalToUtc), and returns the latest such instant at or before `now`
   * (truncated to the minute). The walk is bounded to the one local hour — it stops as soon as
   * a match falls before the hour start — so at most one hour of cron windows is scanned.
   * @param req The zone-aware resolve request (cron, now, zoneId).
   * @param hourStartLocal The repeated local hour start (H:00) as a pseudo-GMT DateTime.
   * @return The latest earliest-UTC repeated-hour fire at or before now, or null if none.
   */
  private static DateTime latestRepeatedHourFire(
    ResolveRequest req,
    DateTime hourStartLocal
  ) {
    DateTime nowFloor = CronMath.truncateToMinute(req.now);
    DateTime best = null;
    DateTime cursor = hourStartLocal.addMinutes(59);
    for (Integer guard = 0; guard < 70 && cursor != null; guard++) {
      DateTime localMatch = WorkflowCronEvaluator.previousFireTime(
        req.cronExpr,
        cursor
      );
      if (localMatch == null || localMatch < hourStartLocal) {
        break;
      }
      DateTime utc = CronMath.resolveLocalToUtc(req.zoneId, localMatch);
      if (utc != null && utc <= nowFloor && (best == null || utc > best)) {
        best = utc;
      }
      cursor = localMatch.addMinutes(-1);
    }
    return best;
  }

  /**
   * @description True when the candidate UTC instant renders to exactly the requested local
   * wall clock in the target zone (minute granularity). Used to detect a fall-back overlap
   * without a direct zone-offset API. Kept local to this class (a distinct simple name) so it
   * is never confused with the identically-purposed private helper in CronMath.
   * @param candidate The UTC instant to test.
   * @param zoneId The IANA time-zone id.
   * @param want The requested local wall clock as a pseudo-GMT DateTime.
   * @return True if the candidate's zone wall clock equals the requested wall clock.
   */
  private static Boolean wallClockRendersTo(
    DateTime candidate,
    String zoneId,
    DateTime want
  ) {
    return candidate.format('yyyy-MM-dd HH:mm', zoneId) ==
      want.formatGmt('yyyy-MM-dd HH:mm');
  }

  // Forward-search resolver. Walks local wall-clock matches from `localNow` and
  // resolves each to a UTC instant. During a fall-back overlap the same local
  // wall clock occurs twice and CronMath.resolveLocalToUtc deliberately returns
  // the EARLIEST (pre-transition) occurrence — correct for due-detection, but for
  // a forward search that earliest instant can land BEFORE req.now (e.g. local
  // 01:30 on a fall-back day resolving to 05:30Z when req.now is 06:00Z). When
  // the resolved instant is earlier than req.now it is rejected and the walk
  // advances to the next local match, so nextFireTime always returns a
  // future (>= req.now) instant. A normal (non-overlap) forward search accepts
  // the first match unchanged, since its resolved instant is >= req.now.
  //
  // The comparison floor is req.now truncated to the minute: candidate fire
  // instants are minute-aligned (seconds zeroed by the cron walk), so comparing
  // against an untruncated req.now that carries seconds (e.g. 09:00:30) would
  // reject the current-minute window (09:00 → resolved UTC) and skip it to the
  // next day. The blank/UTC path already truncates `now` to the minute before
  // matching (WorkflowCronEvaluator.fireTime), so flooring here keeps the two
  // paths consistent — the current minute is accepted while genuinely-prior
  // fall-back occurrences (earlier than the current minute) are still rejected.
  private static DateTime resolveForwardHit(
    ResolveRequest req,
    DateTime localNow
  ) {
    DateTime nowFloor = CronMath.truncateToMinute(req.now);
    DateTime localHit = WorkflowCronEvaluator.nextFireTime(
      req.cronExpr,
      localNow
    );
    while (localHit != null) {
      DateTime utc = CronMath.resolveLocalToUtc(req.zoneId, localHit);
      if (utc == null || utc >= nowFloor) {
        return utc;
      }
      localHit = WorkflowCronEvaluator.nextFireTime(
        req.cronExpr,
        localHit.addMinutes(1)
      );
    }
    return null;
  }

  // Bundles a zone-aware resolve request so the resolver takes one argument
  // rather than a four-item (Boolean-bearing) parameter list.
  private class ResolveRequest {
    private String cronExpr;
    private DateTime now;
    private Boolean forward;
    private String zoneId;
  }
}
