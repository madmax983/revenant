/**
 * @description Supported, read-only, paginated enumeration API for the Revenant
 * engine. Answers "which instances match?" — the list complement to
 * {@link WorkflowStatusRead#getStatus} (which answers "what is the outcome of the
 * instance I already hold a key/Id for?"). Callers filter `Workflow_Instance__c`
 * rows by definition name, status set, and created/modified time windows, and page
 * through the matches with an opaque keyset cursor, receiving lightweight,
 * payload-free `WorkflowEngine.WorkflowInstanceSummary` rows on a
 * `WorkflowEngine.InstancePage`. This lets ISVs and operator-automation authors
 * discover instances without hard-coding the internal `Workflow_Instance__c` field
 * or relationship API names the README forbids querying directly.
 *
 * <p>Strictly read-only: exactly <b>one</b> SOQL query per call and zero DML,
 * regardless of page size or how many instances match the criteria. The projection
 * is payload-free — it never selects the long-text `Input__c` / `Output__c` /
 * `Progress__c` / `Compensation_Stack__c` fields, so a list call never materializes
 * an offloaded-output storage pointer or exhausts the heap in bulk. Fetch a
 * winner's full output per-Id via {@link WorkflowStatusRead#getStatus}.</p>
 *
 * <p><b>Deep pagination is keyset-based, not OFFSET-based.</b> SOQL `OFFSET` is
 * capped at 2,000 rows by the platform and throws beyond it, so a definition with
 * millions of historical instances could not be paged past that with OFFSET. This
 * API instead orders by the stable total ordering `CreatedDate DESC, Id DESC` and
 * pages via a keyset predicate on `(CreatedDate, Id)`, so a caller can walk the
 * entire result set — however deep — one bounded page at a time. The cursor is an
 * <b>opaque</b> string: pass a page's `nextCursor` back verbatim to fetch the next
 * page; do not parse, construct, or mutate it.</p>
 *
 * <p><b>ContinueAsNew stance (consistent with {@link WorkflowStatusRead}).</b> This
 * is a raw row enumeration, not a chain resolution: it returns each matching
 * `Workflow_Instance__c` row on its own, and does <b>not</b> collapse a
 * continue-as-new chain to a single winner the way `getStatus(correlationKey)`
 * does. A `ContinuedAsNew` predecessor generation is therefore its own row and is
 * returned only when the `statuses` filter admits it (i.e. is unset/empty, or
 * explicitly includes `ContinuedAsNew`). Consistent with `getStatus`,
 * `ContinuedAsNew` is treated as a non-terminal hand-off, so such a summary's
 * `isTerminal` is `false` (the terminal set is
 * {@link WorkflowStatusRead#TERMINAL_GETSTATUS_STATUSES}). To resolve a chain to
 * its live/final successor, take a matching row's `correlationKey` and call
 * `getStatus(correlationKey)`.</p>
 */
