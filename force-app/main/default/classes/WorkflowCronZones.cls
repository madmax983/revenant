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
    DateTime localHit = WorkflowCronEvaluator.previousFireTime(
      req.cronExpr,
      localNow
    );
    if (localHit == null) {
      return null;
    }
    return CronMath.resolveLocalToUtc(req.zoneId, localHit);
  }

  // Forward-search resolver. Walks local wall-clock matches from `localNow` and
  // resolves each to a UTC instant. During a fall-back overlap the same local
  // wall clock occurs twice and CronMath.resolveLocalToUtc deliberately returns
  // the EARLIEST (pre-transition) occurrence — correct for due-detection, but for
  // a forward search that earliest instant can land BEFORE req.now (e.g. local
  // 01:30 on a fall-back day resolving to 05:30Z when req.now is 06:00Z). When
  // the resolved instant is strictly before req.now it is rejected and the walk
  // advances to the next local match, so nextFireTime always returns a
  // strictly-future (>= req.now) instant. A normal (non-overlap) forward search
  // accepts the first match unchanged, since its resolved instant is >= req.now.
  private static DateTime resolveForwardHit(
    ResolveRequest req,
    DateTime localNow
  ) {
    DateTime localHit = WorkflowCronEvaluator.nextFireTime(
      req.cronExpr,
      localNow
    );
    while (localHit != null) {
      DateTime utc = CronMath.resolveLocalToUtc(req.zoneId, localHit);
      if (utc == null || utc >= req.now) {
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
