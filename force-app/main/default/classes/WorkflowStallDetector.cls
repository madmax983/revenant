/**
 * @description Proactive stall-detection service for the workflow alerting subsystem.
 * Scans non-terminal workflow instances for inactivity beyond their configured stall
 * threshold and dispatches the resulting emails, platform events and log markers in bulk.
 * Callbacks into WorkflowAlertManager reuse the shared event-building and publishing logic.
 */
public inherited sharing class WorkflowStallDetector {
  /**
   * @description Mutable accumulator threaded through the stall-detection scan.
   */
  private class StallScan {
    /** @description The scan's reference timestamp. */
    public Datetime now;
    /** @description The active stall configs to resolve candidates against. */
    public List<Workflow_Alert_Config__mdt> configs;
    /** @description Ids of suspended instances that have a pending step. */
    public Set<Id> suspendedWithPendingSteps;
    /** @description Accumulated stall alert emails to send in bulk. */
    public List<Messaging.SingleEmailMessage> emails;
    /** @description Accumulated stall alert platform events to publish in bulk. */
    public List<Workflow_Alert__e> events;
    /** @description Accumulated stall alert log markers to insert in bulk. */
    public List<Workflow_Log__c> logs;
  }

  /**
   * @description A single instance that has been confirmed stalled and is due for alerting.
   */
  private class StallHit {
    /** @description The stalled workflow instance. */
    public Workflow_Instance__c instance;
    /** @description The resolved alert config for the instance. */
    public Workflow_Alert_Config__mdt config;
    /** @description How long the instance has been idle, in minutes. */
    public Long idleMinutes;
    /** @description The configured stall threshold, in minutes. */
    public Integer threshold;
  }

  /**
   * @description Proactively identifies stuck workflows in non-terminal states and triggers
   * alerts, dispatching gathered emails, events and log markers in bulk.
   */
  public static void detectAndAlertStalls() {
    Datetime now = System.now();

    // 1. Get active configs
    List<Workflow_Alert_Config__mdt> configs = WorkflowStallConfigResolver.getActiveStallConfigs();
    if (configs.isEmpty()) {
      return;
    }

    // 2. Query candidates using parent-child subqueries.
    List<Workflow_Instance__c> candidates = queryStallCandidates(now);
    if (candidates.isEmpty()) {
      return;
    }

    // 3. Scan candidates, accumulating emails / events / log markers.
    StallScan scan = new StallScan();
    scan.now = now;
    scan.configs = configs;
    scan.suspendedWithPendingSteps = suspendedWithPendingSteps(candidates);
    scan.emails = new List<Messaging.SingleEmailMessage>();
    scan.events = new List<Workflow_Alert__e>();
    scan.logs = new List<Workflow_Log__c>();

    for (Workflow_Instance__c inst : candidates) {
      processStallCandidate(inst, scan);
    }

    // 4. Bulk dispatch and DML logs.
    dispatchStallAlerts(scan);
  }

  /**
   * @description Queries non-terminal instances that may have stalled, eliminating the 50k
   * SOQL-row-processed limit risk via parent-child subqueries.
   * @param now The scan's reference timestamp used to filter resumable suspensions.
   * @return The candidate instances to evaluate for stalls.
   */
  private static List<Workflow_Instance__c> queryStallCandidates(Datetime now) {
    return [
      SELECT
        Id,
        Name,
        Workflow_Name__c,
        Status__c,
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
          WHERE Log_Type__c = 'WorkflowStallAlert'
          ORDER BY CreatedDate DESC
          LIMIT 1
        )
      FROM Workflow_Instance__c
      WHERE
        Status__c IN (
          'Pending',
          'Running',
          'Suspended',
          'Compensating',
          'Cancelling'
        )
        AND Workflow_Name__c NOT IN ('WatchdogWorkflow', 'CleanupWorkflow')
        AND (Status__c != 'Suspended'
        OR Sleep_Until__c = NULL
        OR Sleep_Until__c <= :now)
      WITH SYSTEM_MODE
      ORDER BY CreatedDate ASC
      LIMIT 1000
    ];
  }

  /**
   * @description Determines which suspended instances have a Pending step (waiting on
   * approval or a signal) and should therefore be skipped by the scan.
   * @param candidates The candidate instances being scanned.
   * @return The ids of suspended instances that have at least one pending step.
   */
  private static Set<Id> suspendedWithPendingSteps(
    List<Workflow_Instance__c> candidates
  ) {
    Set<Id> suspendedIds = new Set<Id>();
    for (Workflow_Instance__c inst : candidates) {
      if (inst.Status__c == 'Suspended') {
        suspendedIds.add(inst.Id);
      }
    }

    Set<Id> result = new Set<Id>();
    if (suspendedIds.isEmpty()) {
      return result;
    }
    for (Workflow_Step_Execution__c step : [
      SELECT Workflow_Instance__c
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c IN :suspendedIds AND Status__c = 'Pending'
      WITH SYSTEM_MODE
    ]) {
      result.add(step.Workflow_Instance__c);
    }
    return result;
  }

  /**
   * @description Evaluates one candidate and appends any due alert artefacts to the scan.
   * @param inst The candidate workflow instance to evaluate.
   * @param scan The mutable scan accumulator to append alert artefacts to.
   */
  private static void processStallCandidate(
    Workflow_Instance__c inst,
    StallScan scan
  ) {
    if (shouldSkipCandidate(inst, scan.suspendedWithPendingSteps)) {
      return;
    }

    Workflow_Alert_Config__mdt config = WorkflowStallConfigResolver.resolveStallConfig(
      inst.Workflow_Name__c,
      scan.configs
    );
    if (!hasStallThreshold(config)) {
      return;
    }
    Integer threshold = config.Stall_Threshold_Minutes__c.intValue();

    Datetime lastProgress = lastProgressTime(inst);
    Datetime lastAlert = lastAlertTime(inst);

    Long diffMs = scan.now.getTime() - lastProgress.getTime();
    Long diffMinutes = diffMs / (1000 * 60);
    if (diffMinutes < threshold) {
      return;
    }

    // Suppress if an alert was already logged since the last progress.
    if (lastAlert != null && lastAlert >= lastProgress) {
      return;
    }

    StallHit hit = new StallHit();
    hit.instance = inst;
    hit.config = config;
    hit.idleMinutes = diffMinutes;
    hit.threshold = threshold;
    appendStallAlert(hit, scan);
  }

  /**
   * @description Decides whether a candidate should be skipped: paused definitions,
   * in-transaction resumes and suspended instances awaiting a pending step.
   * @param inst The candidate workflow instance.
   * @param suspendedWithPendingSteps Ids of suspended instances with a pending step.
   * @return True when the candidate should be skipped by the scan.
   */
  private static Boolean shouldSkipCandidate(
    Workflow_Instance__c inst,
    Set<Id> suspendedWithPendingSteps
  ) {
    if (WorkflowPauseGate.isDefinitionPaused(inst.Workflow_Name__c)) {
      return true;
    }
    if (WorkflowEngine.resumedInstanceIds.contains(inst.Id)) {
      return true;
    }
    return inst.Status__c == 'Suspended' &&
      suspendedWithPendingSteps.contains(inst.Id);
  }

  /**
   * @description Determines whether a config has stall alerting enabled with a positive
   * threshold.
   * @param config The resolved alert config to inspect.
   * @return True when the config enables stall alerting with a positive threshold.
   */
  private static Boolean hasStallThreshold(Workflow_Alert_Config__mdt config) {
    return config != null &&
      config.Enable_Alerts__c &&
      config.Stall_Threshold_Minutes__c != null &&
      config.Stall_Threshold_Minutes__c > 0;
  }

  /**
   * @description Returns the most recent step-execution time, falling back to the instance
   * creation time when no steps have executed.
   * @param inst The workflow instance to inspect.
   * @return The timestamp of the instance's last observed progress.
   */
  private static Datetime lastProgressTime(Workflow_Instance__c inst) {
    if (
      inst.Workflow_Step_Executions__r != null &&
      !inst.Workflow_Step_Executions__r.isEmpty()
    ) {
      return inst.Workflow_Step_Executions__r[0].CreatedDate;
    }
    return inst.CreatedDate;
  }

  /**
   * @description Returns the most recent stall-alert log time, or null when none has been
   * recorded.
   * @param inst The workflow instance to inspect.
   * @return The timestamp of the last stall alert logged for the instance, or null.
   */
  private static Datetime lastAlertTime(Workflow_Instance__c inst) {
    if (inst.Workflow_Logs__r != null && !inst.Workflow_Logs__r.isEmpty()) {
      return inst.Workflow_Logs__r[0].CreatedDate;
    }
    return null;
  }

  /**
   * @description Builds the email, event and log marker for a confirmed stall and appends
   * them to the scan accumulator.
   * @param hit The confirmed stall to build alert artefacts for.
   * @param scan The mutable scan accumulator to append alert artefacts to.
   */
  private static void appendStallAlert(StallHit hit, StallScan scan) {
    Workflow_Instance__c inst = hit.instance;
    Workflow_Alert_Config__mdt config = hit.config;
    String message =
      'Workflow stall detected (idle for ' +
      hit.idleMinutes +
      ' minutes)';

    // Build alert email if recipients configured
    if (String.isNotBlank(config.Email_Recipients__c)) {
      WorkflowAlertManager.StallAlertRequest request = new WorkflowAlertManager.StallAlertRequest();
      request.instance = inst;
      request.config = config;
      request.idleMinutes = hit.idleMinutes.intValue();
      request.thresholdMinutes = hit.threshold;
      Messaging.SingleEmailMessage mail = WorkflowAlertEmailBuilder.buildStallEmail(
        request
      );
      if (mail != null) {
        scan.emails.add(mail);
      }
    }

    // Build event if enabled
    if (config.Publish_Alert_Event__c) {
      WorkflowAlertManager.AlertEventRequest eventRequest = new WorkflowAlertManager.AlertEventRequest();
      eventRequest.instance = inst;
      eventRequest.config = config;
      eventRequest.errorMsg = message;
      eventRequest.alertReason = 'stall';
      scan.events.add(WorkflowAlertManager.buildAlertEvent(eventRequest));
    }

    // Build log marker
    scan.logs.add(
      new Workflow_Log__c(
        Workflow_Instance__c = inst.Id,
        Workflow_Name__c = inst.Workflow_Name__c,
        Correlation_Key__c = inst.Correlation_Key__c,
        Log_Type__c = 'WorkflowStallAlert',
        Level__c = 'Warn',
        Message__c = message
      )
    );
  }

  /**
   * @description Sends gathered stall emails, publishes events and inserts the log markers.
   * @param scan The scan accumulator holding the gathered alert artefacts.
   */
  private static void dispatchStallAlerts(StallScan scan) {
    if (!scan.emails.isEmpty()) {
      try {
        if (!Test.isRunningTest()) {
          Messaging.sendEmail(scan.emails, false);
        }
      } catch (Exception ex) {
        WorkflowLog.error(
          'StallAlert',
          'Bulk stall email dispatch failed: ' + ex.getMessage()
        );
      }
      WorkflowAlertManager.sentEmailsCount += scan.emails.size();
    }

    // Publish all gathered event alerts in bulk
    WorkflowAlertManager.publishEvents(scan.events);

    if (!scan.logs.isEmpty()) {
      insert as system scan.logs;
    }
  }
}
