/**
 * @description Deletes operator-selected terminal instances and all their
 * satellites with zero orphans (issue #142). See `docs/instance-purge.md`.
 *
 * ```apex
 * WorkflowInstancePurge.PurgeResult r = WorkflowInstancePurge.purge(ids);
 * WorkflowInstancePurge.PurgeResult f = WorkflowInstancePurge.purge(ids, true);
 * ```
 *
 * Rules for each instance X in the purge set S:
 * 1. X is terminal ({@link WorkflowInstanceTeardown#isPurgeable}).
 * 2. Each child of X is in S.
 * 3. The predecessor of X (`Previous_Instance__c`) is in S.
 * 4. A successor of X that is not in S has a final status.
 * 5. The parent of X, when not in S, has a final status.
 *
 * A final status is terminal and not `Failed`. An operator can retry a
 * `Failed` instance. Rules 2 and 3 stop a dangling child or chain. The purge
 * accepts removal of the oldest generations of a chain. Rules 4 and 5 stop
 * the delete of X while a run or rollback can still read X.
 *
 * `includeRelated` adds the full family of each Id first: all generations in
 * both directions, all children and their families. It never adds a parent.
 *
 * Linked instances in S form a group. The call purges a group as one unit.
 * It purges the groups that obey the rules and reports each other Id. For an
 * expected state, the call returns an outcome. Bad input throws
 * `WorkflowEngine.WorkflowException`.
 *
 * All SOQL and DML run in system mode. The caller must check permissions.
 * A message can name related instances that the caller cannot see.
 */
