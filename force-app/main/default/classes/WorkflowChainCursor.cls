/**
 * @description Opaque keyset cursor of {@link WorkflowChainRead} (issue #116).
 * Internal: not a contract. It keeps the anchor of the first page, and the
 * position (`CreatedDate`, `Id`) and generation of the last row of a page.
 * Callers send it back with no change.
 */
public inherited sharing class WorkflowChainCursor {
  private static final Integer VERSION = 1;
  // Year 1970 to year 3000, in epoch milliseconds.
  private static final Long MAX_MILLIS = 32503680000000L;

  /** @description Anchor of the first page. */
  public Id anchorId { get; private set; }
  /** @description `CreatedDate` of the last row of the page. */
  public Datetime createdAt { get; private set; }
  /** @description `Id` of the last row of the page. */
  public Id rowId { get; private set; }
  /** @description Generation of the last row, or null when unknown. */
  public Integer generation { get; private set; }

  private WorkflowChainCursor(Map<String, Object> payload) {
    this.anchorId = toInstanceId(payload.get('a'));
    this.rowId = toInstanceId(payload.get('i'));
    this.createdAt = Datetime.newInstance(toMillis(payload.get('c')));
    this.generation = toGeneration(payload.get('g'));
  }

  /**
   * @description Encodes a cursor.
   * @param anchorId anchor of the first page
   * @param row last row of the page
   * @param generation its generation, or null
   * @return opaque cursor
   */
  public static String encode(
    Id anchorId,
    Workflow_Instance__c row,
    Integer generation
  ) {
    Map<String, Object> payload = new Map<String, Object>{
      'v' => VERSION,
      'a' => String.valueOf(anchorId),
      'c' => row.CreatedDate.getTime(),
      'i' => String.valueOf(row.Id),
      'g' => generation
    };
    return EncodingUtil.base64Encode(Blob.valueOf(JSON.serialize(payload)));
  }

  /**
   * @description Decodes a cursor from {@link #encode}.
   * @param value opaque cursor, or blank for the first page
   * @return the cursor, or null for the first page
   * @throws WorkflowEngine.WorkflowException when the value is bad
   */
  public static WorkflowChainCursor decode(String value) {
    if (String.isBlank(value)) {
      return null;
    }
    try {
      Map<String, Object> payload = (Map<String, Object>) JSON.deserializeUntyped(
        EncodingUtil.base64Decode(value).toString()
      );
      if (payload.get('v') != VERSION) {
        throw new StringException('unknown version');
      }
      return new WorkflowChainCursor(payload);
    } catch (Exception decodeError) {
      // Each parse error (base64, UTF-8, JSON, number, Id) is a bad cursor.
      throw new WorkflowEngine.WorkflowException(
        'Invalid chain cursor. Send back nextCursor with no change, or leave ' +
        'it null for the first page.'
      );
    }
  }

  /**
   * @description Keyset clause for rows older than the last row. Adds the
   * binds `cursorAt` and `cursorId`.
   * @param binds bind map
   * @return the clause
   */
  public String olderClause(Map<String, Object> binds) {
    binds.put('cursorAt', createdAt);
    binds.put('cursorId', rowId);
    return WorkflowChainWindow.olderThan('cursorAt', 'cursorId');
  }

  private static Long toMillis(Object value) {
    if (!(value instanceof Long || value instanceof Integer)) {
      throw new StringException('bad time');
    }
    Long millis = Long.valueOf(String.valueOf(value));
    if (millis <= 0 || millis > MAX_MILLIS) {
      throw new StringException('bad time');
    }
    return millis;
  }

  // Null is valid: the generation is not known.
  private static Integer toGeneration(Object value) {
    if (value == null) {
      return null;
    }
    Integer generation = Integer.valueOf(String.valueOf(value));
    if (generation < 1) {
      throw new StringException('bad generation');
    }
    return generation;
  }

  private static Id toInstanceId(Object value) {
    Id parsed = Id.valueOf(String.valueOf(value));
    if (parsed.getSobjectType() != Workflow_Instance__c.SObjectType) {
      throw new StringException('not an instance Id');
    }
    return parsed;
  }
}
