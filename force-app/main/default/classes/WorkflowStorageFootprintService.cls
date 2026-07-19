/**
 * @description Backs the System Doctor tab's Storage Footprint panel: a strictly
 * read-only, aggregate-only view of how much of the org's hard, billable data-storage
 * allowance Revenant consumes and how fast it is growing. For each of the seven Revenant
 * data objects it returns a live record count, an estimated storage size (record count x a
 * standard per-record byte estimate), and 7-/30-day creation deltas so operators can see
 * acceleration. Offloaded large payloads are accounted separately as the summed
 * ContentVersion byte volume of engine-owned files. The total estimate is expressed as a
 * percentage of the org's DataStorageMB allowance (via System.OrgLimits) and flagged
 * against an operator-configurable warning threshold (Revenant_Config__mdt). It writes no
 * records, publishes no events, and enqueues no jobs; every query is a bounded aggregate
 * COUNT()/SUM() running WITH SYSTEM_MODE. Follows the WorkflowDashboardStatusService
 * read-panel pattern (checkAuthorization first, serializable Map return).
 */
public inherited sharing class WorkflowStorageFootprintService {
  // Standard per-record data-storage estimate. Salesforce bills most records at a flat
  // ~2 KB regardless of field usage and does not expose a cheap exact per-object byte
  // figure, so this is deliberately an ESTIMATE (see the panel's "estimate" labelling and
  // issue #108's out-of-scope note). Offloaded payload bytes are measured exactly and added
  // on top via the ContentVersion SUM below.
  private static final Long BYTES_PER_RECORD = 2000;

  // The OrgLimits key exposing the org's data-storage allowance (getValue = MB used,
  // getLimit = MB allowed). The same System.OrgLimits.getMap() API already backs the async
  // limit tiles in WorkflowDashboardStatusService.readAsyncLimits.
  private static final String DATA_STORAGE_KEY = 'DataStorageMB';

  // Number of bytes in one megabyte, for converting the MB allowance to a byte budget.
  private static final Long BYTES_PER_MB = 1048576;

  // Default warning threshold (percent of the org's data-storage allowance) applied when the
  // Default Revenant_Config__mdt record or its Storage_Warning_Threshold_Percent__c field is
  // absent. The panel flips to a warning state at or above this percentage.
  @TestVisible
  private static final Decimal DEFAULT_WARNING_THRESHOLD_PERCENT = 75;

  // Test-only override for the warning threshold. When non-null it wins over the metadata read
  // so unit tests can drive the over-threshold classification both ways without deploying
  // config records.
  @TestVisible
  private static Decimal thresholdOverride = null;

  /**
   * @description Returns the Revenant data-storage footprint snapshot for the System Doctor
   * panel: per-object record counts, estimated bytes and 7-/30-day growth deltas; the summed
   * ContentVersion byte volume of offloaded payloads; the combined estimate as a percentage
   * of the org's data-storage allowance; and the configured warning threshold with an
   * over-threshold flag. Strictly read-only — all reads are bounded aggregate COUNT()/SUM()
   * queries WITH SYSTEM_MODE and nothing is written, published, or enqueued.
   * @return A serializable map of the storage-footprint fields consumed by the panel.
   */
  public static Map<String, Object> storageFootprint() {
    WorkflowDashboardSupport.checkAuthorization();
    try {
      // One row per Revenant data object, each built from three bounded static COUNT()
      // aggregates (total, last-7-day, last-30-day). Static SOQL with a literal FROM keeps
      // the reads injection-safe (no variable is concatenated into a query) and the
      // LAST_N_DAYS date literals bound the growth windows. The LIMIT 50000 satisfies the
      // bounded-query rule; a COUNT is never truncated by it.
      List<Map<String, Object>> objectRows = new List<Map<String, Object>>{
        row(
          'Workflow_Instance__c',
          new List<Integer>{
            [
              SELECT COUNT()
              FROM Workflow_Instance__c
              WITH SYSTEM_MODE
              LIMIT 50000
            ],
            [
              SELECT COUNT()
              FROM Workflow_Instance__c
              WHERE CreatedDate = LAST_N_DAYS:7
              WITH SYSTEM_MODE
              LIMIT 50000
            ],
            [
              SELECT COUNT()
              FROM Workflow_Instance__c
              WHERE CreatedDate = LAST_N_DAYS:30
              WITH SYSTEM_MODE
              LIMIT 50000
            ]
          }
        ),
        row(
          'Workflow_Step_Execution__c',
          new List<Integer>{
            [
              SELECT COUNT()
              FROM Workflow_Step_Execution__c
              WITH SYSTEM_MODE
              LIMIT 50000
            ],
            [
              SELECT COUNT()
              FROM Workflow_Step_Execution__c
              WHERE CreatedDate = LAST_N_DAYS:7
              WITH SYSTEM_MODE
              LIMIT 50000
            ],
            [
              SELECT COUNT()
              FROM Workflow_Step_Execution__c
              WHERE CreatedDate = LAST_N_DAYS:30
              WITH SYSTEM_MODE
              LIMIT 50000
            ]
          }
        ),
        row(
          'Workflow_Signal__c',
          new List<Integer>{
            [
              SELECT COUNT()
              FROM Workflow_Signal__c
              WITH SYSTEM_MODE
              LIMIT 50000
            ],
            [
              SELECT COUNT()
              FROM Workflow_Signal__c
              WHERE CreatedDate = LAST_N_DAYS:7
              WITH SYSTEM_MODE
              LIMIT 50000
            ],
            [
              SELECT COUNT()
              FROM Workflow_Signal__c
              WHERE CreatedDate = LAST_N_DAYS:30
              WITH SYSTEM_MODE
              LIMIT 50000
            ]
          }
        ),
        row(
          'Workflow_Log__c',
          new List<Integer>{
            [SELECT COUNT() FROM Workflow_Log__c WITH SYSTEM_MODE LIMIT 50000],
            [
              SELECT COUNT()
              FROM Workflow_Log__c
              WHERE CreatedDate = LAST_N_DAYS:7
              WITH SYSTEM_MODE
              LIMIT 50000
            ],
            [
              SELECT COUNT()
              FROM Workflow_Log__c
              WHERE CreatedDate = LAST_N_DAYS:30
              WITH SYSTEM_MODE
              LIMIT 50000
            ]
          }
        ),
        row(
          'Rate_Limit_State__c',
          new List<Integer>{
            [
              SELECT COUNT()
              FROM Rate_Limit_State__c
              WITH SYSTEM_MODE
              LIMIT 50000
            ],
            [
              SELECT COUNT()
              FROM Rate_Limit_State__c
              WHERE CreatedDate = LAST_N_DAYS:7
              WITH SYSTEM_MODE
              LIMIT 50000
            ],
            [
              SELECT COUNT()
              FROM Rate_Limit_State__c
              WHERE CreatedDate = LAST_N_DAYS:30
              WITH SYSTEM_MODE
              LIMIT 50000
            ]
          }
        ),
        row(
          'Workflow_Pause_State__c',
          new List<Integer>{
            [
              SELECT COUNT()
              FROM Workflow_Pause_State__c
              WITH SYSTEM_MODE
              LIMIT 50000
            ],
            [
              SELECT COUNT()
              FROM Workflow_Pause_State__c
              WHERE CreatedDate = LAST_N_DAYS:7
              WITH SYSTEM_MODE
              LIMIT 50000
            ],
            [
              SELECT COUNT()
              FROM Workflow_Pause_State__c
              WHERE CreatedDate = LAST_N_DAYS:30
              WITH SYSTEM_MODE
              LIMIT 50000
            ]
          }
        ),
        row(
          'Workflow_Schedule__c',
          new List<Integer>{
            [
              SELECT COUNT()
              FROM Workflow_Schedule__c
              WITH SYSTEM_MODE
              LIMIT 50000
            ],
            [
              SELECT COUNT()
              FROM Workflow_Schedule__c
              WHERE CreatedDate = LAST_N_DAYS:7
              WITH SYSTEM_MODE
              LIMIT 50000
            ],
            [
              SELECT COUNT()
              FROM Workflow_Schedule__c
              WHERE CreatedDate = LAST_N_DAYS:30
              WITH SYSTEM_MODE
              LIMIT 50000
            ]
          }
        )
      };

      Long totalRecords = 0;
      for (Map<String, Object> objectRow : objectRows) {
        totalRecords += (Integer) objectRow.get('recordCount');
      }

      Long contentBytes = revenantContentBytes();
      Long recordBytes = totalRecords * BYTES_PER_RECORD;
      Long totalBytes = recordBytes + contentBytes;

      Map<String, Object> result = new Map<String, Object>{
        'objects' => objectRows,
        'bytesPerRecord' => BYTES_PER_RECORD,
        'estimatedRecordBytes' => recordBytes,
        'contentVersionBytes' => contentBytes,
        'estimatedTotalBytes' => totalBytes
      };
      result.putAll(allowanceMetrics(totalBytes));
      return result;
    } catch (Exception ex) {
      throw WorkflowDashboardSupport.auraError(ex.getMessage());
    }
  }

  // Assembles one per-object footprint row from its counts (index 0 = total record count,
  // 1 = last-7-day, 2 = last-30-day), deriving the display label and the estimated byte size
  // from the total record count.
  private static Map<String, Object> row(String apiName, List<Integer> counts) {
    Integer total = counts[0];
    return new Map<String, Object>{
      'apiName' => apiName,
      'label' => displayLabel(apiName),
      'recordCount' => total,
      'estimatedBytes' => total * BYTES_PER_RECORD,
      'delta7' => counts[1],
      'delta30' => counts[2]
    };
  }

  // Sums the byte volume of Revenant-owned offloaded ContentVersion files. Engine-owned
  // documents are identified by the same title prefixes the offload writer stamps and the
  // purger recognises (CleanupDocumentPurger.ALLOWED_PREFIXES / WorkflowPayloadOffload
  // titles), which scopes the sum to Revenant's linked content without enumerating instances
  // (a bounded single aggregate rather than an unbounded per-instance scan). The trailing
  // '_%' relies on SOQL LIKE treating '_' as a single-character wildcard, matching the real
  // 'Input_...', 'Output_...' etc. titles. Latest versions only, so superseded revisions are
  // not double-counted.
  private static Long revenantContentBytes() {
    AggregateResult ar = [
      SELECT SUM(ContentSize) total
      FROM ContentVersion
      WHERE
        IsLatest = TRUE
        AND (Title LIKE 'Input_%'
        OR Title LIKE 'Output_%'
        OR Title LIKE 'State_%'
        OR Title LIKE 'Resume_%'
        OR Title LIKE 'ContinueInput_%'
        OR Title LIKE 'Captures_%'
        OR Title LIKE 'VerificationPayload%')
      WITH SYSTEM_MODE
      LIMIT 50000
    ];
    Object total = ar.get('total');
    return total == null ? 0L : ((Decimal) total).longValue();
  }

  // Expresses the combined estimate as a percentage of the org's DataStorageMB allowance and
  // classifies it against the operator-configured warning threshold. When the org exposes no
  // DataStorageMB limit the percentage is 0 and hasStorageLimit is false so the panel can
  // degrade gracefully rather than divide by zero.
  private static Map<String, Object> allowanceMetrics(Long totalBytes) {
    Decimal threshold = warningThresholdPercent();
    Map<String, System.OrgLimit> limitsMap = System.OrgLimits.getMap();
    Integer usedMb = 0;
    Integer limitMb = 0;
    Boolean hasLimit = false;
    if (limitsMap.containsKey(DATA_STORAGE_KEY)) {
      System.OrgLimit limitObj = limitsMap.get(DATA_STORAGE_KEY);
      usedMb = limitObj.getValue();
      limitMb = limitObj.getLimit();
      hasLimit = limitMb > 0;
    }

    Decimal percentOfAllowance = 0;
    if (hasLimit) {
      Long allowanceBytes = (Long) limitMb * BYTES_PER_MB;
      percentOfAllowance = (Decimal.valueOf(totalBytes) /
        allowanceBytes *
        100)
        .setScale(2, System.RoundingMode.HALF_UP);
    }

    return new Map<String, Object>{
      'orgStorageUsedMb' => usedMb,
      'orgStorageLimitMb' => limitMb,
      'hasStorageLimit' => hasLimit,
      'percentOfAllowance' => percentOfAllowance,
      'warningThresholdPercent' => threshold,
      'isOverThreshold' => hasLimit && percentOfAllowance >= threshold
    };
  }

  // Reads the operator-configured storage warning threshold from the Default
  // Revenant_Config__mdt record via getInstance — a SOQL-free custom-metadata retrieval that
  // adds no query/DML/FLS surface, matching how WorkflowFailureAlertEvaluator reads its config.
  // Falls back to DEFAULT_WARNING_THRESHOLD_PERCENT (75) when the record or its
  // Storage_Warning_Threshold_Percent__c field is absent. A non-null test override wins so unit
  // tests can exercise both classification outcomes deterministically.
  private static Decimal warningThresholdPercent() {
    if (thresholdOverride != null) {
      return thresholdOverride;
    }
    Revenant_Config__mdt config = Revenant_Config__mdt.getInstance('Default');
    if (config != null && config.Storage_Warning_Threshold_Percent__c != null) {
      return config.Storage_Warning_Threshold_Percent__c;
    }
    return DEFAULT_WARNING_THRESHOLD_PERCENT;
  }

  // Human-readable object label derived from the API name (strip the '__c' suffix, swap
  // underscores for spaces) so the panel needs no per-object describe call. Yields e.g.
  // 'Workflow Step Execution' for 'Workflow_Step_Execution__c'.
  private static String displayLabel(String apiName) {
    String base = apiName.endsWith('__c')
      ? apiName.substring(0, apiName.length() - 3)
      : apiName;
    return base.replace('_', ' ');
  }
}
