/**
 * @description Rules of the global admission brake (issue #136). Pure: no SOQL,
 * no DML. The brake parks new starts only. It never stops an in-flight
 * instance.
 *
 * Reason order: emergency stop, then capacity, then ceiling. A value that the
 * brake cannot read does not brake (fail open).
 */
public inherited sharing class GlobalAdmissionPolicy {
  /** @description A new start that must pass the global gate at its first hop. */
  public static final String STATE_AWAITING = 'Awaiting';
  /** @description A new start that the brake parked. */
  public static final String STATE_PARKED = 'Parked';
  /** @description An instance that holds one global slot. */
  public static final String STATE_HELD = 'Held';

  /** @description The operator emergency stop is on. */
  public static final String REASON_EMERGENCY_STOP = 'EMERGENCY_STOP';
  /** @description Auto-brake is on and the capacity status is Critical. */
  public static final String REASON_CAPACITY_CRITICAL = 'CAPACITY_CRITICAL';
  /** @description The global slot count is at the ceiling. */
  public static final String REASON_CEILING = 'CEILING';

  /** @description The values that the brake reads. Null means not read. */
  public class Inputs {
    /** @description Emergency stop config. */
    public Boolean emergencyStop = false;
    /** @description Auto-brake config. */
    public Boolean autoBrake = false;
    /** @description The #129 capacity status, or null. */
    public String capacityStatus;
    /** @description The ceiling (positive), or null for no ceiling. */
    public Integer ceiling;
    /** @description The global slot count, or null when not read. */
    public Integer inFlight;
  }

  /** @description The brake decision. */
  public class Decision {
    /** @description True when a control is set. False: admission is the same as before #136. */
    public Boolean governed = false;
    /** @description True when new starts park. */
    public Boolean braked = false;
    /** @description The first reason, or null when open. */
    public String reason;
    /** @description All reasons, in order. */
    public List<String> reasons = new List<String>();
    /** @description The values that gave this decision. */
    public Inputs inputs;
  }

  /**
   * @description Makes the brake decision.
   * @param i The values that the brake read.
   * @return The decision.
   */
  public static Decision decide(Inputs i) {
    Decision d = new Decision();
    d.inputs = i;
    d.governed = isGoverned(i);
    if (i.emergencyStop == true) {
      d.reasons.add(REASON_EMERGENCY_STOP);
    }
    if (
      i.autoBrake == true &&
      i.capacityStatus == AsyncCapacityEvaluator.STATUS_CRITICAL
    ) {
      d.reasons.add(REASON_CAPACITY_CRITICAL);
    }
    if (i.ceiling != null && i.inFlight != null && i.inFlight >= i.ceiling) {
      d.reasons.add(REASON_CEILING);
    }
    d.braked = !d.reasons.isEmpty();
    d.reason = d.braked ? d.reasons[0] : null;
    return d;
  }

  /**
   * @description Tells if a control is set.
   * @param i The config values.
   * @return True when the emergency stop, the auto-brake or a ceiling is set.
   */
  public static Boolean isGoverned(Inputs i) {
    return i.emergencyStop == true || i.autoBrake == true || i.ceiling != null;
  }

  /**
   * @description Gives the ceiling to use.
   * @param raw The config value.
   * @return The positive ceiling, or null. Blank, 0 or negative gives null.
   */
  public static Integer normalizeCeiling(Decimal raw) {
    if (raw == null || raw < 1) {
      return null;
    }
    return raw.intValue();
  }

  /**
   * @description Gives the marker for a new top-level start.
   * @param d The brake decision.
   * @param paused True when the definition pause parks the start.
   * @return The marker. See the three-argument overload.
   */
  public static String startState(Decision d, Boolean paused) {
    return startState(d, paused, false);
  }

  /**
   * @description Gives the marker for a new top-level start.
   * @param d The brake decision.
   * @param paused True when the definition pause parks the start.
   * @param parkedBacklog True when parked starts fill the free slots. With a
   * ceiling, a new start then parks behind them, so the oldest start goes
   * first.
   * @return Parked (braked, or a ceiling with a backlog, and not paused),
   * Awaiting (paused, or open with a ceiling), or null (not governed, or open
   * with no ceiling).
   */
  public static String startState(
    Decision d,
    Boolean paused,
    Boolean parkedBacklog
  ) {
    if (d == null || !d.governed) {
      return null;
    }
    if (paused == true) {
      return STATE_AWAITING;
    }
    if (d.braked) {
      return STATE_PARKED;
    }
    if (d.inputs.ceiling != null) {
      return parkedBacklog == true ? STATE_PARKED : STATE_AWAITING;
    }
    return null;
  }

  /**
   * @description Tells if a state waits for the global gate.
   * @param state The Global_Admission__c value.
   * @return True for Awaiting and Parked.
   */
  public static Boolean isAwaiting(String state) {
    return state == STATE_AWAITING || state == STATE_PARKED;
  }
}
