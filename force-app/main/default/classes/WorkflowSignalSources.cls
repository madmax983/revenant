/**
 * @description Read-side signal accessors for the durable-execution engine's
 * exactly-once signal handling: the `StepContext.SignalSource` implementations a
 * step reads its pending signals through. A serial step reads at-least-once via
 * `PendingSignalSource`; a parallel-branch step atomically claims each signal at
 * read time (Received → Processing) via `ParallelBranchSignalSource` so two
 * concurrent branches cannot both process the same payload. Both draw from
 * per-execution row/statement budgets so a read can never observe (or claim)
 * more rows than the COMPLETE consume pass can handle. All DML and SOQL run in
 * system mode.
 */
public inherited sharing class WorkflowSignalSources {
  // Caps how many signals a serial step may observe in one execution. Serial
  // steps never claim (no read-side DML), so the only DML is the COMPLETE
  // consume; 8 000 keeps the consume update (matched ids + same-name duplicate
  // cleanup) safely under the 10 000 DML-row limit while never exposing more
  // rows than completion can consume. Excess rows stay Received for a later read.
  // @TestVisible (non-final) so a test can shrink the cap to exercise budget
  // exhaustion without inserting thousands of rows.
  @TestVisible
  private static Integer serialSignalRowCap = 8000;

  // Caps how many signals a single parallel-branch accessor call claims at read
  // time. A claim writes Processing now and the matching COMPLETE writes
  // Consumed later in the SAME transaction, so claim + consume both draw on the
  // 10 000 DML-row governor limit; 4 000 leaves headroom for the consume pass
  // and the engine's other DML. Bounding the claim keeps a branch facing a huge
  // redelivery backlog from blowing the limit on every attempt and stalling
  // forever; any rows beyond the cap stay Received for a later read.
  private static final Integer PARALLEL_CLAIM_ROW_CAP = 4000;
  // Caps how many claim DML *statements* a parallel branch issues in one
  // execution. Each named getSignal/hasSignal (and each getSignals page) is one
  // update statement, so a fan-in step probing many distinct names could exceed
  // the 150 DML-statement governor limit; once this budget is spent the branch
  // reads remaining signals WITHOUT claiming (at-least-once). 100 leaves room
  // for the consume statement and the engine's other DML.
  private static final Integer PARALLEL_CLAIM_STATEMENT_BUDGET = 100;
  // How many times a parallel getSignals() re-pages past a fully-lost candidate
  // page (every row claimed by a sibling between query and lock) before giving
  // up, so a loser does not return empty while later Received rows remain.
  private static final Integer PARALLEL_CLAIM_PAGE_RETRIES = 3;

  /**
   * @description Lazily supplies the pending (unconsumed) signals targeting an
   * instance so a step that never reads signals pays no query/heap cost for
   * unrelated unconsumed signals on the instance. Tracks a cumulative row budget
   * across accessor calls so the step can never observe (and mark consumed) more
   * rows than the COMPLETE consume pass can handle.
   */
  @TestVisible
  public class PendingSignalSource implements StepContext.SignalSource {
    private final Id instanceId;
    private Integer rowBudget = serialSignalRowCap;
    private Boolean capped = false;

    /**
     * @description Builds a serial pending-signal source for the given instance.
     * @param instanceId Id of the instance whose signals are read
     */
    public PendingSignalSource(Id instanceId) {
      this.instanceId = instanceId;
    }

    /**
     * @description Returns the pending (Received) signals of the given name for
     * this instance, drawing from a per-execution row budget. Once the budget is
     * spent it returns a single still-Received row so a suspend-if-empty step is
     * never stranded while a matching signal is pending.
     * @param signalName name of the signals to read
     * @return the pending signals of that name within the remaining row budget
     */
    public List<StepContext.Signal> getPendingSignals(String signalName) {
      if (rowBudget <= 0) {
        capped = true;
        // Don't report a false absence once the budget is spent: return one
        // still-Received row so a step that suspends-if-empty is not stranded
        // while a matching signal is pending (its wake event already fired on
        // insert). Bounded to a single row; the budget still bounds full
        // enumeration, and the remainder stays Received for a later read.
        return loadPendingSignals(this.instanceId, signalName, 1);
      }
      List<StepContext.Signal> loaded = loadPendingSignals(
        this.instanceId,
        signalName,
        rowBudget
      );
      // A full page means more rows of this name may exist beyond what was
      // returned, so the step did not necessarily see every pending row.
      if (loaded.size() >= rowBudget) {
        capped = true;
      }
      rowBudget -= loaded.size();
      return loaded;
    }

    /**
     * @description Returns the most-recent signal of the given name for this
     * instance. This single-row lookup always reflects database truth, even after
     * the row budget is spent, so a step never suspends on a false absence.
     * @param signalName name of the signal to look up
     * @return the latest matching signal, or null when none exists
     */
    public StepContext.Signal getLatestSignal(String signalName) {
      // A single-row "latest"/"has" lookup must reflect database truth even
      // after the row budget is spent. Reporting a false absence here is unsafe:
      // a step that then suspends as if the signal never arrived would never be
      // re-woken (the signal's wake event already fired on insert), stranding
      // the instance. One extra observed row stays within the COMPLETE consume
      // pass's headroom (the budget caps list reads, not single lookups), so the
      // lookup always queries the true most-recent row rather than gating on the
      // budget. Only a genuine full page is still flagged capped.
      //
      // Consume-safety of ungated lookups: each distinct name is queried once
      // (StepContext caches per name via latestByName), so the number of extra
      // observed rows past budget exhaustion is bounded by the SOQL-query
      // governor limit (~200 async) -- far under the 1 000-row headroom between
      // serialSignalRowCap (8 000) and the 9 000-row consume cap. A step
      // would exhaust SOQL long before it could match more ids than
      // markSignalsConsumed() can update, so no consume-overflow redelivery
      // arises (Codex L1108 documented as not reachable, not gated).
      StepContext.Signal latest = loadLatestSignal(this.instanceId, signalName);
      if (latest != null && rowBudget > 0) {
        rowBudget -= 1;
      }
      return latest;
    }

    /**
     * @description Reports whether a read hit the row-budget cap, so the engine
     * knows the step may not have observed every pending row.
     * @return true when a read was truncated by the row budget
     */
    public Boolean readWasCapped() {
      return capped;
    }
  }

  /**
   * @description Signal source for parallel branch steps. Atomically claims each
   * signal at read time (Received → Processing) so two concurrent branches cannot
   * both process the same payload. The claim is held for the lifetime of the
   * current execution attempt: COMPLETE promotes Processing → Consumed; any other
   * outcome (YIELD, SUSPEND, SLEEP, RETRY, …) rolls the claim back to Received
   * so the branch can re-observe the signal on its next run. Each call claims at
   * most PARALLEL_CLAIM_ROW_CAP rows so the read can never exceed the DML-row
   * limit before the step returns.
   *
   * Two-step pattern: an ORDER BY query finds candidate IDs, then a FOR UPDATE
   * lock on those IDs atomically claims them. The claim writes uncommitted DML,
   * which makes a later callout in the same transaction illegal; a step that
   * reads a signal and then calls out on its payload must implement CalloutStep
   * to opt into a non-claiming (at-least-once) read instead.
   */
  public inherited sharing class ParallelBranchSignalSource implements StepContext.SignalSource {
    private final Id instanceId;
    // Cumulative claim ROW budget across all accessor calls in this execution,
    // so claim DML (now) + the matching consume DML (at COMPLETE, same
    // transaction) together stay under the 10 000 DML-row limit no matter how
    // many names the step reads.
    private Integer claimBudget = PARALLEL_CLAIM_ROW_CAP;
    // Cumulative claim DML-STATEMENT budget; bounds how many update statements
    // the accessors issue so a many-name fan-in cannot exceed the 150 statement
    // limit. When spent, reads fall back to non-claiming (at-least-once).
    private Integer claimStatementBudget = PARALLEL_CLAIM_STATEMENT_BUDGET;
    // Set whenever a read was truncated, or fell back to non-claiming, so the
    // step may not have seen (or exclusively claimed) every matching row. The
    // engine then skips same-name duplicate cleanup at consume time.
    private Boolean capped = false;

    /**
     * @description Builds a parallel-branch claiming signal source for the given
     * instance.
     * @param instanceId Id of the instance whose signals are claimed and read
     */
    public ParallelBranchSignalSource(Id instanceId) {
      this.instanceId = instanceId;
    }

    /**
     * @description Reports whether a read was truncated or fell back to a
     * non-claiming (at-least-once) read, so the engine skips same-name duplicate
     * cleanup at consume time.
     * @return true when a read did not exclusively claim every matching row
     */
    public Boolean readWasCapped() {
      return capped;
    }

    // True when SOQL usage is close to the governor limit. Each claim issues a
    // FOR UPDATE lock query, so a many-name fan-in could exhaust SOQL before the
    // DML-statement budget; once near the limit the accessors stop locking and
    // read non-claiming instead (at-least-once) to make progress.
    private Boolean nearSoqlLimit() {
      return Limits.getLimitQueries() > 0 &&
        Limits.getQueries() >= (Integer) (0.8 * Limits.getLimitQueries());
    }

    // Reads still-Received rows in arrival order, optionally excluding ids and
    // scoped to a name. Read-only (no claim) -- the callers decide whether to
    // claim what comes back.
    private List<Workflow_Signal__c> queryReceived(
      String signalName,
      Set<Id> excludeIds,
      Integer limitN
    ) {
      Set<Id> skip = (excludeIds != null) ? excludeIds : new Set<Id>();
      if (String.isBlank(signalName)) {
        return [
          SELECT Id, Signal_Name__c, Payload__c, CreatedDate
          FROM Workflow_Signal__c
          WHERE
            Workflow_Instance__c = :instanceId
            AND Status__c = 'Received'
            AND Id NOT IN :skip
          WITH SYSTEM_MODE
          ORDER BY CreatedDate ASC, Id ASC
          LIMIT :limitN
        ];
      }
      return [
        SELECT Id, Signal_Name__c, Payload__c, CreatedDate
        FROM Workflow_Signal__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Status__c = 'Received'
          AND Signal_Name__c = :signalName
          AND Id NOT IN :skip
        WITH SYSTEM_MODE
        ORDER BY CreatedDate ASC, Id ASC
        LIMIT :limitN
      ];
    }

    private List<StepContext.Signal> toSignals(List<Workflow_Signal__c> rows) {
      List<String> rawPayloads = new List<String>();
      for (Workflow_Signal__c c : rows) {
        rawPayloads.add(c.Payload__c);
      }
      // Resolve offloaded payloads in one bulk query rather than one per row.
      List<String> resolvedPayloads = WorkflowPayloadOffload.resolvePayloads(
        rawPayloads
      );

      List<StepContext.Signal> out = new List<StepContext.Signal>();
      for (Integer i = 0; i < rows.size(); i++) {
        out.add(
          new StepContext.Signal(
              rows[i].Id,
              rows[i].Signal_Name__c,
              resolvedPayloads[i]
            )
            .withCreatedDate(rows[i].CreatedDate)
        );
      }
      return out;
    }

    /**
     * @description Atomically claims (Received to Processing) and returns the
     * pending signals of the given name for this branch, bounded by the claim row
     * and statement budgets. When a budget is spent it falls back to a single
     * non-claiming read so a suspend-if-empty branch is not stranded.
     * @param signalName name of the signals to read
     * @return the claimed (or, past budget, at-least-once) signals of that name
     */
    public List<StepContext.Signal> getPendingSignals(String signalName) {
      if (claimBudget <= 0) {
        capped = true;
        // Don't report a false absence once the claim budget is spent: return
        // one still-Received row read-only (at-least-once) so a branch that
        // suspends-if-empty is not stranded while a matching signal is pending.
        // Bounded to a single row; no claim is issued.
        return toSignals(queryReceived(signalName, null, 1));
      }
      // Statement or SOQL budget spent: read without claiming so a many-name
      // fan-in cannot exceed the DML-statement or SOQL limit. These rows are
      // returned read-only (claimed = false) and at-least-once; mark capped.
      // Debit the row budget just like the claim path so total observed rows
      // stay bounded by PARALLEL_CLAIM_ROW_CAP -- otherwise repeated fallback
      // pages could mark more observed-only ids than the COMPLETE consume pass
      // (capped at 9 000) can handle, leaving the remainder Received.
      if (claimStatementBudget <= 0 || nearSoqlLimit()) {
        capped = true;
        List<Workflow_Signal__c> rows = queryReceived(
          signalName,
          null,
          claimBudget
        );
        claimBudget -= rows.size();
        return toSignals(rows);
      }

      // Try to claim a page; if a sibling claimed the entire page between query
      // and lock, re-page past it (bounded) so we do not return empty while
      // later Received rows remain unclaimed and unwoken.
      return claimReceivedSignalPages(signalName);
    }

    /**
     * @description Pages through Received rows of the given name, locking and
     * claiming a full page at a time and re-paging past pages fully lost to
     * siblings. Keeps the FOR UPDATE query and claim update inside the paging
     * loop by design.
     * @param signalName the signal name to claim
     * @return the claimed signals from the first successfully-locked page, or an
     *   empty list when no matching Received rows survive claiming
     */
    private List<StepContext.Signal> claimReceivedSignalPages(
      String signalName
    ) {
      Set<Id> tried = new Set<Id>();
      Integer attempts = 0;
      while (
        claimBudget > 0 &&
        claimStatementBudget > 0 &&
        attempts < PARALLEL_CLAIM_PAGE_RETRIES
      ) {
        attempts++;
        List<Workflow_Signal__c> candidates = queryReceived(
          signalName,
          tried,
          claimBudget
        );
        if (candidates.isEmpty()) {
          break; // no more matching Received rows anywhere
        }
        // A full page means more matching rows may remain beyond the budget,
        // so flag capped: the COMPLETE consume then preserves (does not clean up)
        // same-name rows this read did not return, leaving them Received for a
        // later read rather than losing them.
        //
        // Short-page note: if a sibling claims only PART of this page between the
        // query and the FOR UPDATE lock, we return just the surviving subset
        // (the sibling exclusively owns the rest -- correct for exactly-once).
        // When the page was NOT full, the query already returned every matching
        // Received row, so that subset is the complete backlog. A short page that
        // still leaves matching rows unreturned can only arise from a FULL page,
        // which requires >PARALLEL_CLAIM_ROW_CAP pending rows of one name (or a
        // budget already drawn down by claiming that many) -- the same
        // pathological >cap regime as the documented at-least-once degradation;
        // capped is set above so the remainder is preserved for a later read.
        if (candidates.size() >= claimBudget) {
          capped = true;
        }
        Set<Id> candidateIds = new Map<Id, Workflow_Signal__c>(candidates)
          .keySet();
        tried.addAll(candidateIds);

        List<StepContext.Signal> claimed = lockAndClaimSignalPage(
          candidateIds,
          candidates
        );
        if (claimed == null) {
          continue; // whole page lost to siblings; try the next page
        }
        return claimed;
      }
      return new List<StepContext.Signal>();
    }

    /**
     * @description Locks the candidate ids with `FOR UPDATE` and, if any
     * survive, atomically marks them Processing and updates them in a single
     * DML statement. The FOR UPDATE query and the follow-on update run inside
     * this one helper call so they stay in the same transaction context and
     * remain atomic per page. Debits the caller's claim row and statement
     * budgets on success.
     *
     * The per-invocation SOQL FOR UPDATE + DML update is intentional and
     * bounded: the caller loops at most `PARALLEL_CLAIM_PAGE_RETRIES` times and
     * returns immediately on the first successful claim, so this helper is
     * called at most that many times per accessor call (typically once).
     * @param candidateIds ids returned by the read-only Received query
     * @param candidates the corresponding candidate rows (payload source)
     * @return the claimed signals for this page on success, or null when the
     *   whole page was lost to siblings so the caller should re-page
     */
    private List<StepContext.Signal> lockAndClaimSignalPage(
      Set<Id> candidateIds,
      List<Workflow_Signal__c> candidates
    ) {
      List<Workflow_Signal__c> locked = [
        SELECT Id
        FROM Workflow_Signal__c
        WHERE Id IN :candidateIds AND Status__c = 'Received'
        WITH SYSTEM_MODE
        FOR UPDATE
      ];
      if (locked.isEmpty()) {
        return null;
      }
      Set<Id> claimedIds = markSignalsProcessing(locked);
      Database.update(locked, true, AccessLevel.SYSTEM_MODE); // one statement for the whole page
      claimBudget -= claimedIds.size();
      claimStatementBudget -= 1;
      return buildClaimedSignals(candidates, claimedIds);
    }

    /**
     * @description Flips each locked row to Processing (in memory) and returns
     * the claimed ids.
     * @param locked the FOR UPDATE-locked Received rows
     * @return the set of ids marked Processing
     */
    private Set<Id> markSignalsProcessing(List<Workflow_Signal__c> locked) {
      Set<Id> claimedIds = new Set<Id>();
      for (Workflow_Signal__c sig : locked) {
        sig.Status__c = 'Processing';
        claimedIds.add(sig.Id);
      }
      return claimedIds;
    }

    /**
     * @description Builds claimed StepContext.Signals for the subset of
     * candidates this branch won, bulk-resolving any offloaded payloads in a
     * single query.
     * @param candidates the candidate rows queried this page
     * @param claimedIds the ids this branch exclusively claimed
     * @return the claimed signals, marked claimed with their created dates
     */
    private List<StepContext.Signal> buildClaimedSignals(
      List<Workflow_Signal__c> candidates,
      Set<Id> claimedIds
    ) {
      List<Workflow_Signal__c> claimedRows = new List<Workflow_Signal__c>();
      List<String> rawPayloads = new List<String>();
      for (Workflow_Signal__c c : candidates) {
        if (claimedIds.contains(c.Id)) {
          claimedRows.add(c);
          rawPayloads.add(c.Payload__c);
        }
      }
      // Resolve any offloaded payloads with a single bulk query (not one per
      // row), matching the read-only list path: a claimed page of offloaded
      // child-completion signals would otherwise run one ContentVersion query
      // each and could exhaust SOQL.
      List<String> resolvedPayloads = WorkflowPayloadOffload.resolvePayloads(
        rawPayloads
      );
      List<StepContext.Signal> result = new List<StepContext.Signal>();
      for (Integer i = 0; i < claimedRows.size(); i++) {
        // claimed = true: this branch now exclusively owns the row.
        result.add(
          new StepContext.Signal(
              claimedRows[i].Id,
              claimedRows[i].Signal_Name__c,
              resolvedPayloads[i]
            )
            .withCreatedDate(claimedRows[i].CreatedDate)
            .asClaimed()
        );
      }
      return result;
    }

    /**
     * @description Atomically claims and returns the most-recent signal of the
     * given name for this branch, re-paging past candidate pages fully claimed by
     * siblings so a loser does not observe a false absence.
     * @param signalName name of the signal to look up
     * @return the latest claimed signal, or null when none is available
     */
    public StepContext.Signal getLatestSignal(String signalName) {
      if (String.isBlank(signalName)) {
        return null;
      }
      // A sibling can claim the newest candidates between our query and lock. If
      // an entire page of 10 is lost that way, a still-Received row just beyond
      // the page must not be reported absent (which could strand it), so re-page
      // (claimed rows are now Processing and drop out of the Received view) up to
      // a bounded number of times.
      for (
        Integer attempt = 0; attempt <= PARALLEL_CLAIM_PAGE_RETRIES; attempt++
      ) {
        List<Workflow_Signal__c> candidates = queryLatestSignalCandidates(
          instanceId,
          signalName
        );
        if (candidates.isEmpty()) {
          return null; // no matching Received rows remain
        }
        // Row, statement or SOQL budget spent: a single-row lookup must still
        // reflect database truth, so return the newest read-only (at-least-once)
        // rather than reporting a false absence -- a branch that then suspends as
        // if the signal never arrived would never be re-woken (its wake event
        // already fired on insert) and would strand. No claim is issued (no
        // budget), so mark capped to skip same-name cleanup at consume.
        if (claimBudget <= 0 || claimStatementBudget <= 0 || nearSoqlLimit()) {
          capped = true;
          Workflow_Signal__c c = candidates[0];
          return new StepContext.Signal(
              c.Id,
              c.Signal_Name__c,
              WorkflowPayloadOffload.resolvePayload(c.Payload__c)
            )
            .withCreatedDate(c.CreatedDate);
        }
        // Try to claim each candidate newest-first; if a sibling wins the race on
        // the newest row, fall back to the next-newest still-Received row instead
        // of reporting absence while a matching signal is still available.
        for (Workflow_Signal__c cand : candidates) {
          StepContext.Signal claimed = tryClaimOneLatestSignal(cand);
          if (claimed != null) {
            return claimed;
          }
        }
        // Every candidate in this page was claimed by a sibling between query and
        // lock; those rows are now Processing and drop out of the next query, so
        // re-page to consider rows beyond the first 10.
      }
      // Could not claim a matching row within the retry budget (siblings own the
      // visible matches). Mark capped so consume skips same-name cleanup.
      capped = true;
      return null;
    }

    /**
     * @description Attempts to atomically claim a single candidate signal
     * (Received to Processing) by FOR UPDATE-locking its id and, if it
     * survives, marking it Processing and issuing a single-row DML update.
     * The FOR UPDATE query and the follow-on update run inside this one
     * helper call so they stay in the same transaction context and remain
     * atomic. Debits the caller's claim row and statement budgets by one on
     * success.
     *
     * The per-candidate SOQL FOR UPDATE + DML update is intentional and
     * bounded: the caller iterates a page of at most 10 candidates and
     * returns immediately on the first successful claim, so this helper is
     * called at most 10 times per retry attempt.
     * @param cand the candidate row this branch attempts to claim
     * @return the claimed `StepContext.Signal` on success, or null when a
     *   sibling won the race so the caller should fall back to the next
     *   candidate
     */
    private StepContext.Signal tryClaimOneLatestSignal(
      Workflow_Signal__c cand
    ) {
      Id targetId = cand.Id;
      List<Workflow_Signal__c> locked = [
        SELECT Id
        FROM Workflow_Signal__c
        WHERE Id = :targetId AND Status__c = 'Received'
        WITH SYSTEM_MODE
        FOR UPDATE
      ];
      if (locked.isEmpty()) {
        return null; // lost the race on this row; try the next-newest
      }
      locked[0].Status__c = 'Processing';
      Database.update(locked[0], true, AccessLevel.SYSTEM_MODE);
      claimBudget -= 1;
      claimStatementBudget -= 1;
      // claimed = true: this branch now exclusively owns the row.
      return new StepContext.Signal(
          cand.Id,
          cand.Signal_Name__c,
          WorkflowPayloadOffload.resolvePayload(cand.Payload__c)
        )
        .withCreatedDate(cand.CreatedDate)
        .asClaimed();
    }
  }

  /**
   * @description Fetches the newest-first candidate page of Received signals
   * of the given name for the given instance, limited to 10 rows. Kept as a
   * top-level static helper so the per-attempt SOQL is not lexically inside
   * `ParallelBranchSignalSource.getLatestSignal`'s retry loop. The
   * per-attempt query is intentional and bounded: the caller retries at most
   * `PARALLEL_CLAIM_PAGE_RETRIES + 1` times and returns immediately on the
   * first successful claim.
   * @param instanceId workflow instance whose signals are being paged
   * @param signalName the signal name to page (assumed non-blank; caller
   *   short-circuits on blank)
   * @return up to 10 candidate rows in newest-first order
   */
  private static List<Workflow_Signal__c> queryLatestSignalCandidates(
    Id instanceId,
    String signalName
  ) {
    return [
      SELECT Id, Signal_Name__c, Payload__c, CreatedDate
      FROM Workflow_Signal__c
      WHERE
        Workflow_Instance__c = :instanceId
        AND Status__c = 'Received'
        AND Signal_Name__c = :signalName
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC, Id DESC
      LIMIT 10
    ];
  }

  /**
   * @description Loads only the single most-recent pending signal matching a
   * name, so a step reading one decision via getSignal/hasSignal does not pull
   * every duplicate payload (consumption still re-queries by name, without
   * payloads). Returns null when no matching Received signal exists.
   * @param instanceId Id of the instance whose signals are read
   * @param signalName name of the signal to load
   * @return the most-recent matching Received signal, or null when none exists
   */
  private static StepContext.Signal loadLatestSignal(
    Id instanceId,
    String signalName
  ) {
    if (String.isBlank(signalName)) {
      return null;
    }
    List<Workflow_Signal__c> records = [
      SELECT Id, Signal_Name__c, Payload__c, CreatedDate
      FROM Workflow_Signal__c
      WHERE
        Workflow_Instance__c = :instanceId
        AND Status__c = 'Received'
        AND Signal_Name__c = :signalName
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC, Id DESC
      LIMIT 1
    ];
    if (records.isEmpty()) {
      return null;
    }
    return new StepContext.Signal(
        records[0].Id,
        records[0].Signal_Name__c,
        WorkflowPayloadOffload.resolvePayload(records[0].Payload__c)
      )
      .withCreatedDate(records[0].CreatedDate);
  }

  /**
   * @description Loads the pending (unconsumed) signals targeting an instance as
   * read-only StepContext.Signal views, in deterministic arrival order. A
   * non-blank signalName scopes the query (and its payload heap cost) to that one
   * name so a single named accessor never pulls every pending payload on the
   * instance; a blank name loads them all. Bounded by rowLimit so a serial step
   * never observes (and marks consumed) more rows than the COMPLETE consume pass
   * can handle. Cancel control signals are handled inline by signal() and never
   * persist a Workflow_Signal__c record, so they are structurally excluded here.
   * @param instanceId Id of the instance whose signals are read
   * @param signalName name to scope the read to, or blank to load all names
   * @param rowLimit maximum rows to read (falls back to serialSignalRowCap)
   * @return the pending signals in arrival order, up to the effective limit
   */
  private static List<StepContext.Signal> loadPendingSignals(
    Id instanceId,
    String signalName,
    Integer rowLimit
  ) {
    Integer effectiveLimit = (rowLimit != null &&
      rowLimit > 0)
      ? rowLimit
      : serialSignalRowCap;
    List<Workflow_Signal__c> records;
    if (String.isBlank(signalName)) {
      records = [
        SELECT Id, Signal_Name__c, Payload__c, CreatedDate
        FROM Workflow_Signal__c
        WHERE Workflow_Instance__c = :instanceId AND Status__c = 'Received'
        WITH SYSTEM_MODE
        ORDER BY CreatedDate ASC, Id ASC
        LIMIT :effectiveLimit
      ];
    } else {
      records = [
        SELECT Id, Signal_Name__c, Payload__c, CreatedDate
        FROM Workflow_Signal__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Status__c = 'Received'
          AND Signal_Name__c = :signalName
        WITH SYSTEM_MODE
        ORDER BY CreatedDate ASC, Id ASC
        LIMIT :effectiveLimit
      ];
    }

    List<String> rawPayloads = new List<String>();
    for (Workflow_Signal__c sig : records) {
      rawPayloads.add(sig.Payload__c);
    }
    // Resolve any offloaded payloads with a single bulk query (not one per row).
    List<String> resolvedPayloads = WorkflowPayloadOffload.resolvePayloads(
      rawPayloads
    );

    List<StepContext.Signal> signals = new List<StepContext.Signal>();
    for (Integer i = 0; i < records.size(); i++) {
      signals.add(
        new StepContext.Signal(
            records[i].Id,
            records[i].Signal_Name__c,
            resolvedPayloads[i]
          )
          .withCreatedDate(records[i].CreatedDate)
      );
    }
    return signals;
  }
}
