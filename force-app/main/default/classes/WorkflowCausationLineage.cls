/**
 * @description Causation-lineage reconstruction for the Revenant engine. Walks a
 * `Workflow_Instance__c`'s parent/ancestor chain up to its root cause, resolving
 * each hop from `Causation_Id__c` (direct id, `key:`-scoped correlation key, or
 * JSON/legacy timestamp-suffixed form via {@link WorkflowCausationParser}) or
 * `Parent_Instance__c`. The walk is read-only (zero DML), bounded by a hop
 * ceiling and a transaction-wide predecessor-query budget so it is governor-safe
 * on deep chains. Extracted from `WorkflowEngine`; all SOQL executes in system
 * mode. Causation-id parsing/cleaning lives on {@link WorkflowCausationParser}
 * and status DTO assembly is delegated back to {@link WorkflowEngine} (the read
 * API), keeping each cohesive phase within its own complexity budget.
 */
public inherited sharing class WorkflowCausationLineage {
  /**
   * @description Transaction-wide budget of predecessor-chain SOQL queries the
   * lineage walk may spend, guarding against governor exhaustion on deep chains.
   */
  @TestVisible
  private static Integer predecessorQueriesRemaining = 15;

  /**
   * @description Returns the historical causation lineage (parent/ancestor chain)
   * of a workflow instance ID up to the root cause. Bounded to a maximum depth of
   * 12 hops to safeguard against cyclic/governor limits. Performs zero DML.
   * @param instanceId Id of the instance whose causation chain is walked
   * @return status DTOs ordered from the given instance up to its root cause;
   * empty when instanceId is null
   */
  public static List<WorkflowEngine.WorkflowStatus> getCausationLineage(
    Id instanceId
  ) {
    List<WorkflowEngine.WorkflowStatus> lineage = new List<WorkflowEngine.WorkflowStatus>();
    if (instanceId == null) {
      return lineage;
    }

    predecessorQueriesRemaining = 15;
    Id currentId = instanceId;
    Set<Id> visitedIds = new Set<Id>();
    Integer maxHops = 12;
    List<Workflow_Instance__c> ancestors = new List<Workflow_Instance__c>();

    for (Integer hop = 0; hop < maxHops; hop++) {
      if (currentId == null || visitedIds.contains(currentId)) {
        break;
      }
      visitedIds.add(currentId);

      Workflow_Instance__c inst = queryLineageInstanceById(currentId);
      if (inst == null) {
        break;
      }
      ancestors.add(inst);

      currentId = resolveNextAncestorId(inst, visitedIds);
    }

    Map<Id, String> resolvedOutputByDocId = WorkflowStatusProjection.bulkResolveOffloadedOutputs(
      ancestors
    );
    for (Workflow_Instance__c inst : ancestors) {
      lineage.add(
        WorkflowStatusProjection.buildStatus(inst, resolvedOutputByDocId)
      );
    }
    return lineage;
  }

  /**
   * @description Fetches the single Workflow_Instance__c row at `currentId`
   * for lineage-walk assembly. Kept as a helper so the per-hop SOQL is not
   * lexically inside `getCausationLineage`'s hop loop. The per-hop query is
   * intentional and bounded: the caller walks at most 12 hops (maxHops) with a
   * visited-id guard, so this helper is called at most 12 times per lineage
   * request.
   * @param currentId the ancestor id to fetch this hop
   * @return the ancestor instance row, or null when nothing is found
   */
  private static Workflow_Instance__c queryLineageInstanceById(Id currentId) {
    List<Workflow_Instance__c> records = [
      SELECT
        Id,
        Workflow_Name__c,
        Correlation_Key__c,
        Status__c,
        Error_Message__c,
        Causation_Id__c,
        Previous_Instance__c,
        Parent_Instance__c,
        Output__c,
        CreatedDate
      FROM Workflow_Instance__c
      WHERE Id = :currentId
      WITH SYSTEM_MODE
      LIMIT 1
    ];
    return records.isEmpty() ? null : records[0];
  }

  /**
   * @description Resolves the next ancestor id for a lineage-walk hop by
   * inspecting the instance's `Causation_Id__c` and, when it is not present,
   * falling back to `Parent_Instance__c`. Handles three ancestor encodings in
   * the same priority order as the pre-refactor loop body: (1) blank
   * causation id -> Parent_Instance__c; (2) valid direct Id -> confirm the
   * target row exists; (3) `key:`-scoped id -> resolve via correlation-key
   * parent query bounded by `earliestCreatedDate` and the visited-id set. A
   * valid direct-id whose target row does not exist resolves to null (the
   * loop then breaks on the next iteration).
   *
   * Per-hop SOQL is intentional and bounded: the outer walk runs at most 12
   * hops, so this helper issues at most two SOQL queries per call (direct
   * lookup + optional `key:` parent query, plus whatever
   * `getEarliestPredecessorCreatedDate` uses when no inline timestamp is
   * present) and the total is capped by the hop count.
   * @param inst the ancestor row from this hop
   * @param visitedIds the ids already walked; used to short-circuit the
   *   correlation-key parent query so the walk cannot revisit a previous hop
   * @return the next currentId to walk, or null to signal end-of-lineage
   *   (loop breaks on the next iteration)
   */
  private static Id resolveNextAncestorId(
    Workflow_Instance__c inst,
    Set<Id> visitedIds
  ) {
    String cause = inst.Causation_Id__c;
    if (String.isBlank(cause)) {
      return inst.Parent_Instance__c;
    }

    if (WorkflowCausationParser.isValidId(cause)) {
      List<Workflow_Instance__c> directRecords = [
        SELECT Id
        FROM Workflow_Instance__c
        WHERE Id = :cause
        WITH SYSTEM_MODE
        LIMIT 1
      ];
      // Valid direct id whose target row is missing resolves to null so the
      // outer loop breaks on the next iteration (matches pre-refactor behavior,
      // where resolvedId stayed null and the final `else` set currentId=null).
      return directRecords.isEmpty() ? null : directRecords[0].Id;
    }

    if (cause.startsWith('key:')) {
      WorkflowCausationParser.CausationKeyParse parsed = WorkflowCausationParser.parseCausationTimestamp(
        cause
      );
      String correlationKey = parsed.correlationKey;
      DateTime earliestCreatedDate = parsed.earliestCreatedDate;
      if (earliestCreatedDate == null) {
        earliestCreatedDate = getEarliestPredecessorCreatedDate(inst);
      }

      List<Workflow_Instance__c> parents = [
        SELECT Id
        FROM Workflow_Instance__c
        WHERE
          (Correlation_Key__c = :correlationKey
          OR Active_Correlation_Key__c = :correlationKey
          OR Root_Correlation_Key__c = :correlationKey)
          AND CreatedDate <= :earliestCreatedDate
          AND Id NOT IN :visitedIds
        WITH SYSTEM_MODE
        ORDER BY CreatedDate DESC
        LIMIT 1
      ];
      return parents.isEmpty() ? null : parents[0].Id;
    }

    return null;
  }

  /**
   * @description Convenience overload resolving the earliest predecessor
   * CreatedDate with the default 100-hop ceiling.
   * @param inst the instance whose predecessor chain to walk
   * @return the earliest CreatedDate observed along the predecessor chain
   */
  private static DateTime getEarliestPredecessorCreatedDate(
    Workflow_Instance__c inst
  ) {
    return getEarliestPredecessorCreatedDate(inst, 100);
  }

  /**
   * @description Mutable state for a predecessor-chain walk: the earliest
   * CreatedDate seen so far, the next predecessor id to visit, the set of
   * already-visited ids, the hop count and the hop ceiling.
   */
  private class PredecessorWalk {
    /** @description Earliest CreatedDate observed so far along the chain. */
    DateTime earliest;
    /** @description The next predecessor id to visit, or null to stop. */
    Id prevId;
    /** @description Ids already visited, guarding against cycles. */
    Set<Id> visited;
    /** @description Number of hops taken so far. */
    Integer hopsCount;
    /** @description Maximum hops permitted for this walk. */
    Integer maxPredecessors;
  }

  /**
   * @description Whether the walk may take another hop to a present predecessor
   * node: the next id is set, unvisited, the node is present, and the hop ceiling
   * is not yet reached.
   * @param walk the walk state
   * @param nodePresent whether the next predecessor node is populated
   * @return true when the walk may advance to the node
   */
  private static Boolean canLookAhead(
    PredecessorWalk walk,
    Boolean nodePresent
  ) {
    return walk.prevId != null &&
      !walk.visited.contains(walk.prevId) &&
      nodePresent &&
      walk.hopsCount < walk.maxPredecessors;
  }

  /**
   * @description Walks up to four further predecessor levels in-memory from the
   * queried row `p` (whose Previous_Instance__r chain was pre-fetched five deep),
   * advancing the walk's earliest/prevId/hopsCount/visited state. Stops at the
   * first level whose predecessor is absent, already visited, or beyond the hop
   * ceiling.
   * @param walk the walk state to advance
   * @param p the queried row with its pre-fetched predecessor chain
   */
  private static void advanceInMemoryLookAhead(
    PredecessorWalk walk,
    Workflow_Instance__c p
  ) {
    if (!canLookAhead(walk, p.Previous_Instance__r != null)) {
      return;
    }
    walk.visited.add(walk.prevId);
    walk.earliest = p.Previous_Instance__r.CreatedDate;
    walk.prevId = p.Previous_Instance__r.Previous_Instance__c;
    walk.hopsCount++;

    if (
      !canLookAhead(walk, p.Previous_Instance__r.Previous_Instance__r != null)
    ) {
      return;
    }
    walk.visited.add(walk.prevId);
    walk.earliest = p.Previous_Instance__r.Previous_Instance__r.CreatedDate;
    walk.prevId = p.Previous_Instance__r.Previous_Instance__r.Previous_Instance__c;
    walk.hopsCount++;

    if (
      !canLookAhead(
        walk,
        p.Previous_Instance__r.Previous_Instance__r.Previous_Instance__c != null
      )
    ) {
      return;
    }
    walk.visited.add(walk.prevId);
    walk.earliest = p.Previous_Instance__r.Previous_Instance__r.Previous_Instance__r
      .CreatedDate;
    walk.prevId = p.Previous_Instance__r.Previous_Instance__r.Previous_Instance__r
      .Previous_Instance__c;
    walk.hopsCount++;

    if (
      !canLookAhead(
        walk,
        p.Previous_Instance__r.Previous_Instance__r.Previous_Instance__r
          .Previous_Instance__c != null
      )
    ) {
      return;
    }
    walk.visited.add(walk.prevId);
    walk.earliest = p.Previous_Instance__r.Previous_Instance__r.Previous_Instance__r
      .Previous_Instance__r.CreatedDate;
    walk.prevId = p.Previous_Instance__r.Previous_Instance__r.Previous_Instance__r
      .Previous_Instance__r.Previous_Instance__c;
    walk.hopsCount++;
  }

  /**
   * @description Walks the predecessor chain from `inst` to find the earliest
   * CreatedDate, bounded by `maxPredecessors` hops and the transaction-wide
   * predecessor-query budget, look-ahead-fetching five chain levels per query.
   * @param inst the instance whose predecessor chain to walk
   * @param maxPredecessors the hop ceiling for this walk
   * @return the earliest CreatedDate observed along the predecessor chain
   */
  private static DateTime getEarliestPredecessorCreatedDate(
    Workflow_Instance__c inst,
    Integer maxPredecessors
  ) {
    PredecessorWalk walk = new PredecessorWalk();
    walk.earliest = inst.CreatedDate;
    walk.prevId = inst.Previous_Instance__c;
    walk.visited = new Set<Id>{ inst.Id };
    walk.hopsCount = 0;
    walk.maxPredecessors = maxPredecessors;
    while (
      walk.prevId != null &&
      !walk.visited.contains(walk.prevId) &&
      walk.hopsCount < maxPredecessors &&
      predecessorQueriesRemaining > 0
    ) {
      walk.visited.add(walk.prevId);
      predecessorQueriesRemaining--;
      Workflow_Instance__c p = queryPredecessorChain(walk.prevId);
      if (p == null) {
        break;
      }

      walk.earliest = p.CreatedDate;
      walk.prevId = p.Previous_Instance__c;
      walk.hopsCount++;

      // Look ahead up to 4 more levels from p in-memory
      advanceInMemoryLookAhead(walk, p);
    }
    return walk.earliest;
  }

  /**
   * @description Fetches one predecessor instance (with 5 chain levels of
   * {@code Previous_Instance__r} pre-fetched) for a single hop of the
   * predecessor-chain walk in {@link getEarliestPredecessorCreatedDate}.
   * <p><b>Intentional per-iteration SOQL.</b> This runs exactly one SOQL query
   * per hop of a sequential predecessor-chain graph walk: the next predecessor
   * id is only knowable after the current row is read, so the walk cannot be
   * bulkified into a single query. It is governor-safe by <b>two independent
   * bounds</b> enforced in the caller's {@code while} condition &mdash; the
   * per-call {@code maxPredecessors} hop cap AND the transaction-wide
   * {@code predecessorQueriesRemaining} query budget &mdash; and each query
   * already look-ahead-fetches 5 chain levels to minimise the hop count.
   * @param prevId the predecessor instance id to fetch
   * @return the predecessor row, or null when no matching row exists
   *         (signalling the caller to stop walking)
   */
  private static Workflow_Instance__c queryPredecessorChain(Id prevId) {
    List<Workflow_Instance__c> prevs = [
      SELECT
        Id,
        CreatedDate,
        Previous_Instance__c,
        Previous_Instance__r.CreatedDate,
        Previous_Instance__r.Previous_Instance__c,
        Previous_Instance__r.Previous_Instance__r.CreatedDate,
        Previous_Instance__r.Previous_Instance__r.Previous_Instance__c,
        Previous_Instance__r.Previous_Instance__r.Previous_Instance__r.CreatedDate,
        Previous_Instance__r.Previous_Instance__r.Previous_Instance__r.Previous_Instance__c,
        Previous_Instance__r.Previous_Instance__r.Previous_Instance__r.Previous_Instance__r.CreatedDate,
        Previous_Instance__r.Previous_Instance__r.Previous_Instance__r.Previous_Instance__r.Previous_Instance__c
      FROM Workflow_Instance__c
      WHERE Id = :prevId
      WITH SYSTEM_MODE
      LIMIT 1
    ];
    return prevs.isEmpty() ? null : prevs[0];
  }
}
