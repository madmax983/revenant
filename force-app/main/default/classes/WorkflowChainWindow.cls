/**
 * @description Chain window of {@link WorkflowChainRead} (issue #116).
 *
 * <p>Scope: same `Workflow_Name__c` and same root key. A legacy row with a
 * blank `Root_Correlation_Key__c` matches on its `Correlation_Key__c`.</p>
 *
 * <p>Window: from the nearest first generation (`Previous_Instance__c` = null)
 * at or before the anchor, to the next first generation after the anchor. A
 * later independent run with the same key is not in the window. An anchor with
 * no successor is the end of the window. `Id` breaks `CreatedDate` ties. Max 2
 * SOQL.</p>
 */
public inherited sharing class WorkflowChainWindow {
  private static final String SCOPE =
    'Workflow_Name__c = :name AND (Root_Correlation_Key__c = :root OR ' +
    '(Root_Correlation_Key__c = null AND Correlation_Key__c = :root))';

  /**
   * @description WHERE clause of the chain window of the anchor. Adds its
   * binds to the map.
   * @param anchor the anchor row, with its `Next_Runs__r` subquery
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
    List<String> parts = new List<String>{ SCOPE };

    Workflow_Instance__c start = anchor.Previous_Instance__c == null
      ? anchor
      : previousStart(anchor, root);
    if (start != null) {
      binds.put('startAt', start.CreatedDate);
      binds.put('startId', start.Id);
      parts.add(
        '(CreatedDate > :startAt OR (CreatedDate = :startAt AND Id >= :startId))'
      );
    }
    if (anchor.Next_Runs__r.isEmpty()) {
      // No successor: no later row is in the chain.
      binds.put('endAt', anchor.CreatedDate);
      binds.put('endId', anchor.Id);
      parts.add(
        '(CreatedDate < :endAt OR (CreatedDate = :endAt AND Id <= :endId))'
      );
    } else {
      Workflow_Instance__c next = nextStart(anchor, root);
      if (next != null) {
        binds.put('nextAt', next.CreatedDate);
        binds.put('nextId', next.Id);
        parts.add(olderThan('nextAt', 'nextId'));
      }
    }
    return String.join(parts, ' AND ');
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

  // Newest first generation in scope before the anchor, or null.
  private static Workflow_Instance__c previousStart(
    Workflow_Instance__c anchor,
    String root
  ) {
    String name = anchor.Workflow_Name__c;
    Datetime anchorAt = anchor.CreatedDate;
    Id anchorId = anchor.Id;
    List<Workflow_Instance__c> rows = [
      SELECT Id, CreatedDate
      FROM Workflow_Instance__c
      WHERE
        Workflow_Name__c = :name
        AND (Root_Correlation_Key__c = :root
        OR (Root_Correlation_Key__c = NULL
        AND Correlation_Key__c = :root))
        AND Previous_Instance__c = NULL
        AND (CreatedDate < :anchorAt
        OR (CreatedDate = :anchorAt
        AND Id < :anchorId))
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC, Id DESC
      LIMIT 1
    ];
    return rows.isEmpty() ? null : rows[0];
  }

  // Oldest first generation in scope after the anchor, or null.
  private static Workflow_Instance__c nextStart(
    Workflow_Instance__c anchor,
    String root
  ) {
    String name = anchor.Workflow_Name__c;
    Datetime anchorAt = anchor.CreatedDate;
    Id anchorId = anchor.Id;
    List<Workflow_Instance__c> rows = [
      SELECT Id, CreatedDate
      FROM Workflow_Instance__c
      WHERE
        Workflow_Name__c = :name
        AND (Root_Correlation_Key__c = :root
        OR (Root_Correlation_Key__c = NULL
        AND Correlation_Key__c = :root))
        AND Previous_Instance__c = NULL
        AND (CreatedDate > :anchorAt
        OR (CreatedDate = :anchorAt
        AND Id > :anchorId))
      WITH SYSTEM_MODE
      ORDER BY CreatedDate ASC, Id ASC
      LIMIT 1
    ];
    return rows.isEmpty() ? null : rows[0];
  }
}
