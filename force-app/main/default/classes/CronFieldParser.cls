/**
 * Parses 5-field cron expressions and individual cron fields into expanded,
 * validated integer value sets. Split out of WorkflowCronEvaluator so the
 * schedule evaluator can stay focused on fire-time walking.
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
      Set<Integer> expanded = expandPart(token, minVal, maxVal);
      if (expanded == null) {
        return null;
      }
      result.addAll(expanded);
    }

    return result.isEmpty() ? null : result;
  }

  // Expands one comma-separated token. Returns null on any error.
  private static Set<Integer> expandPart(
    String token,
    Integer minVal,
    Integer maxVal
  ) {
    if (token.contains('/')) {
      return expandStep(token, minVal, maxVal);
    }
    if (token.equals('*')) {
      return range(minVal, maxVal, 1);
    }
    if (token.contains('-')) {
      return expandRange(token, minVal, maxVal);
    }
    Integer val = tryParseInt(token);
    if (val == null || val < minVal || val > maxVal) {
      return null;
    }
    return new Set<Integer>{ val };
  }

  // Handles the step forms `a-b/n`, `*\/n` and `a/n`. Returns null on error.
  private static Set<Integer> expandStep(
    String token,
    Integer minVal,
    Integer maxVal
  ) {
    List<String> stepParts = token.split('/');
    if (stepParts.size() != 2) {
      return null;
    }
    Integer step = tryParseInt(stepParts[1]);
    if (step == null || step < 1) {
      return null;
    }
    Integer[] bounds = resolveStepBounds(stepParts[0], minVal, maxVal);
    if (bounds == null) {
      return null;
    }
    Integer rangeStart = bounds[0];
    Integer rangeEnd = bounds[1];
    if (rangeStart < minVal || rangeEnd > maxVal || rangeStart > rangeEnd) {
      return null;
    }
    return range(rangeStart, rangeEnd, step);
  }

  // Resolves [start, end] for the left side of a step token, or null on error.
  private static Integer[] resolveStepBounds(
    String left,
    Integer minVal,
    Integer maxVal
  ) {
    if (left.equals('*')) {
      return new List<Integer>{ minVal, maxVal };
    }
    if (left.contains('-')) {
      List<String> b = left.split('-');
      if (b.size() != 2) {
        return null;
      }
      Integer lo = tryParseInt(b[0]);
      Integer hi = tryParseInt(b[1]);
      if (lo == null || hi == null) {
        return null;
      }
      return new List<Integer>{ lo, hi };
    }
    Integer start = tryParseInt(left);
    if (start == null) {
      return null;
    }
    return new List<Integer>{ start, maxVal };
  }

  // Handles the range form `a-b`. Returns null on error.
  private static Set<Integer> expandRange(
    String token,
    Integer minVal,
    Integer maxVal
  ) {
    List<String> bounds = token.split('-');
    if (bounds.size() != 2) {
      return null;
    }
    Integer lo = tryParseInt(bounds[0]);
    Integer hi = tryParseInt(bounds[1]);
    if (lo == null || hi == null || lo < minVal || hi > maxVal || lo > hi) {
      return null;
    }
    return range(lo, hi, 1);
  }

  private static Set<Integer> range(
    Integer start,
    Integer endVal,
    Integer step
  ) {
    Set<Integer> result = new Set<Integer>();
    for (Integer v = start; v <= endVal; v += step) {
      result.add(v);
    }
    return result;
  }

  private static Integer tryParseInt(String s) {
    try {
      return Integer.valueOf(s.trim());
    } catch (Exception e) {
      return null;
    }
  }
}
