/**
 * Cron translation helpers lifted out of WorkflowScheduleSweeper to keep that
 * class under its complexity budget.
 *
 * Two responsibilities live here:
 *   - toSalesforceCron converts this engine's 5-field cron into the 7-field
 *     dedicated-slot format required by System.schedule, remapping day-of-week
 *     numbering and enforcing Salesforce's dom/dow mutual-exclusion rule.
 *   - nextWindow computes the strictly-next fire instant used as the 0-slot
 *     sweep cursor.
 *
 * All logic is byte-identical to the original WorkflowScheduleSweeper helpers;
 * WorkflowScheduleSweeper retains a @TestVisible toSalesforceCron delegator and
 * calls SalesforceCronTranslator.nextWindow from its cursor-advance paths.
 */
public inherited sharing class SalesforceCronTranslator {
  /**
   * @description Converts a 5-field cron (min hour dom month dow) to the 7-field Salesforce
   * format required by System.schedule: seconds minutes hours dom month dow year.
   *
   * Two Salesforce-specific translations are applied:
   *   - Day-of-week is remapped from this engine's 0–6 (0=Sun) to Salesforce's
   *     1–7 (1=Sun…7=Sat), preserving lists/ranges/steps.
   *   - Salesforce requires exactly one of dom/dow to be '?'. Because Salesforce
   *     cron has no DOM-OR-DOW semantics, a cron that restricts BOTH is rejected
   *     for dedicated mode (the 0-slot evaluator still supports it).
   * @param fiveFieldCron The 5-field cron expression to convert.
   * @return The equivalent 7-field Salesforce cron string.
   */
  public static String toSalesforceCron(String fiveFieldCron) {
    List<String> parts = fiveFieldCron.trim().split('\\s+');
    String minute = parts[0];
    String hour = parts[1];
    String dom = parts[2];
    String month = parts[3];
    String dow = parts[4];

    Boolean domRestricted = dom != '*';
    Boolean dowRestricted = dow != '*';

    if (domRestricted && dowRestricted) {
      throw new WorkflowScheduleSweeper.WorkflowScheduleException(
        'Dedicated-slot mode cannot schedule a cron that restricts BOTH day-of-month ' +
          'and day-of-week (Salesforce cron has no OR semantics). Use 0-slot mode ' +
          'for "' +
          fiveFieldCron +
          '".'
      );
    }

    String sfDom;
    String sfDow;
    if (dowRestricted) {
      sfDom = '?';
      sfDow = mapDowField(dow);
    } else {
      sfDom = dom; // '*' or a specific day-of-month
      sfDow = '?';
    }

    return '0 ' +
      minute +
      ' ' +
      hour +
      ' ' +
      sfDom +
      ' ' +
      month +
      ' ' +
      sfDow +
      ' *';
  }

  /**
   * @description Remaps a (restricted) day-of-week field from 0–6 (0=Sun) to Salesforce 1–7,
   * preserving the comma-separated list structure.
   * @param dowField The day-of-week field to remap.
   * @return The remapped comma-separated day-of-week field.
   */
  private static String mapDowField(String dowField) {
    List<String> outParts = new List<String>();
    for (String part : dowField.split(',')) {
      outParts.add(mapDowPart(part.trim()));
    }
    return String.join(outParts, ',');
  }

  /**
   * @description Remaps a single day-of-week token, preserving any step (`/n`) suffix.
   * @param part The day-of-week token (possibly stepped) to remap.
   * @return The remapped token.
   */
  private static String mapDowPart(String part) {
    if (part.contains('/')) {
      List<String> sp = part.split('/');
      return mapDowRange(sp[0]) + '/' + sp[1];
    }
    return mapDowRange(part);
  }

  /**
   * @description Remaps a day-of-week token that may be `*`, a range (`a-b`), or a single day.
   * @param token The day-of-week token to remap.
   * @return The remapped token.
   */
  private static String mapDowRange(String token) {
    if (token == '*') {
      return '*';
    }
    if (token.contains('-')) {
      List<String> b = token.split('-');
      return shiftDow(b[0]) + '-' + shiftDow(b[1]);
    }
    return shiftDow(token);
  }

  /**
   * @description Shifts a single 0–6 day-of-week value to Salesforce's 1–7 numbering.
   * @param value The 0–6 day-of-week value to shift.
   * @return The shifted 1–7 day-of-week value as a string.
   */
  private static String shiftDow(String value) {
    return String.valueOf(Integer.valueOf(value.trim()) + 1);
  }

  /**
   * @description Next fire instant STRICTLY after the handled window, or null if unknown.
   * WorkflowCronEvaluator.nextFireTime is inclusive (returns the window itself if
   * it matches), so we evaluate from one minute past the handled window — cron
   * windows are minute-granular — to guarantee the cursor advances and the row
   * rotates out of future batches.
   * @param cron The schedule's cron expression.
   * @param firedWindow The window instant just handled.
   * @return The next window strictly after firedWindow, or null when unknown.
   */
  public static DateTime nextWindow(String cron, DateTime firedWindow) {
    if (String.isBlank(cron) || firedWindow == null) {
      return null;
    }
    try {
      return WorkflowCronEvaluator.nextFireTime(
        cron,
        firedWindow.addMinutes(1)
      );
    } catch (Exception e) {
      return null;
    }
  }
}
