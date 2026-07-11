/**
 * Parses 5-field cron expressions into expanded, validated integer value sets.
 * Split out of WorkflowCronEvaluator so the schedule evaluator can stay focused
 * on fire-time walking. Per-token grammar (steps, ranges, lists, wildcards) is
 * delegated to CronFieldExpander.
 *
 * Supported syntax per field: `*`, `a`, `a,b,c`, `a-b`, `*\/n`, `a-b/n`, `a/n`.
 */
public inherited sharing class CronFieldParser {
  /**
   * Expanded, validated view of a 5-field cron expression.
   */
  public class Fields {
    public Set<Integer> minutes;
    public Set<Integer> hours;
    public Set<Integer> doms;
    public Set<Integer> months;
    public Set<Integer> dows;
    public Boolean domRestricted;
    public Boolean dowRestricted;
  }

  /**
   * Parses a whole 5-field cron expression. Returns null when the expression is
   * blank, does not have exactly 5 fields, or any field is invalid.
   */
  public static Fields parse(String cronExpr) {
    if (String.isBlank(cronExpr)) {
      return null;
    }
    List<String> parts = cronExpr.trim().split('\\s+');
    if (parts.size() != 5) {
      return null;
    }

    Fields f = new Fields();
    f.minutes = parseField(parts[0], 0, 59);
    f.hours = parseField(parts[1], 0, 23);
    f.doms = parseField(parts[2], 1, 31);
    f.months = parseField(parts[3], 1, 12);
    f.dows = parseField(parts[4], 0, 6);

    if (
      f.minutes == null ||
      f.hours == null ||
      f.doms == null ||
      f.months == null ||
      f.dows == null
    ) {
      return null;
    }

    f.domRestricted = !parts[2].equals('*');
    f.dowRestricted = !parts[4].equals('*');
    return f;
  }

  /**
   * Parses a single cron field into an expanded Set<Integer>.
   * Returns null if the field is invalid or any value is out of [minVal, maxVal].
   */
  @TestVisible
  static Set<Integer> parseField(String field, Integer minVal, Integer maxVal) {
    Set<Integer> result = new Set<Integer>();

    for (String part : field.split(',')) {
      String token = part.trim();
      if (String.isBlank(token)) {
        return null;
      }
      Set<Integer> expanded = CronFieldExpander.expand(token, minVal, maxVal);
      if (expanded == null) {
        return null;
      }
      result.addAll(expanded);
    }

    return result.isEmpty() ? null : result;
  }
}
