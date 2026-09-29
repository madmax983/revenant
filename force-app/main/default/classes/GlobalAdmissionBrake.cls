/**
 * @description Reads the global admission brake (issue #136) and marks new
 * top-level starts.
 *
 * Cost per transaction (the decision is cached):
 * - No control set: 0 SOQL. The config is custom metadata.
 * - Emergency stop on: 0 SOQL.
 * - Auto-brake on: +1 SOQL, the #129 AsyncApexJob read (max 2,001 rows).
 * - Ceiling set: +1 SOQL, the global counter row (no lock).
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
      return GlobalAdmissionPolicy.startState(evaluate(), paused);
    } catch (Exception ex) {
      return null;
    }
  }

  /**
   * @description Sets the marker on a new start before the start saves it. A
   * parked start gets Suspended and a due sleep time, so the watchdog sleep
   * sweep re-drives it after the brake opens. A start under a parent is not
   * marked: it is part of a running root.
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
    return state;
  }

  /**
   * @description Gives the markers that the main watchdog sleep query must not
   * select. When a control is set, parked starts go through
   * `parkedResumeBudget` instead, so they do not fill the main batch.
   * @return {Parked} when a control is set, else an empty set. 0 SOQL.
   */
  public static Set<String> sweepExclusions() {
    return isGoverned()
      ? new Set<String>{ GlobalAdmissionPolicy.STATE_PARKED }
      : new Set<String>();
  }

  /**
   * @description Gives the number of parked starts that one sweep can send to
   * the gate. The number is not more than the free global slots, so a sweep
   * does not send starts that only park again.
   * @param maxRows The sweep batch size.
   * @return 0 when braked or not governed (the main query then takes them),
   * the free slots (max maxRows) with a ceiling, else maxRows.
   */
  public static Integer parkedResumeBudget(Integer maxRows) {
    try {
      if (!isGoverned()) {
        return 0;
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
