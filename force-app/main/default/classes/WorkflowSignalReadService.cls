/**
 * @description Backs the dashboard's unrouted-signal list and count. Holds the dynamic
 * SOQL over Workflow_Signal__c for signals that found no target instance. Extracted from
 * WorkflowDashboardController; all SOQL runs in AccessLevel.SYSTEM_MODE.
 */
public inherited sharing class WorkflowSignalReadService {
  // Class-level static binding variable for the dynamic SOQL wildcard term; must be in
  // scope of this class when Database.query() is executed.
  private static String likeTerm;

  private static final Integer UNROUTED_CANDIDATE_CAP = 2000;

  /**
   * @description Returns a page of unrouted (unmatched) signals with a computed age, so
   * operators can inspect and redeliver signals that found no target instance.
   * @param criteria The search and pagination criteria.
   * @return One display map per unrouted signal on the requested page, oldest first.
   */
  public static List<Map<String, Object>> listUnrouted(
    WorkflowDashboardController.UnroutedQuery criteria
  ) {
    WorkflowDashboardSupport.checkAuthorization();

    String searchTerm = criteria.searchTerm;
    Integer limitSize = criteria.limitSize;
    Integer offsetSize = criteria.offsetSize;

    Integer lim = (limitSize == null ||
      limitSize <= 0)
      ? 50
      : Math.min(limitSize, 100);
    Integer off = (offsetSize == null ||
      offsetSize < 0)
      ? 0
      : Math.min(offsetSize, 2000);

    String query =
      'SELECT Id, Correlation_Key__c, Signal_Name__c, CreatedDate ' +
      'FROM Workflow_Signal__c ' +
      'WHERE Status__c = \'Unrouted\'';

    if (String.isNotBlank(searchTerm)) {
      likeTerm = '%' + searchTerm.trim() + '%';
      query += ' AND (Correlation_Key__c LIKE :likeTerm OR Signal_Name__c LIKE :likeTerm)';
    }

    query += ' ORDER BY CreatedDate ASC LIMIT :lim OFFSET :off';

    List<Workflow_Signal__c> rows = Database.query(
      query,
      AccessLevel.SYSTEM_MODE
    );

    Long nowMs = Datetime.now().getTime();
    List<Map<String, Object>> results = new List<Map<String, Object>>();
    for (Workflow_Signal__c sig : rows) {
      Long ageMinutes = Math.max(
        0L,
        (nowMs - sig.CreatedDate.getTime()) / 60000L
      );
      results.add(
        new Map<String, Object>{
          'id' => sig.Id,
          'correlationKey' => sig.Correlation_Key__c,
          'signalName' => sig.Signal_Name__c,
          'createdDate' => sig.CreatedDate,
          'ageMinutes' => ageMinutes
        }
      );
    }
    return results;
  }

  /**
   * @description Counts unrouted signals matching the search term, reporting a capped flag
   * when the candidate scan hit its governor-safety bound.
   * @param searchTerm The free-text search term over key/name, or blank for all.
   * @return A map with the unrouted-signal count and a capped flag.
   */
  public static Map<String, Object> countUnrouted(String searchTerm) {
    WorkflowDashboardSupport.checkAuthorization();

    String query = 'SELECT Id FROM Workflow_Signal__c WHERE Status__c = \'Unrouted\'';

    if (String.isNotBlank(searchTerm)) {
      likeTerm = '%' + searchTerm.trim() + '%';
      query += ' AND (Correlation_Key__c LIKE :likeTerm OR Signal_Name__c LIKE :likeTerm)';
    }

    query += ' LIMIT :UNROUTED_CANDIDATE_CAP';

    List<Workflow_Signal__c> candidates = Database.query(
      query,
      AccessLevel.SYSTEM_MODE
    );
    Boolean capped = candidates.size() >= UNROUTED_CANDIDATE_CAP;

    return new Map<String, Object>{
      'count' => candidates.size(),
      'capped' => capped
    };
  }
}
