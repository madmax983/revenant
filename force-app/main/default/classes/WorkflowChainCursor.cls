/**
 * @description Opaque keyset cursor of {@link WorkflowChainRead} (issue #116).
 * Keeps the position (`CreatedDate`, `Id`) and the generation of the last row
 * of a page. The format is internal. Callers send it back with no change.
 */
public inherited sharing class WorkflowChainCursor {
  private static final String VERSION = 'v1';
  private static final String SEPARATOR = '|';

  /** @description `CreatedDate` of the last row of the page. */
  public Datetime createdAt { get; private set; }
  /** @description `Id` of the last row of the page. */
  public Id id { get; private set; }
  /** @description Generation of the last row, or null when unknown. */
  public Integer generation { get; private set; }

  private WorkflowChainCursor(Datetime createdAt, Id id, Integer generation) {
    this.createdAt = createdAt;
    this.id = id;
    this.generation = generation;
  }

  /**
   * @description Encodes the position and generation of a row.
   * @param row last row of the page
   * @param generation its generation, or null
   * @return opaque cursor
   */
  public static String encode(Workflow_Instance__c row, Integer generation) {
    String raw = String.join(
      new List<String>{
        VERSION,
        String.valueOf(row.CreatedDate.getTime()),
        String.valueOf(row.Id),
        generation == null ? '' : String.valueOf(generation)
      },
      SEPARATOR
    );
    return EncodingUtil.base64Encode(Blob.valueOf(raw));
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
      return parse(EncodingUtil.base64Decode(value).toString());
    } catch (Exception decodeError) {
      // Each parse error (base64, UTF-8, number, Id) is a bad cursor.
      throw new WorkflowEngine.WorkflowException(
        'Invalid chain cursor. Send back nextCursor with no change, or leave ' +
          'it null for the first page. (' +
          decodeError.getMessage() +
          ')'
      );
    }
  }

  /**
   * @description Keyset clause for rows older than this position. Adds the
   * binds `cursorAt` and `cursorId`.
   * @param binds bind map
   * @return the clause
   */
  public String olderClause(Map<String, Object> binds) {
    binds.put('cursorAt', createdAt);
    binds.put('cursorId', id);
    return WorkflowChainWindow.olderThan('cursorAt', 'cursorId');
  }

  private static WorkflowChainCursor parse(String raw) {
    List<String> parts = raw.split('\\' + SEPARATOR, -1);
    if (parts.size() != 4 || !VERSION.equals(parts[0])) {
      throw new StringException('unknown format');
    }
    return new WorkflowChainCursor(
      Datetime.newInstance(Long.valueOf(parts[1])),
      toInstanceId(parts[2]),
      String.isBlank(parts[3]) ? null : Integer.valueOf(parts[3])
    );
  }

  private static Id toInstanceId(String value) {
    Id rowId = Id.valueOf(value);
    if (rowId.getSobjectType() != Workflow_Instance__c.SObjectType) {
      throw new StringException('not an instance Id');
    }
    return rowId;
  }
}
