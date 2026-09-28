/**
 * @description CSV form of a {@link WorkflowArchiveRecord} (RFC 4180). Line 1
 * is {@link #HEADER}. Line 2 is the instance row. Each next line is one step.
 * Times are ISO 8601 UTC. A blank field reads as null.
 *
 * Spreadsheet safety: a value that starts with `=`, `+`, `-`, `@`, a tab, a
 * carriage return or `'` gets a `'` prefix. The parser removes it again.
 */
public inherited sharing class WorkflowArchiveCsv {
  /** @description The CSV header line. */
  public static final String HEADER = 'row_type,sequence,instance_id,execution_id,workflow_name,correlation_key,status,step_name,attempt,started_at,ended_at,archived_at,error,failure_category,parent_instance_id,input,output,dropped_payload_count,step_count';

  private static final Integer COLUMNS = HEADER.split(',').size();
  private static final String ROW_INSTANCE = 'instance';
  private static final String ROW_STEP = 'step';
  private static final String TIME_FORMAT = 'yyyy-MM-dd\'T\'HH:mm:ss.SSS\'Z\'';
  private static final Set<String> FORMULA_STARTS = new Set<String>{
    '=',
    '+',
    '-',
    '@',
    '\t',
    '\r',
    '\''
  };
  private static final Integer QUOTE = '"'.charAt(0);
  private static final Integer COMMA = ','.charAt(0);
  private static final Integer CR = '\r'.charAt(0);
  private static final Integer LF = '\n'.charAt(0);

  /**
   * @description Writes a record as CSV.
   * @param r the record
   * @return the CSV text
   */
  public static String toCsv(WorkflowArchiveRecord r) {
    List<String> lines = new List<String>{ HEADER };
    lines.add(
      line(
        new List<Object>{
          ROW_INSTANCE,
          0,
          r.instanceId,
          null,
          r.workflowName,
          r.correlationKey,
          r.status,
          null,
          null,
          r.createdAt,
          r.terminalAt,
          r.archivedAt,
          r.errorMessage,
          r.failureCategory,
          r.parentInstanceId,
          r.input,
          r.output,
          r.droppedPayloadCount,
          r.stepCount
        }
      )
    );
    for (WorkflowArchiveRecord.Step s : r.steps) {
      lines.add(
        line(
          new List<Object>{
            ROW_STEP,
            s.sequence,
            r.instanceId,
            s.executionId,
            null,
            null,
            s.status,
            s.stepName,
            s.attempt,
            s.startedAt,
            s.endedAt,
            null,
            s.errorDetails,
            null,
            null,
            null,
            null,
            null,
            null
          }
        )
      );
    }
    return String.join(lines, '\r\n') + '\r\n';
  }

  /**
   * @description Reads a record from CSV that {@link #toCsv} wrote.
   * @param csv the CSV text
   * @return the record
   * @throws WorkflowArchive.ArchiveException when the CSV is not valid
   */
  public static WorkflowArchiveRecord fromCsv(String csv) {
    List<List<String>> rows = parse(csv);
    if (
      rows.size() < 2 ||
      String.join(rows[0], ',') != HEADER ||
      rows[1].size() != COLUMNS ||
      rows[1][0] != ROW_INSTANCE
    ) {
      throw new WorkflowArchive.ArchiveException('Not a workflow archive CSV');
    }
    List<String> h = rows[1];
    WorkflowArchiveRecord r = new WorkflowArchiveRecord();
    r.instanceId = toId(h[2]);
    r.workflowName = text(h[4]);
    r.correlationKey = text(h[5]);
    r.status = text(h[6]);
    r.createdAt = toTime(h[9]);
    r.terminalAt = toTime(h[10]);
    r.archivedAt = toTime(h[11]);
    r.errorMessage = text(h[12]);
    r.failureCategory = text(h[13]);
    r.parentInstanceId = toId(h[14]);
    r.input = text(h[15]);
    r.output = text(h[16]);
    r.droppedPayloadCount = toInt(h[17]);
    r.stepCount = toInt(h[18]);
    for (Integer i = 2; i < rows.size(); i++) {
      r.steps.add(toStep(rows[i]));
    }
    return r;
  }

  /**
   * @description Parses RFC 4180 CSV into rows of fields. Accepts CRLF and LF.
   * @param csv the CSV text
   * @return the rows
   * @throws WorkflowArchive.ArchiveException for an open quoted field
   */
  @TestVisible
  private static List<List<String>> parse(String csv) {
    List<List<String>> rows = new List<List<String>>();
    Integer n = csv == null ? 0 : csv.length();
    Integer i = 0;
    List<String> row = new List<String>();
    while (i < n) {
      Integer[] cursor = new List<Integer>{ i };
      row.add(
        csv.charAt(i) == QUOTE
          ? quotedField(csv, cursor)
          : plainField(csv, cursor)
      );
      i = cursor[0];
      if (i >= n) {
        rows.add(row);
        break;
      }
      Integer c = csv.charAt(i);
      i++;
      if (c == COMMA) {
        if (i == n) {
          row.add('');
          rows.add(row);
        }
        continue;
      }
      if (c == CR && i < n && csv.charAt(i) == LF) {
        i++;
      }
      if (c != CR && c != LF) {
        throw new WorkflowArchive.ArchiveException(
          'Bad CSV text after a quoted field'
        );
      }
      rows.add(row);
      row = new List<String>();
    }
    return rows;
  }

  private static String quotedField(String csv, Integer[] cursor) {
    List<String> parts = new List<String>();
    Integer j = cursor[0] + 1;
    Integer k = csv.indexOf('"', j);
    // A doubled quote is one literal quote. A single quote ends the field.
    while (k >= 0 && k + 1 < csv.length() && csv.charAt(k + 1) == QUOTE) {
      parts.add(csv.substring(j, k + 1));
      j = k + 2;
      k = csv.indexOf('"', j);
    }
    if (k < 0) {
      throw new WorkflowArchive.ArchiveException('Open quoted CSV field');
    }
    parts.add(csv.substring(j, k));
    cursor[0] = k + 1;
    return String.join(parts, '');
  }

  private static String plainField(String csv, Integer[] cursor) {
    Integer start = cursor[0];
    Integer stop = csv.length();
    for (String delimiter : new List<String>{ ',', '\n', '\r' }) {
      Integer at = csv.indexOf(delimiter, start);
      if (at >= 0 && at < stop) {
        stop = at;
      }
    }
    cursor[0] = stop;
    return csv.substring(start, stop);
  }

  private static String line(List<Object> values) {
    List<String> cells = new List<String>();
    for (Object v : values) {
      cells.add(cell(v));
    }
    return String.join(cells, ',');
  }

  private static String cell(Object value) {
    if (value == null) {
      return '';
    }
    String s = value instanceof Datetime
      ? ((Datetime) value).formatGmt(TIME_FORMAT)
      : String.valueOf(value);
    if (s.length() > 0 && FORMULA_STARTS.contains(s.left(1))) {
      s = '\'' + s;
    }
    if (s.containsAny(',"\r\n')) {
      s = '"' + s.replace('"', '""') + '"';
    }
    return s;
  }

  private static WorkflowArchiveRecord.Step toStep(List<String> row) {
    if (row.size() != COLUMNS || row[0] != ROW_STEP) {
      throw new WorkflowArchive.ArchiveException('Bad archive CSV step row');
    }
    WorkflowArchiveRecord.Step s = new WorkflowArchiveRecord.Step();
    s.sequence = toInt(row[1]);
    s.executionId = toId(row[3]);
    s.status = text(row[6]);
    s.stepName = text(row[7]);
    s.attempt = toInt(row[8]);
    s.startedAt = toTime(row[9]);
    s.endedAt = toTime(row[10]);
    s.errorDetails = text(row[12]);
    return s;
  }

  private static String text(String cellValue) {
    if (String.isEmpty(cellValue)) {
      return null;
    }
    return cellValue.startsWith('\'') ? cellValue.substring(1) : cellValue;
  }

  private static Id toId(String cellValue) {
    String s = text(cellValue);
    return s == null ? null : Id.valueOf(s);
  }

  private static Integer toInt(String cellValue) {
    String s = text(cellValue);
    return s == null ? null : Integer.valueOf(s);
  }

  private static Datetime toTime(String cellValue) {
    String s = text(cellValue);
    return s == null
      ? null
      : (Datetime) JSON.deserialize('"' + s + '"', Datetime.class);
  }
}
