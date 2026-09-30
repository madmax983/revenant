/**
 * @description Deletes operator-selected terminal instances and all their
 * satellites with zero orphans (issue #142). See `docs/instance-purge.md`.
 *
 * ```apex
 * WorkflowInstancePurge.PurgeResult r = WorkflowInstancePurge.purge(ids);
 * WorkflowInstancePurge.PurgeResult f = WorkflowInstancePurge.purge(ids, true);
 * ```
 *
 * Rules for each instance X in the final set S:
 * 1. X is terminal ({@link WorkflowInstanceTeardown#PURGEABLE_STATUSES}).
 * 2. Each child of X is in S.
 * 3. The predecessor of X (`Previous_Instance__c`) is in S.
 * 4. A successor of X that is not in S is terminal.
 * 5. The parent of X, when not in S, is terminal.
 *
 * Rules 2 and 3 stop a dangling child or chain. Removal of the oldest
 * generations of a chain passes. Rules 4 and 5 stop a delete under an
 * active run or rollback that still reads X.
 *
 * `includeRelated` adds the full family of each Id first: all generations in
 * both directions, all children and their families. It never adds a parent.
 *
 * Linked instances in S form a group. A group is purged in full or not at
 * all. The call purges the groups that pass and reports each skipped Id.
 * An expected state gives an outcome. Bad input throws
 * `WorkflowEngine.WorkflowException`.
 *
 * All SOQL and DML run in system mode. Call it only from trusted code.
 */
