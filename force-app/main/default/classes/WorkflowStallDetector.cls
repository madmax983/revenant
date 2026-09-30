/**
 * @description Sends one alert for each stalled instance (issue #139). The
 * watchdog heartbeat calls it, so it adds no scheduled job. Does not throw.
 *
 * Stall: the instance has an active status and made no progress for
 * Stall_Threshold_Minutes__c. The progress clock is the newest step
 * CreatedDate (else the instance CreatedDate). A past Sleep_Until__c that is
 * later moves the clock to the wake time. A future Sleep_Until__c on a
 * suspended instance is not a stall: the engine holds a timer.
 *
 * Dedup: a Workflow_Log__c row with the unique Fire_Key__c
 * Stall:<instanceId>:<clockMillis> claims each stall. New progress gives a new
 * clock and a new key. When no channel sends, the claim is deleted, so a
 * later sweep tries again. The detector writes only Workflow_Log__c rows.
 */
public inherited sharing class WorkflowStallDetector {
  /** @description Log_Type__c of the claim row. */
  public static final String LOG_TYPE = 'WorkflowStallAlert';

  private static final String LOG_SOURCE = 'StallAlert';
  private static final String KEY_PREFIX = 'Stall:';
  private static final Long MS_PER_MINUTE = 60000;
  // Maximum instances that one sweep reads.
  private static final Integer MAX_CANDIDATES = 1000;
  // Rows for each candidate: the instance, its newest step and its newest claim.
  private static final Integer QUERY_ROWS_PER_CANDIDATE = 3;
  // Claim insert, event publish and claim release.
  private static final Integer DML_NEEDED = 3;
  // Rows: claim, event and release for each alert.
  private static final Integer ROWS_PER_ALERT = 3;
  // Candidate query and pause cache load.
  private static final Integer SOQL_NEEDED = 2;

  private static final List<String> ACTIVE_STATUSES = new List<String>{
    'Pending',
    'Running',
    'Suspended',
    'Compensating',
    'Cancelling'
  };

  private static final List<String> ENGINE_WORKFLOWS = new List<String>{
    'WatchdogWorkflow',
    'CleanupWorkflow',
    'ArchiveWorkflow'
  };

  /** @description Maximum alerts for one sweep. The next sweep sends the rest. */
  @TestVisible
  private static Integer maxAlertsPerSweep = 100;

  @TestVisible
  private static Boolean forceBudgetExhausted = false;

  // One stall that is due for an alert.
  private class StallHit {
    public Workflow_Instance__c instance;
    public Workflow_Alert_Config__mdt config;
    public Datetime clock;
    public Integer idleMinutes;
    public Workflow_Log__c claim;
    public Boolean hasChannel = false;
    public Boolean sent = false;
  }

  /**
   * @description Finds stalled instances and sends one alert for each new
   * stall. Does not throw.
   * @return The number of stalls that got an alert.
   */
  public static Integer detectAndAlertStalls() {
    Integer alerted = 0;
    try {
      List<Workflow_Alert_Config__mdt> configs = WorkflowStallConfigResolver.getAllConfigs();
      Integer minThreshold = WorkflowStallConfigResolver.minStallThreshold(
        configs
      );
      if (minThreshold == null || !hasBudget()) {
        return 0;
      }
      List<StallHit> hits = claim(
        findStalls(System.now(), configs, minThreshold)
      );
      if (hits.isEmpty()) {
        return 0;
      }
      try {
        dispatch(hits);
      } finally {
        // Release runs also when dispatch throws, so no claim stays unsent.
        alerted = release(hits);
      }
      return alerted;
    } catch (Exception ex) {
      WorkflowLog.error(LOG_SOURCE, 'Stall alert failed: ' + ex.getMessage());
      return alerted;
    }
  }

  /**
   * @description Gives the claim key of one stall.
   * @param instanceId The stalled instance.
   * @param clock The progress clock of the stall.
   * @return The Fire_Key__c value.
   */
  @TestVisible
  private static String claimKey(Id instanceId, Datetime clock) {
    return KEY_PREFIX + instanceId + ':' + clock.getTime();
  }

  private static List<StallHit> findStalls(
    Datetime now,
    List<Workflow_Alert_Config__mdt> configs,
    Integer minThreshold
  ) {
    List<StallHit> hits = new List<StallHit>();
    for (
      Workflow_Instance__c inst : queryCandidates(
        now,
        now.addMinutes(-minThreshold)
      )
    ) {
      StallHit hit = evaluate(inst, configs, now);
      if (hit != null) {
        hits.add(hit);
        if (hits.size() >= maxAlertsPerSweep) {
          break;
        }
      }
    }
    return hits;
  }

  // One query. The anti-join drops each instance with a step after the
  // cutoff, so only idle instances fill the LIMIT. The sort puts the most
  // recently changed instances first, so a new stall comes before an old one.
  private static List<Workflow_Instance__c> queryCandidates(
    Datetime now,
    Datetime cutoff
  ) {
    return [
      SELECT
        Id,
        Name,
        Workflow_Name__c,
        Status__c,
        Current_Step__c,
        Sleep_Until__c,
        CreatedDate,
        Correlation_Key__c,
        (
          SELECT CreatedDate
          FROM Workflow_Step_Executions__r
          ORDER BY CreatedDate DESC
          LIMIT 1
        ),
        (
          SELECT CreatedDate
          FROM Workflow_Logs__r
          WHERE Log_Type__c = :LOG_TYPE
          ORDER BY CreatedDate DESC
          LIMIT 1
        )
      FROM Workflow_Instance__c
      WHERE
        Status__c IN :ACTIVE_STATUSES
        AND Workflow_Name__c NOT IN :ENGINE_WORKFLOWS
        AND (Status__c != 'Suspended'
        OR Sleep_Until__c = NULL
        OR Sleep_Until__c <= :now)
        AND CreatedDate <= :cutoff
        AND Id NOT IN (
          SELECT Workflow_Instance__c
          FROM Workflow_Step_Execution__c
          WHERE CreatedDate > :cutoff
        )
      WITH SYSTEM_MODE
      ORDER BY LastModifiedDate DESC
      LIMIT :MAX_CANDIDATES
    ];
  }

  // Gives a hit when the instance is past its threshold and has no alert for
  // this stall. Else gives null.
  private static StallHit evaluate(
    Workflow_Instance__c inst,
    List<Workflow_Alert_Config__mdt> configs,
    Datetime now
  ) {
    if (
      WorkflowPauseGate.isDefinitionPaused(inst.Workflow_Name__c) ||
      WorkflowEngine.resumedInstanceIds.contains(inst.Id)
    ) {
      return null;
    }
    Workflow_Alert_Config__mdt config = WorkflowStallConfigResolver.resolveStallConfig(
      inst.Workflow_Name__c,
      configs
    );
    if (!WorkflowStallConfigResolver.isStallEnabled(config)) {
      return null;
    }
    Datetime clock = progressClock(inst, now);
    Long idleMinutes = (now.getTime() - clock.getTime()) / MS_PER_MINUTE;
    if (
      idleMinutes < config.Stall_Threshold_Minutes__c.intValue() ||
      alertedSince(inst, clock)
    ) {
      return null;
    }
    StallHit hit = new StallHit();
    hit.instance = inst;
    hit.config = config;
    hit.clock = clock;
    hit.idleMinutes = idleMinutes.intValue();
    return hit;
  }

  private static Datetime progressClock(
    Workflow_Instance__c inst,
    Datetime now
  ) {
    Datetime clock = inst.Workflow_Step_Executions__r.isEmpty()
      ? inst.CreatedDate
      : inst.Workflow_Step_Executions__r[0].CreatedDate;
    Datetime wake = inst.Sleep_Until__c;
    return wake != null && wake <= now && wake > clock ? wake : clock;
  }

  // True when a stall row is at or after the clock. Also covers rows from
  // before the claim key.
  private static Boolean alertedSince(
    Workflow_Instance__c inst,
    Datetime clock
  ) {
    return !inst.Workflow_Logs__r.isEmpty() &&
      inst.Workflow_Logs__r[0].CreatedDate >= clock;
  }

  // Inserts the claim rows. Keeps only the hits whose claim is new.
  private static List<StallHit> claim(List<StallHit> hits) {
    if (hits.isEmpty()) {
      return hits;
    }
    List<Workflow_Log__c> rows = new List<Workflow_Log__c>();
    for (StallHit hit : hits) {
      hit.claim = buildClaim(hit);
      rows.add(hit.claim);
    }
    List<Database.SaveResult> results = Database.insert(
      rows,
      false,
      AccessLevel.SYSTEM_MODE
    );
    List<StallHit> claimed = new List<StallHit>();
    for (Integer i = 0; i < results.size(); i++) {
      if (results[i].isSuccess()) {
        claimed.add(hits[i]);
      }
    }
    return claimed;
  }

  private static Workflow_Log__c buildClaim(StallHit hit) {
    Workflow_Instance__c inst = hit.instance;
    return new Workflow_Log__c(
      Workflow_Instance__c = inst.Id,
      Workflow_Name__c = inst.Workflow_Name__c,
      Correlation_Key__c = inst.Correlation_Key__c,
      Log_Type__c = LOG_TYPE,
      Level__c = 'Warn',
      Message__c = message(hit),
      Fire_Key__c = claimKey(inst.Id, hit.clock),
      Fire_Time__c = hit.clock
    );
  }

  private static String message(StallHit hit) {
    String step = String.isBlank(hit.instance.Current_Step__c)
      ? 'none'
      : hit.instance.Current_Step__c;
    return 'Workflow stall detected (idle for ' +
      hit.idleMinutes +
      ' minutes, status ' +
      hit.instance.Status__c +
      ', current step ' +
      step +
      ')';
  }

  // Sends one email call for all hits and one event publish.
  private static void dispatch(List<StallHit> hits) {
    List<StallHit> mailHits = new List<StallHit>();
    List<Messaging.SingleEmailMessage> mails = new List<Messaging.SingleEmailMessage>();
    List<StallHit> eventHits = new List<StallHit>();
    List<Workflow_Alert__e> events = new List<Workflow_Alert__e>();
    for (StallHit hit : hits) {
      Messaging.SingleEmailMessage mail = buildEmail(hit);
      if (mail != null) {
        mailHits.add(hit);
        mails.add(mail);
      }
      if (hit.config.Publish_Alert_Event__c == true) {
        eventHits.add(hit);
        events.add(buildEvent(hit));
      }
    }
    markSent(mailHits, WorkflowAlertEmailBuilder.sendEmails(mails));
    markSent(eventHits, WorkflowAlertManager.publishEachEvent(events));
  }

  private static Messaging.SingleEmailMessage buildEmail(StallHit hit) {
    WorkflowAlertManager.StallAlertRequest request = new WorkflowAlertManager.StallAlertRequest();
    request.instance = hit.instance;
    request.config = hit.config;
    request.idleMinutes = hit.idleMinutes;
    request.thresholdMinutes = hit.config.Stall_Threshold_Minutes__c.intValue();
    return WorkflowAlertEmailBuilder.buildStallEmail(request);
  }

  private static Workflow_Alert__e buildEvent(StallHit hit) {
    WorkflowAlertManager.AlertEventRequest request = new WorkflowAlertManager.AlertEventRequest();
    request.instance = hit.instance;
    request.config = hit.config;
    request.errorMsg = message(hit);
    request.alertReason = 'stall';
    return WorkflowAlertManager.buildAlertEvent(request);
  }

  // Each hit in the list has a channel. A true result marks it sent.
  private static void markSent(List<StallHit> hits, List<Boolean> results) {
    for (Integer i = 0; i < hits.size(); i++) {
      hits[i].hasChannel = true;
      if (i < results.size() && results[i]) {
        hits[i].sent = true;
      }
    }
  }

  // Deletes the claim of each hit that has a channel but did not send. A hit
  // with no channel keeps its row: the row is the alert. Returns the count
  // of kept claims.
  private static Integer release(List<StallHit> hits) {
    List<Workflow_Log__c> unsent = new List<Workflow_Log__c>();
    Integer alerted = 0;
    for (StallHit hit : hits) {
      if (hit.hasChannel && !hit.sent) {
        unsent.add(hit.claim);
      } else {
        alerted++;
      }
    }
    if (!unsent.isEmpty()) {
      Database.delete(unsent, false, AccessLevel.SYSTEM_MODE);
    }
    return alerted;
  }

  // Keeps WatchdogLiveness.DML_RESERVE statements and queries free, and one
  // email call free.
  private static Boolean hasBudget() {
    Integer dml = DML_NEEDED + WatchdogLiveness.DML_RESERVE;
    Integer soql = SOQL_NEEDED + WatchdogLiveness.DML_RESERVE;
    return !forceBudgetExhausted &&
      Limits.getDmlStatements() + dml <= Limits.getLimitDmlStatements() &&
      Limits.getDmlRows() + ROWS_PER_ALERT * maxAlertsPerSweep + dml <=
      Limits.getLimitDmlRows() &&
      Limits.getQueries() + soql <= Limits.getLimitQueries() &&
      Limits.getQueryRows() + QUERY_ROWS_PER_CANDIDATE * MAX_CANDIDATES <=
      Limits.getLimitQueryRows() &&
      Limits.getEmailInvocations() + 1 < Limits.getLimitEmailInvocations();
  }
}
