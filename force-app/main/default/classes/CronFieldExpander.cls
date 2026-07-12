/**
 * Expands a single cron field token into a validated Set<Integer>. Split out of
 * CronFieldParser so the field-level grammar (steps, ranges, lists, wildcards)
 * lives apart from the 5-field expression assembly, keeping each class's
 * aggregate complexity small.
 *
 * Supported token syntax: `*`, `a`, `a-b`, `*\/n`, `a-b/n`, `a/n`.
 */
public inherited sharing class CronFieldExpander {
  /**
   * @description Expands one cron field token into its value set within
   * [minVal, maxVal], handling wildcard, literal, range, and step forms.
   * @param token The single cron field token to expand (e.g. `*`, `a`, `a-b`, `a/n`).
   * @param minVal The inclusive lower bound legal for this field.
   * @param maxVal The inclusive upper bound legal for this field.
   * @return The set of matched values, or null if the token is unparseable or out of range.
   */
  public static Set<Integer> expand(
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
