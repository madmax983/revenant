/**
 * @description Admission order for the concurrency ceiling (issue #132).
 *
 * Each instance gets a priority (0–9) and a rank key at insert:
 * `key = startMs − priority × agingMinutes × 60000`. The gate admits the
 * lowest key first, then the lowest Id. In one priority class, this is first
 * in, first out (FIFO). Each priority level moves the key back by one aging
 * window. Work that starts more than `(priorityGap × agingMinutes)` after an
 * instance cannot go before it. This is the starvation bound.
 *
 * An instance "waits" when it is parked, holds no slot, and has a status in
 * WAITING_STATUSES. The trigger then sets the indexed `Admission_Queue__c`.
 * A row from before this feature has no key. It ranks first, in Id order.
 *
 * Priority sets admission order only. It does not change step rows, the
 * compensation stack or the Queueable chain. All SOQL runs in system mode.
 */
public inherited sharing class ConcurrencyAdmissionOrder {
  /** @description Lowest priority. */
  public static final Integer MIN_PRIORITY = 0;
  /** @description Highest priority. */
  public static final Integer MAX_PRIORITY = 9;
  /** @description Aging window (minutes per level) when config has none. */
  public static final Integer DEFAULT_AGING_MINUTES = 60;
  /** @description Largest aging window (one year). Stops an overflow. */
  public static final Integer MAX_AGING_MINUTES = 525600;
  /** @description Statuses of an instance that waits for a slot. */
  public static final Set<String> WAITING_STATUSES = new Set<String>{
    'Pending',
    'Running',
    'Suspended'
  };
  /** @description The maximum number of rows that one gate visit wakes. */
  public static final Integer MAX_WAKES = 10;

  private static final Long MS_PER_MINUTE = 60000L;

  // Test seam: skips the queue sync, so a test can make a row from before
  // this feature (a waiting row with a blank queue field).
  @TestVisible
  private static Boolean skipQueueSync = false;

  /**
   * @description Returns the priority for a new instance: the clamped
   * override, else the clamped config value, else MIN_PRIORITY.
   * @param workflowName The workflow definition name.
   * @param requested The per-start override, or null.
   * @return A priority in [MIN_PRIORITY, MAX_PRIORITY].
   */
  public static Integer resolvePriority(
    String workflowName,
    Integer requested
  ) {
    if (requested != null) {
      return clamp(requested, MIN_PRIORITY, MAX_PRIORITY);
    }
    Concurrency_Config__mdt config = ConcurrencyGate.getConfig(workflowName);
    if (config == null || config.Admission_Priority__c == null) {
      return MIN_PRIORITY;
    }
    return clamp(
      clampToInteger(config.Admission_Priority__c),
      MIN_PRIORITY,
      MAX_PRIORITY
    );
  }

  /**
   * @description Returns the aging window for a workflow. A blank or
   * non-positive config value gives DEFAULT_AGING_MINUTES. A value above
   * MAX_AGING_MINUTES gives MAX_AGING_MINUTES.
   * @param workflowName The workflow definition name.
   * @return The aging window in minutes, from 1 to MAX_AGING_MINUTES.
   */
  public static Integer resolveAgingMinutes(String workflowName) {
    Concurrency_Config__mdt config = ConcurrencyGate.getConfig(workflowName);
    if (
      config == null ||
      config.Priority_Aging_Minutes__c == null ||
      config.Priority_Aging_Minutes__c < 1
    ) {
      return DEFAULT_AGING_MINUTES;
    }
    return clamp(
      clampToInteger(config.Priority_Aging_Minutes__c),
      1,
      MAX_AGING_MINUTES
    );
  }

  /**
   * @description Calculates the rank key. A lower key is admitted first.
   * @param startedAt The start time of the instance.
   * @param priority The instance priority.
   * @param agingMinutes The aging window in minutes.
   * @return `startMs − priority × agingMinutes × 60000`.
   */
  public static Long admissionKey(
    Datetime startedAt,
    Integer priority,
    Integer agingMinutes
  ) {
    return startedAt.getTime() - (Long) priority * agingMinutes * MS_PER_MINUTE;
  }

  /**
   * @description Before-insert stamp. Sets the clamped priority on each row.
   * Sets the rank key when it is blank. Costs no SOQL.
   * @param rows The new Workflow_Instance__c rows.
   */
  public static void stampOnInsert(List<Workflow_Instance__c> rows) {
    Datetime now = WorkflowEngine.mockNow != null
      ? WorkflowEngine.mockNow
      : System.now();
    for (Workflow_Instance__c row : rows) {
      Integer requested = (row.Admission_Priority__c == null)
        ? null
        : clampToInteger(row.Admission_Priority__c);
      Integer priority = resolvePriority(row.Workflow_Name__c, requested);
      row.Admission_Priority__c = priority;
      if (row.Admission_Key__c == null) {
        row.Admission_Key__c = admissionKey(
          now,
          priority,
          resolveAgingMinutes(row.Workflow_Name__c)
        );
      }
    }
  }

  /**
   * @description Before-save sync of the indexed queue field. Sets
   * `Admission_Queue__c` to the workflow name while the row waits. Else it
   * clears the field. Call it after the slot release changes the flags.
   * @param row The Workflow_Instance__c row that is saved.
   */
  public static void syncQueueField(Workflow_Instance__c row) {
    if (skipQueueSync) {
      return;
    }
    row.Admission_Queue__c = isWaiting(row) ? row.Workflow_Name__c : null;
  }

  /**
   * @description Sets `Admission_Queue__c` on waiting rows from before this
   * feature. Until then the gate does not see them. The watchdog heartbeat
   * calls it. An admin can also run it once after deploy.
   * @param maxRows The maximum number of rows to fix in one call.
   * @return The number of rows fixed.
   */
  public static Integer backfillQueue(Integer maxRows) {
    List<Workflow_Instance__c> rows = [
      SELECT Id, Workflow_Name__c
      FROM Workflow_Instance__c
      WHERE
        Admission_Queue__c = NULL
        AND Concurrency_Parked__c = TRUE
        AND Concurrency_Slot_Held__c = FALSE
        AND Status__c IN :WAITING_STATUSES
      WITH SYSTEM_MODE
      ORDER BY Id ASC
      LIMIT :maxRows
    ];
    for (Workflow_Instance__c row : rows) {
      row.Admission_Queue__c = row.Workflow_Name__c;
    }
    if (!rows.isEmpty()) {
      Database.update(rows, true, AccessLevel.SYSTEM_MODE);
    }
    return rows.size();
  }

  /**
   * @description True when the row waits for a concurrency slot.
   * @param row The instance, with the flags and Status__c set.
   * @return True when the row is parked, holds no slot and has a waiting status.
   */
  public static Boolean isWaiting(Workflow_Instance__c row) {
    return row.Concurrency_Parked__c == true &&
      row.Concurrency_Slot_Held__c != true &&
      WAITING_STATUSES.contains(row.Status__c);
  }

  /**
   * @description Returns up to `freeSlots` waiting instances that rank ahead of
   * the candidate, best first. A row with a blank key ranks first.
   * @param candidate The instance that asks for a slot (Id, Workflow_Name__c,
   * Admission_Key__c).
   * @param freeSlots The number of free slots.
   * @return The Ids of the rows ahead, best first.
   */
  public static List<Id> findAhead(
    Workflow_Instance__c candidate,
    Integer freeSlots
  ) {
    List<Workflow_Instance__c> rows = (candidate.Admission_Key__c == null)
      ? queryAheadOfBlankKey(candidate, freeSlots)
      : queryAheadOfKey(candidate, freeSlots);
    List<Id> aheadIds = new List<Id>();
    for (Workflow_Instance__c row : rows) {
      aheadIds.add(row.Id);
    }
    return aheadIds;
  }

  /**
   * @description Wakes up to MAX_WAKES waiting instances with one admit-only
   * Queueable (`ConcurrencyAdmissionWake`). The job admits or re-parks each
   * row. It never runs a step. When the Queueable budget is spent, the rows
   * keep their retry timers and the watchdog.
   * @param instanceIds The instances to wake, best first.
   */
  public static void wake(List<Id> instanceIds) {
    if (instanceIds == null || instanceIds.isEmpty()) {
      return;
    }
    if (Test.isRunningTest() && WorkflowEngine.disableQueueableInTest) {
      return;
    }
    if (Limits.getQueueableJobs() >= Limits.getLimitQueueableJobs()) {
      return;
    }
    List<Id> batch = new List<Id>();
    for (Id instanceId : instanceIds) {
      if (batch.size() >= MAX_WAKES) {
        break;
      }
      batch.add(instanceId);
    }
    try {
      System.enqueueJob(new ConcurrencyAdmissionWake(batch));
    } catch (Exception ignored) {
      // Best effort. A failed wake must not roll back the park or admission.
      return;
    }
  }

  private static Integer clamp(Integer value, Integer low, Integer high) {
    return Math.max(low, Math.min(high, value));
  }

  // Decimal to Integer with no overflow: values outside the Integer range
  // become the nearest Integer limit.
  private static Integer clampToInteger(Decimal value) {
    if (value > 2147483647) {
      return 2147483647;
    }
    if (value < -2147483648L) {
      return -2147483647 - 1;
    }
    return value.intValue();
  }

  // Rows ahead of a keyed candidate: blank key, lower key, or same key and
  // lower Id.
  private static List<Workflow_Instance__c> queryAheadOfKey(
    Workflow_Instance__c candidate,
    Integer freeSlots
  ) {
    String queue = candidate.Workflow_Name__c;
    Id candidateId = candidate.Id;
    Decimal key = candidate.Admission_Key__c;
    return [
      SELECT Id
      FROM Workflow_Instance__c
      WHERE
        Admission_Queue__c = :queue
        AND Id != :candidateId
        AND (Admission_Key__c = NULL
        OR Admission_Key__c < :key
        OR (Admission_Key__c = :key
        AND Id < :candidateId))
      WITH SYSTEM_MODE
      ORDER BY Admission_Key__c ASC NULLS FIRST, Id ASC
      LIMIT :freeSlots
    ];
  }

  // Rows ahead of a blank-key candidate: other blank-key rows with a lower Id.
  private static List<Workflow_Instance__c> queryAheadOfBlankKey(
    Workflow_Instance__c candidate,
    Integer freeSlots
  ) {
    String queue = candidate.Workflow_Name__c;
    Id candidateId = candidate.Id;
    return [
      SELECT Id
      FROM Workflow_Instance__c
      WHERE
        Admission_Queue__c = :queue
        AND Admission_Key__c = NULL
        AND Id < :candidateId
      WITH SYSTEM_MODE
      ORDER BY Id ASC
      LIMIT :freeSlots
    ];
  }
}
