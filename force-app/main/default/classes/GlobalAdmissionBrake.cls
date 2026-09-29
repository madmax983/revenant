/**
 * @description Reads the global admission brake (issue #136) and marks new
 * top-level starts.
 *
 * Cost per transaction (the engine keeps the decision for the transaction):
 * - No control set: 0 SOQL. The config is custom metadata.
 * - Emergency stop on: 0 SOQL.
 * - Auto-brake on: +1 SOQL, the #129 AsyncApexJob read (max 2,001 rows).
 * - Ceiling set: +1 SOQL, the global counter row (no lock). A start below the
 *   ceiling also reads the oldest parked starts (+1 SOQL, indexed, max 10
 *   rows). If they exist, it sends them to the gate (RUN_STEP events). It
 *   parks when they fill the free slots.
 *
 * A read that fails does not brake (fail open). No method here throws.
 */
public inherited sharing class GlobalAdmissionBrake {
  // Test hooks.
  @TestVisible
  private static Revenant_Config__mdt configOverride;
  @TestVisible
  private static String capacityStatusOverride;
  @TestVisible
  private static Boolean failCapacityRead = false;
  @TestVisible
  private static Boolean failCounterRead = false;

  private class BrakeReadException extends Exception {
  }

  // Per-transaction decision. Null = not read yet.
  private static GlobalAdmissionPolicy.Decision cached;
  // Per-transaction oldest parked starts. Null = not read yet.
  private static List<Id> cachedBacklog;
  // True after this transaction woke the backlog one time.
  private static Boolean backlogWoken = false;
  // Starts that this transaction marked Awaiting under a ceiling. They take
  // free slots too, so the next start in a bulk start parks sooner.
  private static Integer awaitingMarked = 0;

  /**
   * @description Gives the brake decision. Cached for the transaction. With
   * the emergency stop on, it reads nothing more.
   * @return The decision.
   */
  public static GlobalAdmissionPolicy.Decision evaluate() {
    if (cached == null) {
      cached = read(false);
    }
    return cached;
  }

  /**
   * @description Gives the brake decision with all values read, for System
   * Doctor. Not cached.
   * @return The decision.
   */
  public static GlobalAdmissionPolicy.Decision evaluateAll() {
    return read(true);
  }

  /**
   * @description Tells if a control is set. Reads the config only (0 SOQL).
   * @return True when the brake governs admission.
   */
  public static Boolean isGoverned() {
    return GlobalAdmissionPolicy.isGoverned(configInputs());
  }

  /**
   * @description Gives the configured global ceiling. Reads the config only.
   * @return The positive ceiling, or null.
   */
  public static Integer configuredCeiling() {
    return configInputs().ceiling;
  }

  /**
   * @description Tells if the emergency stop is on. Reads the config only.
   * @return True when the emergency stop is on.
   */
  public static Boolean emergencyStopConfigured() {
    return configInputs().emergencyStop == true;
  }

  /**
   * @description Clears the cached decision. The next call reads again.
   */
  @TestVisible
  private static void resetCache() {
    cached = null;
    cachedBacklog = null;
    backlogWoken = false;
    awaitingMarked = 0;
  }

  /**
   * @description Gives the marker for a new top-level start. Engine workflows
   * get null.
   * @param workflowName The workflow name.
   * @param paused True when the definition pause parks the start.
   * @return The Global_Admission__c value, or null.
   */
  public static String stateForStart(String workflowName, Boolean paused) {
    if (WorkflowPauseGate.isEngineWorkflow(workflowName)) {
      return null;
    }
    try {
      GlobalAdmissionPolicy.Decision d = evaluate();
      Boolean backlog = false;
      if (
        d.governed &&
        !d.braked &&
        paused != true &&
        d.inputs.ceiling != null
      ) {
        // Park when older parked starts and the starts of this transaction
        // fill the free slots. A full read (MAX_WAKES rows) counts as full.
        // Else the start takes a free slot, and the wake admits the backlog.
        Integer queued = parkedBacklog(d).size();
        backlog =
          queued >= ConcurrencyAdmissionOrder.MAX_WAKES ||
          queued + awaitingMarked >= freeSlots(d);
      }
      String state = GlobalAdmissionPolicy.startState(d, paused, backlog);
      if (
        state == GlobalAdmissionPolicy.STATE_AWAITING &&
        paused != true &&
        d.inputs.ceiling != null
      ) {
        awaitingMarked++;
      }
      return state;
    } catch (Exception ex) {
      return null;
    }
  }

  // The oldest starts that the brake parked and that can run now (not held,
  // not paused), max the free slots and max the wake batch. A new start parks
  // behind them, so it cannot take the slot of an older start. A read that
  // fails gives an empty list (fail open).
  private static List<Id> parkedBacklog(GlobalAdmissionPolicy.Decision d) {
    if (cachedBacklog != null) {
      return cachedBacklog;
    }
    cachedBacklog = new List<Id>();
    try {
      Integer rowLimit = Math.min(
        freeSlots(d),
        ConcurrencyAdmissionOrder.MAX_WAKES
      );
      if (rowLimit <= 0 || WorkflowPauseGate.wildcardPaused()) {
        return cachedBacklog;
      }
      Set<String> pausedNames = WorkflowPauseGate.pausedNames();
      for (Workflow_Instance__c row : [
        SELECT Id
        FROM Workflow_Instance__c
        WHERE
          Global_Admission__c = :GlobalAdmissionPolicy.STATE_PARKED
          AND Status__c = 'Suspended'
          AND Held_At__c = NULL
          AND Workflow_Name__c NOT IN :pausedNames
        WITH SYSTEM_MODE
        ORDER BY CreatedDate ASC, Id ASC
        LIMIT :rowLimit
      ]) {
        cachedBacklog.add(row.Id);
      }
    } catch (Exception ex) {
      cachedBacklog = new List<Id>();
    }
    return cachedBacklog;
  }

  // Free global slots from the lock-free count. An unread count gives the
  // wake batch size (fail open).
  private static Integer freeSlots(GlobalAdmissionPolicy.Decision d) {
    if (d.inputs.inFlight == null) {
      return ConcurrencyAdmissionOrder.MAX_WAKES;
    }
    return Math.max(0, d.inputs.ceiling - d.inputs.inFlight);
  }

  // A start that finds a backlog sends the oldest parked starts to the gate,
  // one time for each transaction. It uses the normal RUN_STEP path (a
  // platform event), not a Queueable, so it does not use the Queueable of the
  // caller. The gate admits each start or parks it again. It never runs a step
  // before admission.
  private static void wakeBacklog() {
    if (backlogWoken || cachedBacklog == null || cachedBacklog.isEmpty()) {
      return;
    }
    backlogWoken = true;
    if (Test.isRunningTest() && WorkflowEngine.disableQueueableInTest) {
      return;
    }
    try {
      WorkflowOrchestratorEnqueue.enqueueOrchestrators(cachedBacklog);
    } catch (Exception ex) {
      // Best effort: a failed publish must not fail the start. The watchdog
      // sweep sends the backlog.
      return;
    }
  }

  /**
   * @description Sets the marker on a new start before the start saves it. A
   * parked start gets Suspended and a due sleep time. The watchdog sleep sweep
   * sends it to the gate after the brake opens. The method does not mark a
   * start that has a parent: the root already holds a slot.
   * @param instance The new instance, not saved yet with these fields.
   * @param paused True when the definition pause parks the start.
   * @return The marker, or null.
   */
  public static String stampAtStart(
    Workflow_Instance__c instance,
    Boolean paused
  ) {
    if (instance.Parent_Instance__c != null) {
      return null;
    }
    String state = stateForStart(instance.Workflow_Name__c, paused);
    if (state == null) {
      return null;
    }
    instance.Global_Admission__c = state;
    // Reuse the #91 awaiting-admission marker: it defers the first step
    // deadline and routes the watchdog sweep to the gate.
    instance.Concurrency_Parked__c = true;
    if (state == GlobalAdmissionPolicy.STATE_PARKED) {
      instance.Status__c = 'Suspended';
      instance.Sleep_Until__c = DateTime.now();
    }
    wakeBacklog();
    return state;
  }

  /**
   * @description Gives the number of parked starts that one sweep can send to
   * the gate. The number is not more than the free global slots, so a sweep
   * does not send starts that only park again.
   * @param maxRows The sweep batch size.
   * @return 0 when braked, the free slots (max maxRows) with a ceiling, else
   * maxRows. With no control set, maxRows (0 SOQL).
   */
  public static Integer parkedResumeBudget(Integer maxRows) {
    try {
      if (!isGoverned()) {
        return maxRows;
      }
      GlobalAdmissionPolicy.Decision d = evaluate();
      if (d.braked) {
        return 0;
      }
      if (d.inputs.ceiling == null || d.inputs.inFlight == null) {
        // No ceiling, or the count read failed (fail open): the gate decides.
        return maxRows;
      }
      return Math.max(
        0,
        Math.min(maxRows, d.inputs.ceiling - d.inputs.inFlight)
      );
    } catch (Exception ex) {
      // Fail open: the gate decides.
      return maxRows;
    }
  }

  private static GlobalAdmissionPolicy.Decision read(Boolean full) {
    GlobalAdmissionPolicy.Inputs i = configInputs();
    if (!GlobalAdmissionPolicy.isGoverned(i)) {
      return GlobalAdmissionPolicy.decide(i);
    }
    if (i.emergencyStop && !full) {
      return GlobalAdmissionPolicy.decide(i);
    }
    if (i.autoBrake) {
      i.capacityStatus = readCapacityStatus();
    }
    if (i.ceiling != null) {
      i.inFlight = readInFlight();
    }
    return GlobalAdmissionPolicy.decide(i);
  }

  // Custom metadata getInstance costs no SOQL.
  private static GlobalAdmissionPolicy.Inputs configInputs() {
    GlobalAdmissionPolicy.Inputs i = new GlobalAdmissionPolicy.Inputs();
    Revenant_Config__mdt config = configOverride != null
      ? configOverride
      : Revenant_Config__mdt.getInstance('Default');
    if (config == null) {
      return i;
    }
    i.emergencyStop = config.Emergency_Stop__c == true;
    i.autoBrake = config.Auto_Brake_On_Capacity__c == true;
    i.ceiling = GlobalAdmissionPolicy.normalizeCeiling(
      config.Global_Max_Active_Instances__c
    );
    return i;
  }

  // The #129 status. Null when the read fails (fail open).
  private static String readCapacityStatus() {
    try {
      if (failCapacityRead) {
        throw new BrakeReadException('Test: capacity read failed');
      }
      if (capacityStatusOverride != null) {
        return capacityStatusOverride;
      }
      return WorkflowAsyncCapacityService.currentStatus();
    } catch (Exception ex) {
      return null;
    }
  }

  // The global slot count, no lock. Null when the read fails (fail open).
  private static Integer readInFlight() {
    try {
      if (failCounterRead) {
        throw new BrakeReadException('Test: counter read failed');
      }
      return GlobalAdmissionGate.readInFlight();
    } catch (Exception ex) {
      return null;
    }
  }
}
