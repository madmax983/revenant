/**
 * @description Dashboard view of a Continue-As-New chain (issue #116). Maps
 * {@link WorkflowChainRead} pages to plain maps for the LWC. Read-only.
 */
public inherited sharing class WorkflowDashboardChainService {
  // Tests set a small page size to test the cursor.
  @TestVisible
  private static Integer pageSize = WorkflowChainRead.DEFAULT_PAGE_SIZE;

  /**
   * @description Loads one page of the chain of an instance.
   * @param instanceId any generation of the chain
   * @param cursor `nextCursor` of the previous page, or null
   * @return the page as a map, or null when the instance is unknown
   */
  public static Map<String, Object> loadChain(Id instanceId, String cursor) {
    WorkflowDashboardSupport.checkAuthorization();
    if (instanceId == null) {
      throw auraError('instanceId is required.');
    }
    WorkflowEngine.ChainRequest request = new WorkflowEngine.ChainRequest();
    request.instanceId = instanceId;
    request.pageSize = pageSize;
    request.cursor = cursor;
    WorkflowEngine.ChainPage page;
    try {
      page = WorkflowChainRead.getChain(request);
    } catch (WorkflowEngine.WorkflowException ex) {
      throw auraError(ex.getMessage());
    }
    return page == null ? null : toView(page);
  }

  private static Map<String, Object> toView(WorkflowEngine.ChainPage page) {
    List<Map<String, Object>> rows = new List<Map<String, Object>>();
    for (WorkflowEngine.ChainGeneration g : page.entries) {
      rows.add(
        new Map<String, Object>{
          'instanceId' => g.instanceId,
          'instanceName' => g.instanceName,
          'generation' => g.generation,
          'status' => g.status,
          'correlationKey' => g.correlationKey,
          'outcome' => g.outcome,
          'startedAt' => g.startedAt,
          'endedAt' => g.endedAt,
          'failureCategory' => g.failureCategory,
          'errorMessage' => g.errorMessage
        }
      );
    }
    return new Map<String, Object>{
      'generations' => rows,
      'rootCorrelationKey' => page.rootCorrelationKey,
      'totalCount' => page.totalCount,
      'isTotalCapped' => page.isTotalCapped,
      'hasMore' => page.hasMore,
      'nextCursor' => page.nextCursor,
      'pageSize' => page.pageSize
    };
  }

  private static AuraHandledException auraError(String message) {
    AuraHandledException ex = new AuraHandledException(message);
    ex.setMessage(message);
    return ex;
  }
}