public inherited sharing class WorkflowInstancePurge {
  /**
   * @description The maximum number of Ids for one call. One call also
   * deletes no more than this number of instances.
   */
  public static final Integer MAX_INSTANCES_PER_CALL = 50;
  /** @description The maximum link levels that `includeRelated` follows. */
  public static final Integer MAX_LINK_ROUNDS = 20;
  /**
   * @description The maximum rows for each related read. The family read and
   * the link check each have this limit.
   */
  public static final Integer MAX_RELATED_ROWS = 2000;

  private static final Integer MAX_NAMED_IDS = 5;
  private static final String STATUS_FAILED = 'Failed';

  // Tests lower the bounds to exercise the limit paths with few rows.
  @TestVisible
  private static Integer maxLinkRounds = MAX_LINK_ROUNDS;
  @TestVisible
  private static Integer maxRelatedRows = MAX_RELATED_ROWS;

  /**
   * @description The result for one Id.
   */
  public enum Outcome {
    /** Deleted with all its satellites. */
    PURGED,
    /** No workflow instance has this Id. */
    NOT_FOUND,
    /** The status is not terminal. */
    REJECTED_NOT_TERMINAL,
    /** The purge would remove the link of a child or chain generation. */
    REJECTED_RELATED,
    /** A related instance can still run and read this one. */
    REJECTED_RELATED_ACTIVE,
    /** The related group is larger than the bounds of one call. */
    REJECTED_TOO_LARGE,
    /** This call cannot purge the Id now. Call again for this Id. */
    DEFERRED
  }

  /**
   * @description The outcome for one instance.
   */
  public class InstanceResult {
    /** @description The instance Id. */
    public Id instanceId { get; private set; }
    /** @description The outcome. */
    public Outcome outcome { get; private set; }
    /** @description What happened and what to do next. */
    public String message { get; private set; }
    /** @description False for a related Id that `includeRelated` added. */
    public Boolean requested { get; private set; }

    private InstanceResult(
      Id instanceId,
      Outcome outcome,
      String message,
      Boolean requested
    ) {
      this.instanceId = instanceId;
      this.outcome = outcome;
      this.message = message;
      this.requested = requested;
    }
  }

  /**
   * @description The result of one call.
   */
  public class PurgeResult {
    /**
     * @description One row for each requested Id (sorted), then one row for
     * each related Id that the call purged.
     */
    public List<InstanceResult> results { get; private set; }
    /** @description Deleted instances, related ones included. */
    public Integer purgedCount { get; private set; }
    /** @description Deleted signals. */
    public Integer deletedSignalCount { get; private set; }
    /** @description Deleted instance logs. */
    public Integer deletedLogCount { get; private set; }
    /** @description Deleted engine files. */
    public Integer deletedFileCount { get; private set; }

    private Map<Id, InstanceResult> byId = new Map<Id, InstanceResult>();

    private PurgeResult() {
      this.results = new List<InstanceResult>();
      this.purgedCount = 0;
      this.deletedSignalCount = 0;
      this.deletedLogCount = 0;
      this.deletedFileCount = 0;
    }

    /**
     * @description Returns the row for an Id.
     * @param instanceId the Id
     * @return the row, or null when the call did not report the Id
     */
    public InstanceResult get(Id instanceId) {
      return byId.get(instanceId);
    }

    /**
     * @description Returns the outcome for an Id.
     * @param instanceId the Id
     * @return the outcome, or null when the call did not report the Id
     */
    public Outcome outcomeOf(Id instanceId) {
      InstanceResult r = byId.get(instanceId);
      return r == null ? null : r.outcome;
    }

    private void add(InstanceResult r) {
      results.add(r);
      byId.put(r.instanceId, r);
    }
  }

  /**
   * @description Purges one instance. Same as `purge(new Set<Id>{ id })`.
   * @param instanceId the instance Id
   * @return the result
   * @throws WorkflowEngine.WorkflowException when the Id is null
   */
  public static PurgeResult purge(Id instanceId) {
    if (instanceId == null) {
      throw new WorkflowEngine.WorkflowException(
        'instanceId must not be null.'
      );
    }
    return purge(new Set<Id>{ instanceId }, false);
  }

  /**
   * @description Purges the selected instances. Related instances are not
   * added.
   * @param instanceIds the instance Ids, at most
   * {@link #MAX_INSTANCES_PER_CALL}
   * @return the result
   * @throws WorkflowEngine.WorkflowException for bad input
   */
  public static PurgeResult purge(Set<Id> instanceIds) {
    return purge(instanceIds, false);
  }

  /**
   * @description Purges the selected instances.
   * @param instanceIds the instance Ids, at most
   * {@link #MAX_INSTANCES_PER_CALL}
   * @param includeRelated true to add the full family of each Id
   * @return the result
   * @throws WorkflowEngine.WorkflowException for bad input
   */
  public static PurgeResult purge(Set<Id> instanceIds, Boolean includeRelated) {
    validate(instanceIds);
    return new Planner(instanceIds, includeRelated == true).run();
  }

  private static void validate(Set<Id> instanceIds) {
    if (instanceIds == null || instanceIds.contains(null)) {
      throw new WorkflowEngine.WorkflowException(
        'instanceIds must not be null or contain null.'
      );
    }
    if (instanceIds.size() > MAX_INSTANCES_PER_CALL) {
      throw new WorkflowEngine.WorkflowException(
        'A purge takes at most ' +
          MAX_INSTANCES_PER_CALL +
          ' Ids. Split the Ids into more calls.'
      );
    }
  }

  // Thrown when a lock wait fails. No DML has run yet.
  private class LockException extends Exception {
  }

  // One call: read and lock, group, bound, check the rules, then delete.
  private class Planner {
    private final List<Id> requested = new List<Id>();
    private final Set<Id> requestedSet;
    private final Boolean includeRelated;
    private final PurgeResult result = new PurgeResult();
    // Rows of the purge set S.
    private Map<Id, Workflow_Instance__c> rows = new Map<Id, Workflow_Instance__c>();
    // Rows in S whose links the family read did not follow in full.
    private final Set<Id> unexpanded = new Set<Id>();
    private Integer relatedRowsRead = 0;
    // Groups that obey every rule, in order.
    private final List<List<Id>> accepted = new List<List<Id>>();

    Planner(Set<Id> instanceIds, Boolean includeRelated) {
      this.requestedSet = instanceIds;
      this.includeRelated = includeRelated;
      this.requested.addAll(sortedIds(instanceIds));
    }

    PurgeResult run() {
      try {
        plan();
      } catch (LockException e) {
        // Nothing is deleted. The rest waits for a new call.
        reportWrongType();
        reportUnreported(Outcome.DEFERRED, lockedMessage());
        return finish();
      }
      if (accepted.isEmpty()) {
        return finish();
      }
      Savepoint sp = Database.setSavepoint();
      try {
        deleteAccepted();
      } catch (DmlException e) {
        if (e.getDmlType(0) != StatusCode.UNABLE_TO_LOCK_ROW) {
          throw e;
        }
        // Another transaction locks a satellite. Undo all deletes.
        Database.rollback(sp);
        resetCounts();
        for (List<Id> grp : accepted) {
          reportGroup(grp, Outcome.DEFERRED, lockedMessage());
        }
      }
      return finish();
    }

    private void plan() {
      Set<Id> instanceIds = new Set<Id>();
      for (Id i : requested) {
        if (i.getSObjectType() == Workflow_Instance__c.SObjectType) {
          instanceIds.add(i);
        }
      }
      rows = lockRows(instanceIds);
      Set<Id> locked = new Set<Id>(rows.keySet());
      if (includeRelated) {
        expandFamilies();
      }

      // Bound first, so the call locks only rows that it can delete. A group
      // with a non-terminal member fails rule 1 now. It takes no budget.
      List<List<Id>> fitting = new List<List<Id>>();
      Integer used = 0;
      Violations early = new Violations();
      for (Workflow_Instance__c row : rows.values()) {
        if (!isTerminal(row)) {
          early.notTerminal.add(row.Id);
        }
      }
      for (List<Id> grp : groupsOf(rows.keySet())) {
        if (rejectIfViolated(grp, early)) {
          continue;
        } else if (isTooLarge(grp)) {
          reportGroup(grp, Outcome.REJECTED_TOO_LARGE, tooLargeMessage());
        } else if (used + grp.size() > MAX_INSTANCES_PER_CALL) {
          reportGroup(grp, Outcome.DEFERRED, deferredMessage());
        } else {
          fitting.add(grp);
          used += grp.size();
        }
      }

      // Lock the added related rows, then check links on fresh data.
      Map<Id, Workflow_Instance__c> fresh = new Map<Id, Workflow_Instance__c>();
      Set<Id> toLock = new Set<Id>();
      for (List<Id> grp : fitting) {
        for (Id i : grp) {
          if (locked.contains(i)) {
            fresh.put(i, rows.get(i));
          } else {
            toLock.add(i);
          }
        }
      }
      fresh.putAll(lockRows(toLock));
      rows.putAll(fresh);
      Violations v = findViolations(fresh);

      for (List<Id> grp : fitting) {
        List<Id> present = presentIn(grp, fresh);
        if (present.isEmpty() || rejectIfViolated(present, v)) {
          continue;
        }
        if (v.truncated) {
          // Some links are not known. Do not guess.
          reportGroup(present, Outcome.DEFERRED, truncatedMessage());
        } else {
          accepted.add(present);
        }
      }
    }

    // ── Reads ────────────────────────────────────────────────────────────
    private Map<Id, Workflow_Instance__c> lockRows(Set<Id> ids) {
      if (ids.isEmpty()) {
        return new Map<Id, Workflow_Instance__c>();
      }
      try {
        return new Map<Id, Workflow_Instance__c>(
          [
            SELECT Id, Status__c, Parent_Instance__c, Previous_Instance__c
            FROM Workflow_Instance__c
            WHERE Id IN :ids
            WITH SYSTEM_MODE
            FOR UPDATE
          ]
        );
      } catch (QueryException e) {
        // The lock wait timed out or found a deadlock.
        throw new LockException(e.getMessage());
      }
    }

    // Adds children, successors and predecessors, one link level a round.
    private void expandFamilies() {
      Set<Id> frontier = new Set<Id>(rows.keySet());
      Integer rounds = 0;
      while (!frontier.isEmpty()) {
        Integer budget = maxRelatedRows - relatedRowsRead;
        if (budget <= 0) {
          unexpanded.addAll(frontier);
          return;
        }
        rounds++;
        Set<Id> known = new Set<Id>(rows.keySet());
        Set<Id> predecessorIds = new Set<Id>();
        for (Id i : frontier) {
          Id prev = rows.get(i).Previous_Instance__c;
          if (prev != null && !known.contains(prev)) {
            predecessorIds.add(prev);
          }
        }
        List<Workflow_Instance__c> found = [
          SELECT Id, Status__c, Parent_Instance__c, Previous_Instance__c
          FROM Workflow_Instance__c
          WHERE
            (Id IN :predecessorIds
            OR Parent_Instance__c IN :frontier
            OR Previous_Instance__c IN :frontier)
            AND Id NOT IN :known
          WITH SYSTEM_MODE
          LIMIT :budget
        ];
        relatedRowsRead += found.size();
        Set<Id> next = new Set<Id>();
        for (Workflow_Instance__c row : found) {
          rows.put(row.Id, row);
          next.add(row.Id);
        }
        // A full page can be cut. A row past the last level is too deep.
        if (
          found.size() == budget || (rounds > maxLinkRounds && !next.isEmpty())
        ) {
          unexpanded.addAll(frontier);
          unexpanded.addAll(next);
          return;
        }
        frontier = next;
      }
    }

    // Reads the links of S that point out of S, after the lock of S.
    private Violations findViolations(Map<Id, Workflow_Instance__c> inSet) {
      Violations v = new Violations();
      if (inSet.isEmpty()) {
        return v;
      }
      Set<Id> keys = inSet.keySet();
      Set<Id> refIds = new Set<Id>();
      for (Workflow_Instance__c row : inSet.values()) {
        addIfOutside(refIds, row.Parent_Instance__c, keys);
        addIfOutside(refIds, row.Previous_Instance__c, keys);
      }
      Integer cap = maxRelatedRows + 1;
      List<Workflow_Instance__c> outside = [
        SELECT Id, Status__c, Parent_Instance__c, Previous_Instance__c
        FROM Workflow_Instance__c
        WHERE
          (Id IN :refIds
          OR Parent_Instance__c IN :keys
          OR Previous_Instance__c IN :keys)
          AND Id NOT IN :keys
        WITH SYSTEM_MODE
        LIMIT :cap
      ];
      v.truncated = outside.size() == cap;
      Map<Id, Workflow_Instance__c> byId = new Map<Id, Workflow_Instance__c>(
        outside
      );
      Set<Id> trusted = trustedIds(outside, inSet);
      Map<Id, Workflow_Instance__c> relocked = lockRows(trusted);
      for (Id i : trusted) {
        if (relocked.containsKey(i)) {
          byId.put(i, relocked.get(i));
        } else {
          // Deleted since the read. It can no longer read X.
          byId.remove(i);
        }
      }

      for (Workflow_Instance__c o : byId.values()) {
        if (keys.contains(o.Parent_Instance__c)) {
          if (isTerminal(o)) {
            v.dangling(o.Parent_Instance__c, 'child ' + o.Id);
          } else {
            v.active(o.Parent_Instance__c, 'child ' + label(o));
          }
        }
        if (keys.contains(o.Previous_Instance__c) && !isFinal(o)) {
          v.active(o.Previous_Instance__c, 'successor ' + label(o));
        }
      }
      for (Workflow_Instance__c row : inSet.values()) {
        if (!isTerminal(row)) {
          v.notTerminal.add(row.Id);
        }
        Workflow_Instance__c parent = byId.get(row.Parent_Instance__c);
        if (parent != null && !isFinal(parent)) {
          v.active(row.Id, 'parent ' + label(parent));
        }
        if (byId.containsKey(row.Previous_Instance__c)) {
          v.dangling(row.Id, 'predecessor ' + row.Previous_Instance__c);
        }
      }
      return v;
    }

    // The outside parents and successors that have a final status. The call
    // locks them and reads them again. A redrive or rollback that starts
    // first wins: the new status shows in the second read.
    private Set<Id> trustedIds(
      List<Workflow_Instance__c> outside,
      Map<Id, Workflow_Instance__c> inSet
    ) {
      Set<Id> parentIds = new Set<Id>();
      for (Workflow_Instance__c row : inSet.values()) {
        if (row.Parent_Instance__c != null) {
          parentIds.add(row.Parent_Instance__c);
        }
      }
      Set<Id> trusted = new Set<Id>();
      for (Workflow_Instance__c o : outside) {
        Boolean isRelied =
          parentIds.contains(o.Id) || inSet.containsKey(o.Previous_Instance__c);
        if (isRelied && isFinal(o)) {
          trusted.add(o.Id);
        }
      }
      return trusted;
    }

    // ── Grouping ─────────────────────────────────────────────────────────
    // Groups S by in-set parent and predecessor links, in requested order.
    private List<List<Id>> groupsOf(Set<Id> ids) {
      Map<Id, Id> root = new Map<Id, Id>();
      for (Id i : ids) {
        root.put(i, i);
      }
      for (Id i : ids) {
        Workflow_Instance__c row = rows.get(i);
        union(root, i, row.Parent_Instance__c);
        union(root, i, row.Previous_Instance__c);
      }
      // Requested Ids first, so groups keep the requested order.
      List<Id> order = new List<Id>();
      for (Id i : requested) {
        if (ids.contains(i)) {
          order.add(i);
        }
      }
      order.addAll(sortedIds(ids));
      Map<Id, List<Id>> byRoot = new Map<Id, List<Id>>();
      List<List<Id>> groups = new List<List<Id>>();
      Set<Id> seen = new Set<Id>();
      for (Id i : order) {
        if (!seen.add(i)) {
          continue;
        }
        Id r = find(root, i);
        if (!byRoot.containsKey(r)) {
          List<Id> members = new List<Id>();
          byRoot.put(r, members);
          groups.add(members);
        }
        byRoot.get(r).add(i);
      }
      return groups;
    }

    private void union(Map<Id, Id> root, Id a, Id b) {
      if (b == null || !root.containsKey(b)) {
        return;
      }
      Id ra = find(root, a);
      Id rb = find(root, b);
      if (ra != rb) {
        root.put(ra, rb);
      }
    }

    private Id find(Map<Id, Id> root, Id i) {
      Id r = i;
      while (root.get(r) != r) {
        r = root.get(r);
      }
      // Path compression.
      Id cur = i;
      while (root.get(cur) != r) {
        Id nextId = root.get(cur);
        root.put(cur, r);
        cur = nextId;
      }
      return r;
    }

    private Boolean isTooLarge(List<Id> grp) {
      if (grp.size() > MAX_INSTANCES_PER_CALL) {
        return true;
      }
      for (Id i : grp) {
        if (unexpanded.contains(i)) {
          return true;
        }
      }
      return false;
    }

    private List<Id> presentIn(
      List<Id> grp,
      Map<Id, Workflow_Instance__c> fresh
    ) {
      List<Id> present = new List<Id>();
      for (Id i : grp) {
        if (fresh.containsKey(i)) {
          present.add(i);
        } else {
          // Deleted since the first read.
          rows.remove(i);
        }
      }
      return present;
    }

    // ── Rules ────────────────────────────────────────────────────────────
    // Reports the group and returns true when a member breaks a rule.
    private Boolean rejectIfViolated(List<Id> grp, Violations v) {
      Id cause = null;
      Boolean causeActive = false;
      for (Id i : grp) {
        Boolean isActive = v.isActive(i);
        if (isActive || v.danglingById.containsKey(i)) {
          if (cause == null || (isActive && !causeActive)) {
            cause = i;
            causeActive = isActive;
          }
        }
      }
      if (cause == null) {
        return false;
      }
      for (Id i : grp) {
        if (!requestedSet.contains(i)) {
          continue;
        }
        if (v.notTerminal.contains(i)) {
          add(i, Outcome.REJECTED_NOT_TERMINAL, notTerminalMessage(i));
        } else if (v.activeById.containsKey(i)) {
          add(
            i,
            Outcome.REJECTED_RELATED_ACTIVE,
            'A related instance can still run and read this instance: ' +
              names(v.activeById.get(i)) +
              '. Purge again when it has a final status.'
          );
        } else if (v.danglingById.containsKey(i)) {
          add(
            i,
            Outcome.REJECTED_RELATED,
            'The purge would remove the link of related instances: ' +
              names(v.danglingById.get(i)) +
              '. Add them to the Ids, or set includeRelated to true.'
          );
        } else {
          add(
            i,
            causeActive
              ? Outcome.REJECTED_RELATED_ACTIVE
              : Outcome.REJECTED_RELATED,
            'Related instance ' +
              cause +
              ' in this group cannot be purged: ' +
              reasonOf(cause, v) +
              '. The call purges a related group as one unit.'
          );
        }
      }
      return true;
    }

    private String reasonOf(Id i, Violations v) {
      if (v.notTerminal.contains(i)) {
        return 'its status is ' + rows.get(i).Status__c;
      }
      if (v.activeById.containsKey(i)) {
        return names(v.activeById.get(i));
      }
      return names(v.danglingById.get(i));
    }

    // ── Delete ───────────────────────────────────────────────────────────
    private void deleteAccepted() {
      if (accepted.isEmpty()) {
        return;
      }
      List<List<Workflow_Instance__c>> members = new List<List<Workflow_Instance__c>>();
      for (List<Id> grp : accepted) {
        List<Workflow_Instance__c> m = new List<Workflow_Instance__c>();
        for (Id i : grp) {
          m.add(new Workflow_Instance__c(Id = i));
        }
        members.add(m);
      }
      CleanupDocumentPurger.PurgeChunk chunk = CleanupDocumentPurger.planGroups(
        members
      );
      WorkflowInstanceTeardown.Counts counts = WorkflowInstanceTeardown.run(
        chunk
      );
      result.purgedCount = counts.instances;
      result.deletedSignalCount = counts.signals;
      result.deletedLogCount = counts.logs;
      result.deletedFileCount = counts.files;

      List<Id> related = new List<Id>();
      for (List<Id> grp : accepted) {
        if (!chunk.instanceIdsToPurge.contains(grp[0])) {
          reportGroup(grp, Outcome.DEFERRED, deferredMessage());
        } else if (!counts.complete) {
          reportGroup(grp, Outcome.DEFERRED, satellitesMessage());
        } else {
          for (Id i : grp) {
            if (requestedSet.contains(i)) {
              add(i, Outcome.PURGED, 'Purged with its satellites.');
            } else {
              related.add(i);
            }
          }
        }
      }
      for (Id i : sortedIds(new Set<Id>(related))) {
        result.add(
          new InstanceResult(
            i,
            Outcome.PURGED,
            'Purged as a related instance.',
            false
          )
        );
      }
    }

    private void resetCounts() {
      result.purgedCount = 0;
      result.deletedSignalCount = 0;
      result.deletedLogCount = 0;
      result.deletedFileCount = 0;
      List<InstanceResult> kept = new List<InstanceResult>();
      for (InstanceResult r : result.results) {
        if (r.outcome != Outcome.PURGED) {
          kept.add(r);
        } else {
          result.byId.remove(r.instanceId);
        }
      }
      result.results = kept;
    }

    // ── Report ───────────────────────────────────────────────────────────
    private void reportWrongType() {
      for (Id i : requested) {
        if (i.getSObjectType() != Workflow_Instance__c.SObjectType) {
          add(i, Outcome.NOT_FOUND, notFoundMessage());
        }
      }
    }

    private void reportGroup(List<Id> grp, Outcome o, String message) {
      for (Id i : grp) {
        if (requestedSet.contains(i) && result.get(i) == null) {
          add(i, o, message);
        }
      }
    }

    private void reportUnreported(Outcome o, String message) {
      for (Id i : requested) {
        if (result.get(i) == null) {
          add(i, o, message);
        }
      }
    }

    // Reports NOT_FOUND for the rest. Orders the rows: requested Ids first,
    // in sorted order, then related Ids.
    private PurgeResult finish() {
      reportUnreported(Outcome.NOT_FOUND, notFoundMessage());
      List<InstanceResult> ordered = new List<InstanceResult>();
      for (Id i : requested) {
        ordered.add(result.get(i));
      }
      for (InstanceResult r : result.results) {
        if (!r.requested) {
          ordered.add(r);
        }
      }
      result.results = ordered;
      return result;
    }

    private void add(Id i, Outcome o, String message) {
      result.add(new InstanceResult(i, o, message, true));
    }

    private String notTerminalMessage(Id i) {
      List<String> statuses = new List<String>(
        WorkflowInstanceTeardown.purgeableStatuses()
      );
      statuses.sort();
      return 'The status is ' +
        rows.get(i).Status__c +
        '. You can purge only an instance with the status ' +
        String.join(statuses, ', ') +
        '. Cancel it or let it finish. Then purge it.';
    }
  }

  // Links of the purge set that point out of it, by instance in the set.
  private class Violations {
    Boolean truncated = false;
    Set<Id> notTerminal = new Set<Id>();
    Map<Id, List<String>> activeById = new Map<Id, List<String>>();
    Map<Id, List<String>> danglingById = new Map<Id, List<String>>();

    Boolean isActive(Id instanceId) {
      return notTerminal.contains(instanceId) ||
        activeById.containsKey(instanceId);
    }

    void active(Id instanceId, String what) {
      put(activeById, instanceId, what);
    }

    void dangling(Id instanceId, String what) {
      put(danglingById, instanceId, what);
    }

    private void put(Map<Id, List<String>> m, Id instanceId, String what) {
      if (!m.containsKey(instanceId)) {
        m.put(instanceId, new List<String>());
      }
      m.get(instanceId).add(what);
    }
  }

  private static Boolean isTerminal(Workflow_Instance__c row) {
    return WorkflowInstanceTeardown.isPurgeable(row.Status__c);
  }

  // Terminal and not Failed: no retry, run or rollback can start from it.
  private static Boolean isFinal(Workflow_Instance__c row) {
    return isTerminal(row) && row.Status__c != STATUS_FAILED;
  }

  private static String label(Workflow_Instance__c row) {
    return row.Id + ' (' + row.Status__c + ')';
  }

  private static void addIfOutside(Set<Id> target, Id candidate, Set<Id> keys) {
    if (candidate != null && !keys.contains(candidate)) {
      target.add(candidate);
    }
  }

  private static List<Id> sortedIds(Set<Id> ids) {
    List<String> sorted = new List<String>();
    for (Id i : ids) {
      sorted.add(String.valueOf(i));
    }
    sorted.sort();
    List<Id> out = new List<Id>();
    for (String s : sorted) {
      out.add(Id.valueOf(s));
    }
    return out;
  }

  private static String names(List<String> items) {
    List<String> shown = new List<String>();
    for (Integer i = 0; i < items.size() && i < MAX_NAMED_IDS; i++) {
      shown.add(items[i]);
    }
    String text = String.join(shown, ', ');
    if (items.size() > MAX_NAMED_IDS) {
      text += ' and ' + (items.size() - MAX_NAMED_IDS) + ' more';
    }
    return text;
  }

  private static String tooLargeMessage() {
    return 'The related group is larger than one call can purge (' +
      MAX_INSTANCES_PER_CALL +
      ' instances, ' +
      maxLinkRounds +
      ' link levels, ' +
      maxRelatedRows +
      ' related rows). Purge the oldest generations or the children first,' +
      ' without includeRelated.';
  }

  private static String deferredMessage() {
    return 'This call is full (' +
      MAX_INSTANCES_PER_CALL +
      ' instances, ' +
      CleanupDocumentPurger.MAX_DOCS_PER_CHUNK +
      ' files). Call purge again for this Id.';
  }

  private static String truncatedMessage() {
    return 'The Ids in this call have more than ' +
      maxRelatedRows +
      ' related rows to check. Call purge again with fewer Ids.';
  }

  private static String satellitesMessage() {
    return 'The call deleted part of the signals and logs. More remain.' +
      ' The instance and its files stay. Call purge again for this Id.';
  }

  private static String notFoundMessage() {
    return 'No workflow instance has this Id. If you purged it before, do nothing.';
  }

  private static String lockedMessage() {
    return 'Another transaction locks a row of this purge.' +
      ' Call purge again for this Id.';
  }
}
