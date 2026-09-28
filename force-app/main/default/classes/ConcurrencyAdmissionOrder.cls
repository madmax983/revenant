/**
 * @description Admission order for the concurrency ceiling (issue #132).
 *
 * Each instance gets a priority (0–9) and a rank key at insert:
 * `key = startMs − priority × agingMinutes × 60000`. The gate admits the
 * lowest key first, then the lowest Id. In one priority class this is FIFO.
 * A higher class gets a time credit of one aging window per level, so an
 * instance is never passed by work that starts more than
 * `(priorityGap × agingMinutes)` after it. This is the starvation bound.
 *
 * Priority controls admission order only. It does not touch step rows, the
 * compensation stack or the Queueable chain. All SOQL runs in system mode.
 */
public inherited sharing class ConcurrencyAdmissionOrder {
  /** @description Lowest priority. */
  public static final Integer MIN_PRIORITY = 0;
  /** @description Highest priority. */
  public static final Integer MAX_PRIORITY = 9;
  /** @description Aging window (minutes per level) when config has none. */
  public static final Integer DEFAULT_AGING_MINUTES = 60;
  /** @description Statuses of an instance that waits for a slot. */
  public static final Set<String> WAITING_STATUSES = new Set<String>{
    'Pending',
    'Running',
    'Suspended'
  };

  // Maximum rows one gate visit wakes. Keeps the wake cost bounded.
  private static final Integer MAX_WAKES = 5;
  private static final Long MS_PER_MINUTE = 60000L;

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
      return clamp(requested);
    }
    Concurrency_Config__mdt config = ConcurrencyGate.getConfig(workflowName);
    if (config == null || config.Admission_Priority__c == null) {
      return MIN_PRIORITY;
    }
    return clamp(config.Admission_Priority__c.intValue());
  }

  /**
   * @description Returns the aging window for a workflow. A blank or
   * non-positive config value gives DEFAULT_AGING_MINUTES.
   * @param workflowName The workflow definition name.
   * @return The aging window in minutes (at least 1).
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
    return config.Priority_Aging_Minutes__c.intValue();
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
   * @description Before-insert stamp. Sets the priority (clamped) and the rank
   * key on each row. Keeps a key that is already set. Costs no SOQL.
   * @param rows The new Workflow_Instance__c rows.
   */
  public static void stampOnInsert(List<Workflow_Instance__c> rows) {
    Datetime now = WorkflowEngine.mockNow != null
      ? WorkflowEngine.mockNow
      : System.now();
    for (Workflow_Instance__c row : rows) {
      stamp(row, now);
    }
  }

  /**
   * @description Sets the priority and key on a row from before this feature,
   * from its CreatedDate. The gate calls it on the first visit.
   * @param row The instance, with Workflow_Name__c, CreatedDate and both
   * admission fields queried.
   * @return True when the row changed.
   */
  public static Boolean backfill(Workflow_Instance__c row) {
    if (row.Admission_Key__c != null) {
      return false;
    }
    stamp(row, row.CreatedDate);
    return true;
  }

  /**
   * @description Returns up to `maxRows` waiting instances of the workflow that
   * rank ahead of the candidate, in admission order. A row with a blank key
   * (from before this feature) ranks first.
   * @param workflowName The workflow definition name.
   * @param candidate The instance that asks for a slot (Id, Admission_Key__c).
   * @param maxRows The number of free slots.
   * @return The Ids of the rows ahead, best first.
   */
  public static List<Id> findAhead(
    String workflowName,
    Workflow_Instance__c candidate,
    Integer maxRows
  ) {
    Id candidateId = candidate.Id;
    Decimal key = candidate.Admission_Key__c;
    List<Workflow_Instance__c> rows = (key == null)
      ? queryAheadOfBlankKey(workflowName, candidateId, maxRows)
      : queryAheadOfKey(workflowName, candidateId, key, maxRows);
    List<Id> aheadIds = new List<Id>();
    for (Workflow_Instance__c row : rows) {
      aheadIds.add(row.Id);
    }
    return aheadIds;
  }

  /**
   * @description Wakes up to MAX_WAKES waiting instances through the existing
   * resume path, so the head of the queue visits the gate now.
   * @param instanceIds The instances to wake, best first.
   */
  public static void wake(List<Id> instanceIds) {
    Integer count = 0;
    for (Id instanceId : instanceIds) {
      if (count >= MAX_WAKES) {
        return;
      }
      try {
        WorkflowResumeEnqueue.enqueueResume(instanceId);
      } catch (Exception ignored) {
        // Best effort. The row still has its retry timer and the watchdog.
        // A failed wake must not roll back the park or the admission.
        WorkflowResumeEnqueue.clearEnqueueGuards(new Set<Id>{ instanceId });
      }
      count++;
    }
  }

  // Sets the clamped priority and, when blank, the key.
  private static void stamp(Workflow_Instance__c row, Datetime startedAt) {
    Integer requested = (row.Admission_Priority__c == null)
      ? null
      : row.Admission_Priority__c.intValue();
    Integer priority = resolvePriority(row.Workflow_Name__c, requested);
    row.Admission_Priority__c = priority;
    if (row.Admission_Key__c == null) {
      row.Admission_Key__c = admissionKey(
        startedAt,
        priority,
        resolveAgingMinutes(row.Workflow_Name__c)
      );
    }
  }

  private static Integer clamp(Integer priority) {
    return Math.max(MIN_PRIORITY, Math.min(MAX_PRIORITY, priority));
  }

  // Rows ahead of a keyed candidate: blank key, lower key, or same key and
  // lower Id.
  private static List<Workflow_Instance__c> queryAheadOfKey(
    String workflowName,
    Id candidateId,
    Decimal key,
    Integer maxRows
  ) {
    return [
      SELECT Id
      FROM Workflow_Instance__c
      WHERE
        Workflow_Name__c = :workflowName
        AND Concurrency_Parked__c = TRUE
        AND Concurrency_Slot_Held__c = FALSE
        AND Status__c IN :WAITING_STATUSES
        AND Id != :candidateId
        AND (Admission_Key__c = NULL
        OR Admission_Key__c < :key
        OR (Admission_Key__c = :key
        AND Id < :candidateId))
      WITH SYSTEM_MODE
      ORDER BY Admission_Key__c ASC NULLS FIRST, Id ASC
      LIMIT :maxRows
    ];
  }

  // Rows ahead of a blank-key candidate: other blank-key rows with a lower Id.
  private static List<Workflow_Instance__c> queryAheadOfBlankKey(
    String workflowName,
    Id candidateId,
    Integer maxRows
  ) {
    return [
      SELECT Id
      FROM Workflow_Instance__c
      WHERE
        Workflow_Name__c = :workflowName
        AND Concurrency_Parked__c = TRUE
        AND Concurrency_Slot_Held__c = FALSE
        AND Status__c IN :WAITING_STATUSES
        AND Admission_Key__c = NULL
        AND Id < :candidateId
      WITH SYSTEM_MODE
      ORDER BY Id ASC
      LIMIT :maxRows
    ];
  }
}