public inherited sharing class WorkflowInstancePurge {
  /** @description Maximum Ids in and instances purged by one call. */
  public static final Integer MAX_INSTANCES_PER_CALL = 50;
  /** @description Maximum link rounds that `includeRelated` follows. */
  public static final Integer MAX_LINK_ROUNDS = 20;
  /** @description Maximum related rows that one call reads. */
  public static final Integer MAX_RELATED_ROWS = 2000;

  private static final Integer MAX_NAMED_IDS = 5;

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
    /** The purge would leave a child or chain without its link. */
    REJECTED_RELATED,
    /** A related instance is not terminal and still reads this one. */
    REJECTED_RELATED_ACTIVE,
    /** The related group passes the bounds of one call. */
    REJECTED_TOO_LARGE,
    /** The bounds of this call are full. Call again for this Id. */
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

  // One call. Reads and locks, groups, checks the rules, then deletes.
  private class Planner {
    private final List<Id> requested = new List<Id>();
    private final Set<Id> requestedSet;
    private final Boolean includeRelated;
    private final PurgeResult result = new PurgeResult();
    // Rows of the purge set S.
    private Map<Id, Workflow_Instance__c> rows = new Map<Id, Workflow_Instance__c>();
    // Rows in S whose links a truncated read did not follow.
    private final Set<Id> unexpanded = new Set<Id>();
    private Integer relatedRowsRead = 0;

    Planner(Set<Id> instanceIds, Boolean includeRelated) {
      this.requestedSet = instanceIds;
      this.includeRelated = includeRelated;
      this.requested.addAll(sortedIds(instanceIds));
    }

    PurgeResult run() {
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
      List<List<Id>> groups = groupsOf(rows.keySet());

      List<List<Id>> checkable = new List<List<Id>>();
      Set<Id> checkIds = new Set<Id>();
      for (List<Id> grp : groups) {
        if (isTooLarge(grp)) {
          reportGroup(grp, Outcome.REJECTED_TOO_LARGE, tooLargeMessage());
        } else {
          checkable.add(grp);
          checkIds.addAll(grp);
        }
      }
      // Lock the added related rows too, then check links on fresh data.
      Map<Id, Workflow_Instance__c> fresh = new Map<Id, Workflow_Instance__c>();
      Set<Id> toLock = new Set<Id>();
      for (Id i : checkIds) {
        if (locked.contains(i)) {
          fresh.put(i, rows.get(i));
        } else {
          toLock.add(i);
        }
      }
      fresh.putAll(lockRows(toLock));
      rows.putAll(fresh);
      Violations v = findViolations(fresh);

      List<List<Id>> accepted = new List<List<Id>>();
      for (List<Id> grp : checkable) {
        List<Id> present = presentIn(grp, fresh);
        if (present.isEmpty()) {
          continue;
        }
        if (v.truncated) {
          reportGroup(present, Outcome.REJECTED_TOO_LARGE, tooLargeMessage());
        } else if (!rejectIfViolated(present, v)) {
          accepted.add(present);
        }
      }
      deleteWithinBounds(accepted);
      reportNotFound();
      return result;
    }

    // ── Reads ────────────────────────────────────────────────────────────
    private Map<Id, Workflow_Instance__c> lockRows(Set<Id> ids) {
      if (ids.isEmpty()) {
        return new Map<Id, Workflow_Instance__c>();
      }
      return new Map<Id, Workflow_Instance__c>(
        [
          SELECT Id, Status__c, Parent_Instance__c, Previous_Instance__c
          FROM Workflow_Instance__c
          WHERE Id IN :ids
          WITH SYSTEM_MODE
          FOR UPDATE
        ]
      );
    }

    // Adds children, successors and predecessors round by round.
    private void expandFamilies() {
      Set<Id> frontier = new Set<Id>(rows.keySet());
      Integer rounds = 0;
      while (!frontier.isEmpty()) {
        Integer budget = MAX_RELATED_ROWS - relatedRowsRead;
        if (rounds == MAX_LINK_ROUNDS || budget <= 0) {
          unexpanded.addAll(frontier);
          return;
        }
        rounds++;
        Set<Id> predecessorIds = new Set<Id>();
        for (Id i : frontier) {
          Id prev = rows.get(i).Previous_Instance__c;
          if (prev != null && !rows.containsKey(prev)) {
            predecessorIds.add(prev);
          }
        }
        List<Workflow_Instance__c> found = [
          SELECT Id, Status__c, Parent_Instance__c, Previous_Instance__c
          FROM Workflow_Instance__c
          WHERE
            Id IN :predecessorIds
            OR Parent_Instance__c IN :frontier
            OR Previous_Instance__c IN :frontier
          WITH SYSTEM_MODE
          LIMIT :budget
        ];
        relatedRowsRead += found.size();
        Set<Id> next = new Set<Id>();
        for (Workflow_Instance__c row : found) {
          if (!rows.containsKey(row.Id)) {
            rows.put(row.Id, row);
            next.add(row.Id);
          }
        }
        if (found.size() == budget) {
          // The read can be cut. These links are not known in full.
          unexpanded.addAll(frontier);
          unexpanded.addAll(next);
          return;
        }
        frontier = next;
      }
    }

    // Reads the links of S that point out of S, after the lock.
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
      Integer cap = MAX_RELATED_ROWS + 1;
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
      if (outside.size() == cap) {
        v.truncated = true;
        return v;
      }
      Map<Id, Workflow_Instance__c> byId = new Map<Id, Workflow_Instance__c>(
        outside
      );
      for (Workflow_Instance__c o : outside) {
        if (keys.contains(o.Parent_Instance__c)) {
          v.dangling(o.Parent_Instance__c, 'child ' + o.Id);
        }
        if (keys.contains(o.Previous_Instance__c) && !isTerminal(o)) {
          v.active(o.Previous_Instance__c, 'successor ' + label(o));
        }
      }
      for (Workflow_Instance__c row : inSet.values()) {
        if (!isTerminal(row)) {
          v.notTerminal.add(row.Id);
        }
        Workflow_Instance__c parent = byId.get(row.Parent_Instance__c);
        if (parent != null && !isTerminal(parent)) {
          v.active(row.Id, 'parent ' + label(parent));
        }
        if (byId.containsKey(row.Previous_Instance__c)) {
          v.dangling(row.Id, 'predecessor ' + row.Previous_Instance__c);
        }
      }
      return v;
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
        Boolean isActive =
          v.notTerminal.contains(i) || v.activeById.containsKey(i);
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
          add(
            i,
            Outcome.REJECTED_NOT_TERMINAL,
            'Status is ' +
              rows.get(i).Status__c +
              '. Only a terminal instance (' +
              String.join(
                new List<String>(WorkflowInstanceTeardown.PURGEABLE_STATUSES),
                ', '
              ) +
              ') can be purged. Cancel it or let it finish, then purge it.'
          );
        } else if (v.activeById.containsKey(i)) {
          add(
            i,
            Outcome.REJECTED_RELATED_ACTIVE,
            'A related instance is not terminal and still reads this one: ' +
              names(v.activeById.get(i)) +
              '. Purge again when it is terminal.'
          );
        } else if (v.danglingById.containsKey(i)) {
          add(
            i,
            Outcome.REJECTED_RELATED,
            'The purge would leave related instances without their link: ' +
              names(v.danglingById.get(i)) +
              '. Add them to the Ids, or set includeRelated to true.'
          );
        } else if (causeActive) {
          add(
            i,
            Outcome.REJECTED_RELATED_ACTIVE,
            'Related instance ' +
              cause +
              ' in this group is not terminal or has an active related' +
              ' instance. A related group is purged as one unit.'
          );
        } else {
          add(
            i,
            Outcome.REJECTED_RELATED,
            'Related instance ' +
              cause +
              ' in this group was rejected. A related group is purged' +
              ' as one unit.'
          );
        }
      }
      return true;
    }

    // ── Delete ───────────────────────────────────────────────────────────
    private void deleteWithinBounds(List<List<Id>> accepted) {
      List<List<Workflow_Instance__c>> fitting = new List<List<Workflow_Instance__c>>();
      List<List<Id>> fittingIds = new List<List<Id>>();
      Integer used = 0;
      for (List<Id> grp : accepted) {
        if (used + grp.size() > MAX_INSTANCES_PER_CALL) {
          reportGroup(grp, Outcome.DEFERRED, deferredMessage());
          continue;
        }
        used += grp.size();
        List<Workflow_Instance__c> members = new List<Workflow_Instance__c>();
        for (Id i : grp) {
          members.add(new Workflow_Instance__c(Id = i));
        }
        fitting.add(members);
        fittingIds.add(grp);
      }
      if (fitting.isEmpty()) {
        return;
      }
      CleanupDocumentPurger.PurgeChunk chunk = CleanupDocumentPurger.planGroups(
        fitting
      );
      WorkflowInstanceTeardown.Counts counts = WorkflowInstanceTeardown.run(
        chunk
      );
      result.purgedCount = counts.instances;
      result.deletedSignalCount = counts.signals;
      result.deletedLogCount = counts.logs;
      result.deletedFileCount = counts.files;

      List<Id> related = new List<Id>();
      for (List<Id> grp : fittingIds) {
        if (!chunk.instanceIdsToPurge.contains(grp[0])) {
          reportGroup(grp, Outcome.DEFERRED, deferredMessage());
          continue;
        }
        for (Id i : grp) {
          if (requestedSet.contains(i)) {
            add(i, Outcome.PURGED, 'Purged with its satellites.');
          } else {
            related.add(i);
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

    // ── Report ───────────────────────────────────────────────────────────
    private void reportGroup(List<Id> grp, Outcome o, String message) {
      for (Id i : grp) {
        if (requestedSet.contains(i)) {
          add(i, o, message);
        }
      }
    }

    private void reportNotFound() {
      for (Id i : requested) {
        if (result.get(i) == null) {
          add(
            i,
            Outcome.NOT_FOUND,
            'No workflow instance has this Id. It is possibly purged already.'
          );
        }
      }
      // Requested rows first, in sorted order. Then related rows.
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
    }

    private void add(Id i, Outcome o, String message) {
      result.add(new InstanceResult(i, o, message, true));
    }
  }

  // Links of the purge set that point out of it, by instance in the set.
  private class Violations {
    Boolean truncated = false;
    Set<Id> notTerminal = new Set<Id>();
    Map<Id, List<String>> activeById = new Map<Id, List<String>>();
    Map<Id, List<String>> danglingById = new Map<Id, List<String>>();

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
    return WorkflowInstanceTeardown.PURGEABLE_STATUSES.contains(row.Status__c);
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
    return 'The related group has more than ' +
      MAX_INSTANCES_PER_CALL +
      ' instances, more than ' +
      MAX_LINK_ROUNDS +
      ' link levels, or more than ' +
      MAX_RELATED_ROWS +
      ' related rows. Purge the oldest generations or the children first,' +
      ' without includeRelated.';
  }

  private static String deferredMessage() {
    return 'The bounds of this call (' +
      MAX_INSTANCES_PER_CALL +
      ' instances, ' +
      CleanupDocumentPurger.MAX_DOCS_PER_CHUNK +
      ' files) are full. Call purge again for this Id.';
  }
}
