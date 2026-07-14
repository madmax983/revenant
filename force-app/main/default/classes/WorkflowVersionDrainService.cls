/**
 * @description Builds the per-Definition_Version__c drain view for a workflow: for each
 * observed version, the non-terminal (still executing), failed (terminal but re-drivable),
 * and clean-terminal counts plus a safeToRetire flag. Chooses a full row scan for small
 * definitions and a bounded discover-then-aggregate strategy for large ones. Extracted
 * from WorkflowDashboardController; all SOQL runs WITH SYSTEM_MODE.
 */
public inherited sharing class WorkflowVersionDrainService {
  // Statuses that mean an instance still needs its definition-version code deployed.
  // CompensationFailed is included because such instances can still be Resume-Rollback'd.
  private static final Set<String> NON_TERMINAL_STATUSES = new Set<String>{
    'Pending',
    'Running',
    'Suspended',
    'Compensating',
    'Cancelling',
    'CompensationFailed',
    'Paused'
  };

  // Terminal statuses that are nonetheless re-drivable on their original version. Reported
  // as a distinct count so retiring a version's code never silently breaks a still-
  // recoverable failed run.
  private static final Set<String> RECOVERABLE_TERMINAL_STATUSES = new Set<String>{
    'Failed'
  };

  /**
   * @description Returns a per-Definition_Version__c drain view for the given workflow
   * name. Each row carries three buckets — non-terminal (still executing), failed
   * (terminal but re-drivable on this version), and clean terminal — plus a safeToRetire
   * flag that is true only when BOTH the non-terminal and failed counts are 0. Only
   * versions actually observed in Workflow_Instance__c are returned; absence from results
   * is NOT reported as "safe".
   * @param workflowName The workflow definition name to build the drain view for.
   * @return One drain-bucket map per observed definition version, or an empty list.
   */
  public static List<Map<String, Object>> buildDrainView(String workflowName) {
    WorkflowDashboardSupport.checkAuthorization();

    if (String.isBlank(workflowName)) {
      return new List<Map<String, Object>>();
    }

    VersionDrainAccumulator acc = new VersionDrainAccumulator();

    Integer totalCount = [
      SELECT COUNT()
      FROM Workflow_Instance__c
      WHERE Workflow_Name__c = :workflowName
      WITH SYSTEM_MODE
    ];

    if (totalCount <= 40000) {
      accumulateVersionDrainByScan(workflowName, acc);
    } else {
      accumulateVersionDrainByAggregate(workflowName, acc);
    }

    return acc.toRows();
  }

  // Accumulates per-version (non-terminal / failed / clean-terminal) instance counts and
  // renders the sorted display rows. Centralizing the status-bucketing keeps the two
  // collection strategies (full scan vs. aggregate) from duplicating it.
  private class VersionDrainAccumulator {
    Map<String, Integer> nonTerminal = new Map<String, Integer>();
    Map<String, Integer> failed = new Map<String, Integer>();
    Map<String, Integer> terminal = new Map<String, Integer>();
    Map<String, Integer> versionKeyToInt = new Map<String, Integer>();

    void ensureVersion(String verKey, Integer verInt) {
      if (!nonTerminal.containsKey(verKey)) {
        nonTerminal.put(verKey, 0);
        failed.put(verKey, 0);
        terminal.put(verKey, 0);
        versionKeyToInt.put(verKey, verInt);
      }
    }

    void bucket(String verKey, String stat, Integer count) {
      if (NON_TERMINAL_STATUSES.contains(stat)) {
        nonTerminal.put(verKey, nonTerminal.get(verKey) + count);
      } else if (RECOVERABLE_TERMINAL_STATUSES.contains(stat)) {
        failed.put(verKey, failed.get(verKey) + count);
      } else {
        terminal.put(verKey, terminal.get(verKey) + count);
      }
    }

    List<Map<String, Object>> toRows() {
      // Sort version keys numerically (null sorts last)
      List<String> sortedKeys = new List<String>(nonTerminal.keySet());
      sortedKeys.sort();
      Integer nullKeyIdx = sortedKeys.indexOf('null');
      if (nullKeyIdx != -1) {
        sortedKeys.remove(nullKeyIdx);
        sortedKeys.add('null');
      }

      List<Map<String, Object>> rows = new List<Map<String, Object>>();
      for (String verKey : sortedKeys) {
        Integer nt = nonTerminal.get(verKey);
        Integer fl = failed.get(verKey);
        Integer tm = terminal.get(verKey);
        rows.add(
          new Map<String, Object>{
            'version' => versionKeyToInt.get(verKey),
            'nonTerminalCount' => nt,
            'failedCount' => fl,
            'terminalCount' => tm,
            'totalCount' => nt +
            fl +
            tm,
            'safeToRetire' => nt == 0 &&
            fl == 0
          }
        );
      }
      return rows;
    }
  }

  // Small definitions: a single full row scan buckets every instance by version + status.
  private static void accumulateVersionDrainByScan(
    String workflowName,
    VersionDrainAccumulator acc
  ) {
    for (Workflow_Instance__c inst : [
      SELECT Definition_Version__c, Status__c
      FROM Workflow_Instance__c
      WHERE Workflow_Name__c = :workflowName
      WITH SYSTEM_MODE
    ]) {
      Decimal verDecimal = inst.Definition_Version__c;
      Integer ver = verDecimal == null ? null : verDecimal.intValue();
      String verKey = ver == null ? 'null' : String.valueOf(ver);
      acc.ensureVersion(verKey, ver);
      acc.bucket(verKey, inst.Status__c, 1);
    }
  }

  // Large definitions: avoid materializing every row. Discover the observed versions via
  // two bounded queries, then bucket each version's status counts with a SINGLE GROUP BY
  // aggregate over just those versions.
  private static void accumulateVersionDrainByAggregate(
    String workflowName,
    VersionDrainAccumulator acc
  ) {
    Set<Decimal> versionDecimals = new Set<Decimal>();
    Boolean hasNullVersion = discoverDrainVersions(
      workflowName,
      versionDecimals
    );

    for (Decimal ver : versionDecimals) {
      Integer verInt = ver == null ? null : ver.intValue();
      acc.ensureVersion(String.valueOf(verInt), verInt);
    }

    if (!versionDecimals.isEmpty()) {
      for (AggregateResult ar : [
        SELECT Definition_Version__c ver, Status__c, COUNT(Id) cnt
        FROM Workflow_Instance__c
        WHERE
          Workflow_Name__c = :workflowName
          AND Definition_Version__c IN :versionDecimals
        WITH SYSTEM_MODE
        GROUP BY Definition_Version__c, Status__c
      ]) {
        Decimal verDecimal = (Decimal) ar.get('ver');
        Integer verInt = verDecimal == null ? null : verDecimal.intValue();
        acc.bucket(
          String.valueOf(verInt),
          (String) ar.get('Status__c'),
          (Integer) ar.get('cnt')
        );
      }
    }

    if (hasNullVersion) {
      acc.ensureVersion('null', null);
      for (AggregateResult ar : [
        SELECT Status__c, COUNT(Id) cnt
        FROM Workflow_Instance__c
        WHERE Workflow_Name__c = :workflowName AND Definition_Version__c = NULL
        WITH SYSTEM_MODE
        GROUP BY Status__c
      ]) {
        acc.bucket(
          'null',
          (String) ar.get('Status__c'),
          (Integer) ar.get('cnt')
        );
      }
    }
  }

  // Populates versionDecimals with the non-null Definition_Version__c values observed in
  // the active/failed slice (up to 5000) and the most recent 10000 runs; returns true if
  // any null-version instance was seen.
  private static Boolean discoverDrainVersions(
    String workflowName,
    Set<Decimal> versionDecimals
  ) {
    Boolean hasNullVersion = false;
    for (Workflow_Instance__c inst : [
      SELECT Definition_Version__c
      FROM Workflow_Instance__c
      WHERE
        Workflow_Name__c = :workflowName
        AND Status__c NOT IN ('Completed', 'Cancelled', 'ContinuedAsNew')
      WITH SYSTEM_MODE
      LIMIT 5000
    ]) {
      if (inst.Definition_Version__c != null) {
        versionDecimals.add(inst.Definition_Version__c);
      } else {
        hasNullVersion = true;
      }
    }
    for (Workflow_Instance__c inst : [
      SELECT Definition_Version__c
      FROM Workflow_Instance__c
      WHERE Workflow_Name__c = :workflowName
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC
      LIMIT 10000
    ]) {
      if (inst.Definition_Version__c != null) {
        versionDecimals.add(inst.Definition_Version__c);
      } else {
        hasNullVersion = true;
      }
    }
    return hasNullVersion;
  }
}
