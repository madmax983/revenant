/**
 * @description Read API for a Continue-As-New chain (issue #116). Gives the
 * generations of a chain as one list, newest first, with a keyset cursor.
 * An Id of each member of a chain gives the same result.
 * {@link WorkflowChainWindow} sets the membership.
 *
 * <p>Cost: max 5 SOQL, for all chain lengths. One SOQL for a single
 * generation. No DML, no enqueue, no event. No long text field.</p>
 *
 * <p>Limit: an independent run that uses the root key while the chain is not
 * closed splits the chain. `getStatus` has a related limit.</p>
 */
public inherited sharing class WorkflowChainRead {
  /** @description Page size when `ChainRequest.pageSize` is null. */
  public static final Integer DEFAULT_PAGE_SIZE = 50;

  /** @description Max page size. The read uses this value for a larger value. */
  public static final Integer MAX_PAGE_SIZE = 200;

  /**
   * @description Max generations that the total counts. Above this value,
   * `ChainPage.isTotalCapped` is true and `generation` is null.
   */
  public static final Integer MAX_COUNTED_GENERATIONS = 50000;

  // Tests set a small cap to test the capped path.
  @TestVisible
  private static Integer countCap = MAX_COUNTED_GENERATIONS;

  private static final String FIELDS =
    'Id, Name, Workflow_Name__c, Correlation_Key__c, Root_Correlation_Key__c, ' +
    'Status__c, CreatedDate, Terminal_At__c, Failure_Category__c, ' +
    'Error_Message__c, Previous_Instance__c';

  /**
   * @description Gives the first page of the chain of an instance.
   * @param instanceId Id of a generation
   * @return the first page, or null when no instance has that Id
   */
  public static WorkflowEngine.ChainPage getChain(Id instanceId) {
    WorkflowEngine.ChainRequest request = new WorkflowEngine.ChainRequest();
    request.instanceId = instanceId;
    return getChain(request);
  }

  /**
   * @description Gives the first page of the chain of the newest instance with
   * this correlation key or root key.
   * @param correlationKey the key
   * @return the first page, or null when no instance has that key
   */
  public static WorkflowEngine.ChainPage getChain(String correlationKey) {
    WorkflowEngine.ChainRequest request = new WorkflowEngine.ChainRequest();
    request.correlationKey = correlationKey;
    return getChain(request);
  }

  /**
   * @description Gives one page of a chain, newest first. With a cursor, the
   * read uses the chain of the first page.
   * @param request Id or key, page size and cursor
   * @return the page, or null when the request is null, empty or unknown
   * @throws WorkflowEngine.WorkflowException when the request sets both Id and
   * key, the page size is zero or less, or the cursor is bad
   */
  public static WorkflowEngine.ChainPage getChain(
    WorkflowEngine.ChainRequest request
  ) {
    if (!hasInput(request)) {
      return null;
    }
    Chain chain = new Chain();
    chain.pageSize = resolvePageSize(request.pageSize);
    chain.cursor = WorkflowChainCursor.decode(request.cursor);
    Workflow_Instance__c anchor = chain.cursor != null
      ? anchorById(chain.cursor.anchorId)
      : resolveAnchor(request);
    if (anchor == null) {
      return null;
    }
    chain.anchorId = anchor.Id;
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
   * @description True when the request sets an Id or a key.
   * @param request the request, or null
   * @return true when there is input to read
   * @throws WorkflowEngine.WorkflowException when both are set
   */
  private static Boolean hasInput(WorkflowEngine.ChainRequest request) {
    if (request == null) {
      return false;
    }
    Boolean hasKey = String.isNotBlank(request.correlationKey);
    if (request.instanceId != null && hasKey) {
      throw new WorkflowEngine.WorkflowException(
        'Set instanceId or correlationKey, not both.'
      );
    }
    return request.instanceId != null || hasKey;
  }

  /**
   * @description Reads the anchor of a first page: by key or by Id.
   * @param request request with an Id or a key
   * @return the anchor, or null
   */
  private static Workflow_Instance__c resolveAnchor(
    WorkflowEngine.ChainRequest request
  ) {
    return String.isNotBlank(request.correlationKey)
      ? anchorByKey(request.correlationKey.trim())
      : anchorById(request.instanceId);
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
   * @description Reads the anchor by Id. The child subquery finds a successor
   * in the same SOQL.
   * @param instanceId the Id
   * @return the anchor, or null
   */
  private static Workflow_Instance__c anchorById(Id instanceId) {
    List<Workflow_Instance__c> rows = [
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
    return rows.isEmpty() ? null : rows[0];
  }

  /**
   * @description Reads the newest row with this correlation key or root key.
   * @param key the trimmed key
   * @return the anchor, or null
   */
  private static Workflow_Instance__c anchorByKey(String key) {
    List<Workflow_Instance__c> rows = [
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
      WHERE Correlation_Key__c = :key OR Root_Correlation_Key__c = :key
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC, Id DESC
      LIMIT 1
    ];
    return rows.isEmpty() ? null : rows[0];
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
   * (max 2 for the window, 1 count, 1 page).
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
   * @description Makes the page. Each row gets a generation 1 less than the
   * row above it.
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
      ? WorkflowChainCursor.encode(
          chain.anchorId,
          rows[take - 1],
          lastGeneration
        )
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
    private Id anchorId;
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