public inherited sharing class WorkflowInstanceQuery {
  /**
   * @description Page size used when a caller leaves `InstanceCriteria.pageSize`
   * null. Public so callers can size their own UX against the documented default.
   */
  public static final Integer DEFAULT_PAGE_SIZE = 50;

  /**
   * @description Hard ceiling on a single page's size. A larger requested
   * `InstanceCriteria.pageSize` is <b>clamped</b> to this value (never an error);
   * the effective size applied is echoed back on `InstancePage.pageSize`. This
   * bounds the per-call SOQL row and heap budget no matter what a caller asks for.
   * Public so callers can size their own paging against the documented cap.
   */
  public static final Integer MAX_PAGE_SIZE = 200;

  /**
   * @description Enumerates the workflow instances matching `criteria`, newest
   * first (`CreatedDate DESC, Id DESC`), as one bounded, payload-free page. A null
   * `criteria` (or one with every filter unset) matches all instances. Costs
   * exactly one SOQL query and zero DML.
   *
   * <p>Filtering semantics (each filter is independent and AND-combined):</p>
   * <ul>
   *   <li><b>definitionName</b> — null/blank matches any definition; otherwise an
   *   exact `Workflow_Name__c` match.</li>
   *   <li><b>statuses</b> — null/empty matches any status; otherwise `Status__c`
   *   must be one of the set.</li>
   *   <li><b>createdAfter / createdBefore</b> — null bounds are unbounded. The
   *   window is half-open `[after, before)`: the after bound is inclusive
   *   (`CreatedDate &gt;= createdAfter`) and the before bound is exclusive
   *   (`CreatedDate &lt; createdBefore`), so adjacent windows compose without
   *   overlap.</li>
   *   <li><b>modifiedAfter / modifiedBefore</b> — same half-open
   *   inclusive-after / exclusive-before semantics against `LastModifiedDate`.</li>
   * </ul>
   *
   * @param criteria the filter + pagination criteria (null = match all, first page)
   * @return a page of lightweight instance summaries plus the next-page cursor
   * (`nextCursor` null and `hasMore` false on the last page)
   * @throws WorkflowEngine.WorkflowException when `criteria.pageSize` is
   * non-positive, or `criteria.cursor` is present but not a cursor previously
   * returned by this API (garbage/tampered)
   */
  public static WorkflowEngine.InstancePage findInstances(
    WorkflowEngine.InstanceCriteria criteria
  ) {
    WorkflowEngine.InstanceCriteria effective = criteria == null
      ? new WorkflowEngine.InstanceCriteria()
      : criteria;

    Integer pageSize = resolvePageSize(effective.pageSize);
    Cursor cursor = decodeCursor(effective.cursor);

    // Fetch one extra row (pageSize + 1) so we can tell whether a further page
    // exists — and therefore whether to emit a nextCursor — without a second query
    // or a COUNT. The extra row is dropped from the returned page.
    List<Workflow_Instance__c> rows = queryPage(
      effective,
      pageSize + 1,
      cursor
    );

    return buildPage(rows, pageSize);
  }

  /**
   * @description Resolves the effective page size from a caller-supplied value:
   * null falls back to {@link #DEFAULT_PAGE_SIZE}; a value above
   * {@link #MAX_PAGE_SIZE} is clamped down to the cap; a non-positive value is a
   * caller error and throws. Never returns a value outside `1..MAX_PAGE_SIZE`.
   * @param requested the raw `InstanceCriteria.pageSize` (may be null)
   * @return the effective page size, in `1..MAX_PAGE_SIZE`
   * @throws WorkflowEngine.WorkflowException when `requested` is &lt;= 0
   */
  private static Integer resolvePageSize(Integer requested) {
    if (requested == null) {
      return DEFAULT_PAGE_SIZE;
    }
    if (requested <= 0) {
      throw new WorkflowEngine.WorkflowException(
        'pageSize must be a positive integer (1 to ' +
          MAX_PAGE_SIZE +
          '); received ' +
          requested +
          '. Leave it null to use the default of ' +
          DEFAULT_PAGE_SIZE +
          '.'
      );
    }
    return requested > MAX_PAGE_SIZE ? MAX_PAGE_SIZE : requested;
  }

  /**
   * @description Runs the single page query with `Database.queryWithBinds`. Every
   * caller-supplied value reaches SOQL only through a named bind in `binds` (never
   * through string concatenation), so criteria values can never inject SOQL; the
   * WHERE body is composed from string literals in {@link #buildWhere}. The
   * projection is deliberately payload-free — it selects only lightweight scalar
   * fields, never a long-text (`Input__c` / `Output__c` / `Progress__c` /
   * `Compensation_Stack__c`) field — so the read stays heap-bounded. The stable
   * `CreatedDate DESC, Id DESC` total ordering (with the keyset predicate when a
   * cursor is supplied) guarantees no duplicate or skipped row across pages.
   * @param criteria the filter criteria (pagination resolved by the caller)
   * @param fetchLimitSize the SOQL LIMIT (page size plus one probe row)
   * @param cursor the decoded keyset cursor, or null for the first page
   * @return the matching rows, newest first, at most `fetchLimitSize` of them
   */
  private static List<Workflow_Instance__c> queryPage(
    WorkflowEngine.InstanceCriteria criteria,
    Integer fetchLimitSize,
    Cursor cursor
  ) {
    Map<String, Object> binds = new Map<String, Object>{
      'fetchLimitSize' => fetchLimitSize
    };
    String whereClause = buildWhere(criteria, cursor, binds);

    String soql =
      'SELECT Id, Workflow_Name__c, Correlation_Key__c, Status__c, CreatedDate, LastModifiedDate ' +
      'FROM Workflow_Instance__c';
    if (String.isNotBlank(whereClause)) {
      soql += ' WHERE ' + whereClause;
    }
    soql += ' ORDER BY CreatedDate DESC, Id DESC LIMIT :fetchLimitSize';

    return Database.queryWithBinds(soql, binds, AccessLevel.SYSTEM_MODE);
  }

  /**
   * @description Composes the WHERE body from guard-driven, all-literal clause
   * fragments and populates `binds` with each active filter's value (mirroring the
   * bound-clause pattern of {@link BulkWorkflowSelector}). A blank/null filter is
   * simply omitted, so an all-unset criteria yields an empty clause (match all).
   * Every value is bound — nothing caller-supplied is concatenated into SOQL. The
   * keyset predicate selects everything strictly "after" the cursor row in the
   * `CreatedDate DESC, Id DESC` ordering, with the Id tie-breaker so rows sharing a
   * `CreatedDate` are still totally ordered (no duplicates, no gaps across pages).
   * Exposed to tests through {@link #buildWhereForTest} to pin the bound operators.
   * @param criteria the filter criteria supplying the optional predicates
   * @param cursor the decoded keyset cursor to append, or null to omit it
   * @param binds the bind map to populate; mutated in place with each clause's value
   * @return the composed WHERE body (without the leading `WHERE`), blank when no
   * filter is set
   */
  private static String buildWhere(
    WorkflowEngine.InstanceCriteria criteria,
    Cursor cursor,
    Map<String, Object> binds
  ) {
    List<String> clauses = new List<String>();
    if (String.isNotBlank(criteria.definitionName)) {
      binds.put('definitionName', criteria.definitionName);
      clauses.add('Workflow_Name__c = :definitionName');
    }
    if (criteria.statuses != null && !criteria.statuses.isEmpty()) {
      binds.put('statusFilter', criteria.statuses);
      clauses.add('Status__c IN :statusFilter');
    }
    if (criteria.createdAfter != null) {
      binds.put('createdAfter', criteria.createdAfter);
      clauses.add('CreatedDate >= :createdAfter');
    }
    if (criteria.createdBefore != null) {
      binds.put('createdBefore', criteria.createdBefore);
      clauses.add('CreatedDate < :createdBefore');
    }
    if (criteria.modifiedAfter != null) {
      binds.put('modifiedAfter', criteria.modifiedAfter);
      clauses.add('LastModifiedDate >= :modifiedAfter');
    }
    if (criteria.modifiedBefore != null) {
      binds.put('modifiedBefore', criteria.modifiedBefore);
      clauses.add('LastModifiedDate < :modifiedBefore');
    }
    if (cursor != null) {
      binds.put('cursorCreated', cursor.createdAt);
      binds.put('cursorId', cursor.id);
      clauses.add(
        '(CreatedDate < :cursorCreated OR (CreatedDate = :cursorCreated AND Id < :cursorId))'
      );
    }
    return String.join(clauses, ' AND ');
  }

  /**
   * @description `@TestVisible` seam returning the composed WHERE body for a
   * criteria (no keyset cursor, throwaway bind map), so a unit test can pin the
   * exact comparison operator of each of the four time-window bounds
   * (inclusive-after `&gt;=` / exclusive-before `&lt;`) directly against the
   * generated clause text. This is the only way to assert the half-open contract
   * for the modified window, because Apex cannot set a real `LastModifiedDate` to
   * exercise it end-to-end. Wraps {@link #buildWhere} rather than exposing it
   * directly so no test needs to name the private `Cursor` type. Not a
   * suppression — `@TestVisible` is an accepted repo convention.
   * @param criteria the filter criteria to compose predicates from
   * @return the composed WHERE body (without the leading `WHERE`)
   */
  @TestVisible
  private static String buildWhereForTest(
    WorkflowEngine.InstanceCriteria criteria
  ) {
    return buildWhere(criteria, null, new Map<String, Object>());
  }

  /**
   * @description Projects the fetched rows into an `InstancePage`. The query
   * fetched `pageSize + 1` rows: if more than `pageSize` came back, at least one
   * further page exists, so the extra row is dropped and a `nextCursor` is minted
   * from the last retained row; otherwise this is the final page and `nextCursor`
   * is null. The page DTO derives `hasMore` from `nextCursor`, keeping the two
   * consistent by construction.
   * @param rows the fetched rows (up to `pageSize + 1`), newest first
   * @param pageSize the effective page size (rows beyond it signal a further page)
   * @return the assembled page
   */
  private static WorkflowEngine.InstancePage buildPage(
    List<Workflow_Instance__c> rows,
    Integer pageSize
  ) {
    Boolean hasMore = rows.size() > pageSize;
    Integer take = hasMore ? pageSize : rows.size();

    List<WorkflowEngine.WorkflowInstanceSummary> entries = new List<WorkflowEngine.WorkflowInstanceSummary>();
    for (Integer i = 0; i < take; i++) {
      entries.add(new WorkflowEngine.WorkflowInstanceSummary(rows[i]));
    }

    String nextCursor = hasMore ? encodeCursor(rows[take - 1]) : null;
    return new WorkflowEngine.InstancePage(entries, nextCursor, pageSize);
  }

  /**
   * @description Encodes an opaque, base64 keyset cursor from a row's sort key
   * (`CreatedDate` as epoch milliseconds) and its `Id` tie-breaker. The format is
   * an internal detail — callers must treat the returned string as opaque and pass
   * it back verbatim.
   * @param row the last row of the current page, whose position the cursor marks
   * @return the opaque cursor string
   */
  private static String encodeCursor(Workflow_Instance__c row) {
    Map<String, Object> payload = new Map<String, Object>{
      'c' => row.CreatedDate.getTime(),
      'i' => String.valueOf(row.Id)
    };
    return EncodingUtil.base64Encode(Blob.valueOf(JSON.serialize(payload)));
  }

  /**
   * @description Decodes an opaque cursor previously produced by
   * {@link #encodeCursor} back into its `(CreatedDate, Id)` keyset position. A
   * null/blank cursor means "start from the first page" and returns null. Any other
   * value that is not a well-formed cursor this API produced — a truncated,
   * tampered, or foreign string — is a caller error and throws, rather than
   * silently returning wrong-page results.
   * @param cursor the opaque cursor string (may be null/blank for the first page)
   * @return the decoded cursor, or null for the first page
   * @throws WorkflowEngine.WorkflowException when `cursor` is non-blank but not a
   * cursor this API produced
   */
  private static Cursor decodeCursor(String cursor) {
    if (String.isBlank(cursor)) {
      return null;
    }
    try {
      String decodedJson = EncodingUtil.base64Decode(cursor).toString();
      Map<String, Object> payload = (Map<String, Object>) JSON.deserializeUntyped(
        decodedJson
      );
      Long millis = Long.valueOf(String.valueOf(payload.get('c')));
      Id rowId = (Id) String.valueOf(payload.get('i'));
      Cursor decoded = new Cursor();
      decoded.createdAt = Datetime.newInstance(millis);
      decoded.id = rowId;
      return decoded;
    } catch (Exception decodeError) {
      throw new WorkflowEngine.WorkflowException(
        'Invalid pagination cursor. Pass back the nextCursor from a previous ' +
          'findInstances page verbatim, or leave it null to start from the first ' +
          'page. (' +
          decodeError.getMessage() +
          ')'
      );
    }
  }

  /**
   * @description In-memory decoded keyset position: the `CreatedDate` sort key and
   * the `Id` tie-breaker of the row a cursor marks. Instance-only (no static
   * members); used solely to carry the decoded cursor from {@link #decodeCursor}
   * into {@link #queryPage}.
   */
  private class Cursor {
    private Datetime createdAt;
    private Id id;
  }
}
