/**
 * @description Chain membership of {@link WorkflowChainRead} (issue #116).
 *
 * <p>Scope: same `Workflow_Name__c` and same root key. A legacy row with a
 * blank `Root_Correlation_Key__c` matches on its `Correlation_Key__c`.</p>
 *
 * <p>Pivot: the predecessor of the anchor, or the anchor when it has no
 * predecessor. Range: from the nearest first generation
 * (`Previous_Instance__c` = null) at or before the pivot, to the next first
 * generation after the pivot. A row is a member when it is that first
 * generation, or when its predecessor is in the range.</p>
 *
 * <p>Thus a later independent run with the same key is not a member. A late
 * successor (for example a `compensate()` instance) stays with the chain of
 * its predecessor, also after a newer run used the key. `Id` breaks
 * `CreatedDate` ties. Max 2 SOQL.</p>
 */
public inherited sharing class WorkflowChainWindow {
  private static final String SCOPE =
    'Workflow_Name__c = :name AND (Root_Correlation_Key__c = :root OR ' +
    '(Root_Correlation_Key__c = null AND Correlation_Key__c = :root))';

  /**
   * @description WHERE clause of the chain of the anchor. Adds its binds to
   * the map.
   * @param anchor the anchor row, with `Previous_Instance__r.CreatedDate`
   * @param root the root key of the anchor (not blank)
   * @param binds bind map
   * @return the clause
   */
  public static String clause(
    Workflow_Instance__c anchor,
    String root,
    Map<String, Object> binds
  ) {
    binds.put('name', anchor.Workflow_Name__c);
    binds.put('root', root);
    Boolean hasPrevious = anchor.Previous_Instance__c != null;
    Map<String, Object> pivot = new Map<String, Object>{
      'name' => anchor.Workflow_Name__c,
      'root' => root,
      'pivotAt' => hasPrevious
        ? anchor.Previous_Instance__r.CreatedDate
        : anchor.CreatedDate,
      'pivotId' => hasPrevious ? anchor.Previous_Instance__c : anchor.Id
    };

    Workflow_Instance__c start = hasPrevious
      ? firstGeneration(pivot, true)
      : anchor;
    Workflow_Instance__c next = firstGeneration(pivot, false);

    // Successors: the predecessor is in [start, next).
    List<String> successor = new List<String>{ 'Previous_Instance__c != null' };
    List<String> member = new List<String>();
    if (start != null) {
      binds.put('startAt', start.CreatedDate);
      binds.put('startId', start.Id);
      member.add('Id = :startId');
      successor.add(
        '(Previous_Instance__r.CreatedDate > :startAt OR ' +
          '(Previous_Instance__r.CreatedDate = :startAt AND ' +
          'Previous_Instance__r.Id >= :startId))'
      );
    }
    if (next != null) {
      binds.put('nextAt', next.CreatedDate);
      binds.put('nextId', next.Id);
      successor.add(
        '(Previous_Instance__r.CreatedDate < :nextAt OR ' +
          '(Previous_Instance__r.CreatedDate = :nextAt AND ' +
          'Previous_Instance__r.Id < :nextId))'
      );
    }
    member.add('(' + String.join(successor, ' AND ') + ')');
    return SCOPE + ' AND (' + String.join(member, ' OR ') + ')';
  }

  /**
   * @description Keyset clause for rows older than a bound position.
   * @param atBind bind name of the `CreatedDate`
   * @param idBind bind name of the `Id`
   * @return the clause
   */
  public static String olderThan(String atBind, String idBind) {
    return '(CreatedDate < :' +
      atBind +
      ' OR (CreatedDate = :' +
      atBind +
      ' AND Id < :' +
      idBind +
      '))';
  }

  // First generation in scope next to the pivot: the newest at or before it
  // (atOrBefore = true), or the oldest after it. Null when none.
  private static Workflow_Instance__c firstGeneration(
    Map<String, Object> pivot,
    Boolean atOrBefore
  ) {
    String position = atOrBefore
      ? '(CreatedDate < :pivotAt OR (CreatedDate = :pivotAt AND Id <= :pivotId))' +
        ' ORDER BY CreatedDate DESC, Id DESC'
      : '(CreatedDate > :pivotAt OR (CreatedDate = :pivotAt AND Id > :pivotId))' +
        ' ORDER BY CreatedDate ASC, Id ASC';
    List<Workflow_Instance__c> rows = Database.queryWithBinds(
      'SELECT Id, CreatedDate FROM Workflow_Instance__c WHERE ' +
        SCOPE +
        ' AND Previous_Instance__c = null AND ' +
        position +
        ' LIMIT 1',
      pivot,
      AccessLevel.SYSTEM_MODE
    );
    return rows.isEmpty() ? null : rows[0];
  }
}
