/**
 * @description Backs the System Doctor tab's Storage Footprint panel: a strictly
 * read-only, aggregate-only view of how much of the org's hard, billable storage
 * allowances Revenant consumes and how fast it is growing. For each of the ten Revenant
 * data objects it returns a live record count, an estimated storage size (record count x a
 * standard per-record byte estimate), and 7-/30-day creation deltas so operators can see
 * acceleration. Offloaded large payloads are accounted separately as the summed
 * ContentVersion byte volume of engine-owned files. Record bytes are expressed as a
 * percentage of the org's DataStorageMB allowance and the offloaded file bytes as a
 * percentage of the org's FileStorageMB allowance (both via System.OrgLimits), because
 * records and files bill against separate allowances. The configurable warning threshold
 * (Revenant_Config__mdt) is applied to the DATA percentage; the FILE percentage is surfaced
 * as a separate informational gauge. It writes no records, publishes no events, and enqueues
 * no jobs; every query is a bounded aggregate COUNT()/SUM() running WITH SYSTEM_MODE (a bare
 * COUNT()/SUM() returns a scalar and needs no LIMIT to stay bounded). Follows the
 * WorkflowDashboardStatusService read-panel pattern (checkAuthorization first, serializable
 * Map return).
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

  // The OrgLimits key exposing the org's file-storage allowance (getValue = MB used,
  // getLimit = MB allowed). Offloaded ContentVersion payloads bill against FILE storage, not
  // DATA storage, so their byte volume is measured against this allowance rather than
  // DataStorageMB. 'FileStorageMB' is a documented System.OrgLimits.getMap() key.
  private static final String FILE_STORAGE_KEY = 'FileStorageMB';

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
   * @description Returns the Revenant storage footprint snapshot for the System Doctor
   * panel: per-object record counts, estimated bytes and 7-/30-day growth deltas; the summed
   * ContentVersion byte volume of offloaded payloads; the record-byte estimate as a percentage
   * of the org's DataStorageMB allowance and the offloaded-file bytes as a percentage of the
   * FileStorageMB allowance; and the configured warning threshold (applied to the data
   * percentage) with an over-threshold flag. Strictly read-only — all reads are bounded
   * aggregate COUNT()/SUM() queries WITH SYSTEM_MODE and nothing is written, published, or
   * enqueued.
   * @return A serializable map of the storage-footprint fields consumed by the panel.
   */
  public static Map<String, Object> storageFootprint() {
    WorkflowDashboardSupport.checkAuthorization();
    try {
      // One row per Revenant data object, each built from three static COUNT() aggregates
      // (total, last-7-day, last-30-day). Static SOQL with a literal FROM keeps the reads
      // injection-safe (no variable is concatenated into a query) and the LAST_N_DAYS date
      // literals bound the growth windows. The total uses `WHERE Id != NULL` (which matches
      // every row) rather than a LIMIT: a COUNT() is a scalar that is never truncated by
      // governor limits, whereas a `LIMIT 50000` would silently cap — and therefore
      // under-report — the count at that ceiling in exactly the high-volume orgs whose
      // acceleration this panel exists to surface. The `!= NULL` predicate satisfies the
      // analyzer's non-restrictive-query rule without imposing that cap.
      List<Map<String, Object>> objectRows = new List<Map<String, Object>>{
        row(
          'Workflow_Instance__c',
          new List<Integer>{
            [
              SELECT COUNT()
              FROM Workflow_Instance__c
              WHERE Id != NULL
              WITH SYSTEM_MODE
            ],
            [
              SELECT COUNT()
              FROM Workflow_Instance__c
              WHERE CreatedDate = LAST_N_DAYS:7
              WITH SYSTEM_MODE
            ],
            [
              SELECT COUNT()
              FROM Workflow_Instance__c
              WHERE CreatedDate = LAST_N_DAYS:30
              WITH SYSTEM_MODE
            ]
          }
        ),
        row(
          'Workflow_Step_Execution__c',
          new List<Integer>{
            [
              SELECT COUNT()
              FROM Workflow_Step_Execution__c
              WHERE Id != NULL
              WITH SYSTEM_MODE
            ],
            [
              SELECT COUNT()
              FROM Workflow_Step_Execution__c
              WHERE CreatedDate = LAST_N_DAYS:7
              WITH SYSTEM_MODE
            ],
            [
              SELECT COUNT()
              FROM Workflow_Step_Execution__c
              WHERE CreatedDate = LAST_N_DAYS:30
              WITH SYSTEM_MODE
            ]
          }
        ),
        row(
          'Workflow_Signal__c',
          new List<Integer>{
            [
              SELECT COUNT()
              FROM Workflow_Signal__c
              WHERE Id != NULL
              WITH SYSTEM_MODE
            ],
            [
              SELECT COUNT()
              FROM Workflow_Signal__c
              WHERE CreatedDate = LAST_N_DAYS:7
              WITH SYSTEM_MODE
            ],
            [
              SELECT COUNT()
              FROM Workflow_Signal__c
              WHERE CreatedDate = LAST_N_DAYS:30
              WITH SYSTEM_MODE
            ]
          }
        ),
        row(
          'Workflow_Log__c',
          new List<Integer>{
            [
              SELECT COUNT()
              FROM Workflow_Log__c
              WHERE Id != NULL
              WITH SYSTEM_MODE
            ],
            [
              SELECT COUNT()
              FROM Workflow_Log__c
              WHERE CreatedDate = LAST_N_DAYS:7
              WITH SYSTEM_MODE
            ],
            [
              SELECT COUNT()
              FROM Workflow_Log__c
              WHERE CreatedDate = LAST_N_DAYS:30
              WITH SYSTEM_MODE
            ]
          }
        ),
        row(
          'Rate_Limit_State__c',
          new List<Integer>{
            [
              SELECT COUNT()
              FROM Rate_Limit_State__c
              WHERE Id != NULL
              WITH SYSTEM_MODE
            ],
            [
              SELECT COUNT()
              FROM Rate_Limit_State__c
              WHERE CreatedDate = LAST_N_DAYS:7
              WITH SYSTEM_MODE
            ],
            [
              SELECT COUNT()
              FROM Rate_Limit_State__c
              WHERE CreatedDate = LAST_N_DAYS:30
              WITH SYSTEM_MODE
            ]
          }
        ),
        row(
          'Workflow_Pause_State__c',
          new List<Integer>{
            [
              SELECT COUNT()
              FROM Workflow_Pause_State__c
              WHERE Id != NULL
              WITH SYSTEM_MODE
            ],
            [
              SELECT COUNT()
              FROM Workflow_Pause_State__c
              WHERE CreatedDate = LAST_N_DAYS:7
              WITH SYSTEM_MODE
            ],
            [
              SELECT COUNT()
              FROM Workflow_Pause_State__c
              WHERE CreatedDate = LAST_N_DAYS:30
              WITH SYSTEM_MODE
            ]
          }
        ),
        row(
          'Workflow_Schedule__c',
          new List<Integer>{
            [
              SELECT COUNT()
              FROM Workflow_Schedule__c
              WHERE Id != NULL
              WITH SYSTEM_MODE
            ],
            [
              SELECT COUNT()
              FROM Workflow_Schedule__c
              WHERE CreatedDate = LAST_N_DAYS:7
              WITH SYSTEM_MODE
            ],
            [
              SELECT COUNT()
              FROM Workflow_Schedule__c
              WHERE CreatedDate = LAST_N_DAYS:30
              WITH SYSTEM_MODE
            ]
          }
        ),
        row(
          'Workflow_Search_Attribute__c',
          new List<Integer>{
            [
              SELECT COUNT()
              FROM Workflow_Search_Attribute__c
              WHERE Id != NULL
              WITH SYSTEM_MODE
            ],
            [
              SELECT COUNT()
              FROM Workflow_Search_Attribute__c
              WHERE CreatedDate = LAST_N_DAYS:7
              WITH SYSTEM_MODE
            ],
            [
              SELECT COUNT()
              FROM Workflow_Search_Attribute__c
              WHERE CreatedDate = LAST_N_DAYS:30
              WITH SYSTEM_MODE
            ]
          }
        ),
        row(
          'Debounce_State__c',
          new List<Integer>{
            [
              SELECT COUNT()
              FROM Debounce_State__c
              WHERE Id != NULL
              WITH SYSTEM_MODE
            ],
            [
              SELECT COUNT()
              FROM Debounce_State__c
              WHERE CreatedDate = LAST_N_DAYS:7
              WITH SYSTEM_MODE
            ],
            [
              SELECT COUNT()
              FROM Debounce_State__c
              WHERE CreatedDate = LAST_N_DAYS:30
              WITH SYSTEM_MODE
            ]
          }
        ),
        row(
          'Concurrency_State__c',
          new List<Integer>{
            [
              SELECT COUNT()
              FROM Concurrency_State__c
              WHERE Id != NULL
              WITH SYSTEM_MODE
            ],
            [
              SELECT COUNT()
              FROM Concurrency_State__c
              WHERE CreatedDate = LAST_N_DAYS:7
              WITH SYSTEM_MODE
            ],
            [
              SELECT COUNT()
              FROM Concurrency_State__c
              WHERE CreatedDate = LAST_N_DAYS:30
              WITH SYSTEM_MODE
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
      result.putAll(allowanceMetrics(recordBytes, contentBytes));
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
  //
  // KNOWN LIMITATION (title-prefix scoping): this identifies engine files by TITLE, not by the
  // ContentDocumentLink the offloader actually writes (savePayloadIfNeeded links each file to
  // its Workflow_Instance__c via ContentDocumentLink.LinkedEntityId). An unrelated user file
  // whose title happens to start with one of these prefixes (e.g. a manually uploaded
  // 'Input_notes.txt') is therefore over-counted, inflating the file-storage figure. Scoping by
  // ContentDocumentLink was evaluated and rejected as not cheaply bounded: ContentDocumentLink
  // requires a LinkedEntityId (or ContentDocumentId) filter, so the only way to enumerate
  // engine links is to bind the full set of Workflow_Instance__c ids — which in the very
  // high-volume orgs this panel targets is millions of rows and blows the 50k SOQL-row governor,
  // reintroducing exactly the unbounded per-instance scan this aggregate avoids. Tightening this
  // to link-based scoping is tracked as a follow-up to issue #108.
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
    ];
    Object total = ar.get('total');
    return total == null ? 0L : ((Decimal) total).longValue();
  }

  // Expresses record bytes as a percentage of the DataStorageMB allowance and offloaded file
  // bytes as a percentage of the FileStorageMB allowance, because records and files bill against
  // separate org allowances (adding file bytes into the data percentage produced false data
  // warnings). The operator-configured warning threshold is applied to the DATA percentage only;
  // the FILE percentage is returned as a separate informational gauge (isOverThreshold reflects
  // data storage). When the org exposes no allowance for a given key that percentage is 0 and its
  // has*Limit flag is false so the panel degrades gracefully rather than dividing by zero.
  private static Map<String, Object> allowanceMetrics(
    Long recordBytes,
    Long contentBytes
  ) {
    Decimal threshold = warningThresholdPercent();
    Map<String, System.OrgLimit> limitsMap = System.OrgLimits.getMap();

    Map<String, Object> dataMetrics = allowanceFor(
      limitsMap,
      DATA_STORAGE_KEY,
      recordBytes
    );
    Map<String, Object> fileMetrics = allowanceFor(
      limitsMap,
      FILE_STORAGE_KEY,
      contentBytes
    );

    Boolean hasDataLimit = (Boolean) dataMetrics.get('hasLimit');
    Decimal dataPercent = (Decimal) dataMetrics.get('percent');

    return new Map<String, Object>{
      'orgStorageUsedMb' => dataMetrics.get('usedMb'),
      'orgStorageLimitMb' => dataMetrics.get('limitMb'),
      'hasStorageLimit' => hasDataLimit,
      'percentOfAllowance' => dataPercent,
      'orgFileStorageUsedMb' => fileMetrics.get('usedMb'),
      'orgFileStorageLimitMb' => fileMetrics.get('limitMb'),
      'hasFileStorageLimit' => fileMetrics.get('hasLimit'),
      'filePercentOfAllowance' => fileMetrics.get('percent'),
      'warningThresholdPercent' => threshold,
      'isOverThreshold' => hasDataLimit && dataPercent >= threshold
    };
  }

  // Computes one allowance gauge (used MB, limit MB, has-limit flag and used-bytes percentage)
  // for the given System.OrgLimits key. Returns percentage 0 and hasLimit false when the org
  // exposes no such limit, so callers never divide by a zero allowance.
  private static Map<String, Object> allowanceFor(
    Map<String, System.OrgLimit> limitsMap,
    String limitKey,
    Long usedBytes
  ) {
    Integer usedMb = 0;
    Integer limitMb = 0;
    Boolean hasLimit = false;
    if (limitsMap.containsKey(limitKey)) {
      System.OrgLimit limitObj = limitsMap.get(limitKey);
      usedMb = limitObj.getValue();
      limitMb = limitObj.getLimit();
      hasLimit = limitMb > 0;
    }

    Decimal percent = 0;
    if (hasLimit) {
      Long allowanceBytes = (Long) limitMb * BYTES_PER_MB;
      percent = (Decimal.valueOf(usedBytes) /
        allowanceBytes *
        100)
        .setScale(2, System.RoundingMode.HALF_UP);
    }

    return new Map<String, Object>{
      'usedMb' => usedMb,
      'limitMb' => limitMb,
      'hasLimit' => hasLimit,
      'percent' => percent
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
