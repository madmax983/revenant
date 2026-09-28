/**
 * @description Read API for a Continue-As-New chain (issue #116). Gives the
 * generations of a chain as one list, newest first, with a keyset cursor.
 * Each member of a chain gives the same result. {@link WorkflowChainWindow}
 * sets the membership.
 *
 * <p>Cost: max 6 SOQL, for all chain lengths. One SOQL for a single
 * generation. No DML, no enqueue, no event. No long text field.</p>
 *
 * <p>Limit: a run that uses the root key again while the chain is live mixes
 * the two chains. This is the same limit as `getStatus`.</p>
 */
public inherited sharing class WorkflowChainRead {
  /** @description Page size when `ChainRequest.pageSize` is null. */
  public static final Integer DEFAULT_PAGE_SIZE = 50;

  /** @description Max page size. A larger value is clamped. */
  public static final Integer MAX_PAGE_SIZE = 200;

  /**
   * @description Max generations that the total counts. Above this value,
   * `ChainPage.isTotalCapped` is true and `generation` is null.
   */
  public static final Integer MAX_COUNTED_GENERATIONS = 50000;

  // Test hook: a small cap exercises the capped path.
  @TestVisible
  private static Integer countCap = MAX_COUNTED_GENERATIONS;

  private static final String FIELDS =
    'Id, Name, Workflow_Name__c, Correlation_Key__c, Root_Correlation_Key__c, ' +
    'Status__c, CreatedDate, Terminal_At__c, Failure_Category__c, ' +
    'Error_Message__c, Previous_Instance__c';

  /**
   * @description Gives the first page of the chain of a generation.
   * @param keyOrId instance Id or correlation key of any generation
   * @return the first page, or null when no instance matches
   */
  public static WorkflowEngine.ChainPage getChain(String keyOrId) {
    WorkflowEngine.ChainRequest request = new WorkflowEngine.ChainRequest();
    request.keyOrId = keyOrId;
    return getChain(request);
  }

  /**
   * @description Gives one page of the chain of a generation, newest first.
   * An Id-shaped value reads that instance. Else (or when no instance has that
   * Id) the value is a key: the newest row with that correlation key or root
   * key is the anchor.
   * @param request key or Id, page size and cursor
   * @return the page, or null when the request is null, blank or unknown
   * @throws WorkflowEngine.WorkflowException when the page size is zero or
   * less, or the cursor is bad
   */
  public static WorkflowEngine.ChainPage getChain(
    WorkflowEngine.ChainRequest request
  ) {
    if (request == null || String.isBlank(request.keyOrId)) {
      return null;
    }
    Chain chain = new Chain();
    chain.pageSize = resolvePageSize(request.pageSize);
    chain.cursor = WorkflowChainCursor.decode(request.cursor);
    Workflow_Instance__c anchor = resolveAnchor(request.keyOrId.trim());
    if (anchor == null) {
      return null;
    }
    chain.root = rootKeyOf(anchor);
    if (isSingleGeneration(anchor, chain.root)) {
      // The only row is on the first page. A cursor points past it.
      return buildPage(
        chain.cursor == null
          ? new List<Workflow_Instance__c>{ anchor }
          : new List<Workflow_Instance__c>(),
        chain
      );
    }
    return readWindow(anchor, chain);
  }

  /**
   * @description Null gives the default. Above the max gives the max.
   * @param requested caller page size, or null
   * @return page size in 1..MAX_PAGE_SIZE
   * @throws WorkflowEngine.WorkflowException when zero or less
   */
  private static Integer resolvePageSize(Integer requested) {
    if (requested == null) {
      return DEFAULT_PAGE_SIZE;
    }
    if (requested <= 0) {
      throw new WorkflowEngine.WorkflowException(
        'pageSize must be 1 to ' +
          MAX_PAGE_SIZE +
          '; received ' +
          requested +
          '. Leave it null for ' +
          DEFAULT_PAGE_SIZE +
          '.'
      );
    }
    return Math.min(requested, MAX_PAGE_SIZE);
  }

  /**
   * @description Reads the anchor row. Id first, then key. The child subquery
   * finds a successor in the same SOQL.
   * @param keyOrId trimmed Id or key
   * @return the anchor, or null
   */
  private static Workflow_Instance__c resolveAnchor(String keyOrId) {
    Id instanceId = toInstanceId(keyOrId);
    if (instanceId != null) {
      List<Workflow_Instance__c> byId = [
        SELECT
          Id,
          Name,
          Workflow_Name__c,
          Correlation_Key__c,
          Root_Correlation_Key__c,
          Status__c,
          CreatedDate,
          Terminal_At__c,
          Failure_Category__c,
          Error_Message__c,
          Previous_Instance__c,
          (SELECT Id FROM Next_Runs__r LIMIT 1)
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
        WITH SYSTEM_MODE
        LIMIT 1
      ];
      if (!byId.isEmpty()) {
        return byId[0];
      }
    }
    List<Workflow_Instance__c> byKey = [
      SELECT
        Id,
        Name,
        Workflow_Name__c,
        Correlation_Key__c,
        Root_Correlation_Key__c,
        Status__c,
        CreatedDate,
        Terminal_At__c,
        Failure_Category__c,
        Error_Message__c,
        Previous_Instance__c,
        (SELECT Id FROM Next_Runs__r LIMIT 1)
      FROM Workflow_Instance__c
      WHERE Correlation_Key__c = :keyOrId OR Root_Correlation_Key__c = :keyOrId
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC, Id DESC
      LIMIT 1
    ];
    return byKey.isEmpty() ? null : byKey[0];
  }

  /**
   * @description Converts an Id-shaped value to a `Workflow_Instance__c` Id.
   * @param value trimmed input
   * @return the Id, or null when the value is not an instance Id
   */
  private static Id toInstanceId(String value) {
    Boolean idShaped =
      (value.length() == 15 || value.length() == 18) && value.isAlphanumeric();
    if (!idShaped) {
      return null;
    }
    try {
      Id candidate = Id.valueOf(value);
      return candidate.getSobjectType() == Workflow_Instance__c.SObjectType
        ? candidate
        : null;
    } catch (StringException notAnId) {
      return null;
    }
  }

  /**
   * @description Root key of a row. A legacy row with a blank root uses its own
   * correlation key (same fallback as `WorkflowContinueAsNew`).
   * @param row the anchor
   * @return the root key, or null when both are blank
   */
  private static String rootKeyOf(Workflow_Instance__c row) {
    return String.isNotBlank(row.Root_Correlation_Key__c)
      ? row.Root_Correlation_Key__c
      : row.Correlation_Key__c;
  }

  /**
   * @description True when the anchor has no predecessor and no successor, or
   * has no root key to match.
   * @param anchor the anchor with its `Next_Runs__r` subquery
   * @param root the root key of the anchor
   * @return true for a single generation
   */
  private static Boolean isSingleGeneration(
    Workflow_Instance__c anchor,
    String root
  ) {
    return String.isBlank(root) ||
      (anchor.Previous_Instance__c == null && anchor.Next_Runs__r.isEmpty());
  }

  /**
   * @description Counts the window, then reads one page of it. Max 4 SOQL
   * (2 for the window, 1 count, 1 page).
   * @param anchor the anchor
   * @param chain the read state; this method sets the total
   * @return the page
   */
  private static WorkflowEngine.ChainPage readWindow(
    Workflow_Instance__c anchor,
    Chain chain
  ) {
    Map<String, Object> binds = new Map<String, Object>();
    String window = WorkflowChainWindow.clause(anchor, chain.root, binds);

    // COUNT() uses one query row. LIMIT stops the scan after the cap.
    binds.put('cap', countCap + 1);
    Integer counted = Database.countQueryWithBinds(
      'SELECT COUNT() FROM Workflow_Instance__c WHERE ' +
        window +
        ' LIMIT :cap',
      binds,
      AccessLevel.SYSTEM_MODE
    );
    chain.capped = counted > countCap;
    chain.total = Math.min(counted, countCap);

    String pageWhere = chain.cursor == null
      ? window
      : window + ' AND ' + chain.cursor.olderClause(binds);
    binds.put('fetch', chain.pageSize + 1);
    List<Workflow_Instance__c> rows = Database.queryWithBinds(
      'SELECT ' +
        FIELDS +
        ' FROM Workflow_Instance__c WHERE ' +
        pageWhere +
        ' ORDER BY CreatedDate DESC, Id DESC LIMIT :fetch',
      binds,
      AccessLevel.SYSTEM_MODE
    );
    return buildPage(rows, chain);
  }

  /**
   * @description Makes the page. Each row gets 1 less than the row above it.
   * The extra row (pageSize + 1) only sets the next cursor.
   * @param rows rows newest first, max pageSize + 1
   * @param chain the read state
   * @return the page
   */
  private static WorkflowEngine.ChainPage buildPage(
    List<Workflow_Instance__c> rows,
    Chain chain
  ) {
    Integer take = Math.min(rows.size(), chain.pageSize);
    Integer top = chain.topGeneration();
    List<WorkflowEngine.ChainGeneration> entries = new List<WorkflowEngine.ChainGeneration>();
    Integer lastGeneration = null;
    for (Integer i = 0; i < take; i++) {
      lastGeneration = (top == null || top - i < 1) ? null : top - i;
      entries.add(new WorkflowEngine.ChainGeneration(rows[i], lastGeneration));
    }
    String nextCursor = rows.size() > chain.pageSize
      ? WorkflowChainCursor.encode(rows[take - 1], lastGeneration)
      : null;
    return new WorkflowEngine.ChainPage(
      entries,
      chain.root,
      chain.total,
      chain.capped,
      nextCursor,
      chain.pageSize
    );
  }

  /**
   * @description State of one read.
   */
  private class Chain {
    private String root;
    private Integer pageSize;
    private WorkflowChainCursor cursor;
    private Integer total = 1;
    private Boolean capped = false;

    /**
     * @description Generation of the top row: the total on the first page, or
     * the cursor generation minus 1. Null when not known.
     * @return the generation, or null
     */
    private Integer topGeneration() {
      if (cursor != null) {
        return cursor.generation == null ? null : cursor.generation - 1;
      }
      return capped ? null : total;
    }
  }
}
