/**
 * Schedule input resolution and workflow-name validation, lifted out of
 * WorkflowScheduleSweeper to keep that class under its complexity budget.
 *
 * resolveInput substitutes the {{fireTime}} / {{scheduleName}} tokens into a
 * schedule's Input_Json__c and deserializes it; isValidWorkflowName rejects a
 * schedule whose Workflow_Name__c does not resolve to a WorkflowDefinition before
 * it reaches the engine. Shared by the 0-slot sweep planner, the dedicated-slot
 * fire service, and the manual run so all paths validate and resolve identically.
 *
 * Token escaping, null handling, and the Type.forName / instanceof checks are
 * byte-identical to the original WorkflowScheduleSweeper helpers.
 */
public inherited sharing class ScheduleInputResolver {
  /**
   * @description Resolves a schedule's Input_Json__c into a workflow input, substituting the
   * {{fireTime}} and {{scheduleName}} tokens. Returns null when no input is set.
   * Shared by the 0-slot sweep, run-now, and the dedicated WorkflowScheduleJob so
   * the three paths cannot drift.
   * @param sched The schedule supplying the input template.
   * @param fireTime The window instant substituted for the {{fireTime}} token.
   * @return The deserialized workflow input, or null when no input is configured.
   */
  public static Object resolveInput(
    Workflow_Schedule__c sched,
    DateTime fireTime
  ) {
    if (String.isBlank(sched.Input_Json__c)) {
      return null;
    }
    // Token values are JSON-escaped before substitution so a schedule name (or
    // any future token value) containing a quote or backslash can't produce
    // invalid JSON and abort the sweep when JSON.deserializeUntyped runs.
    String jsonStr = sched.Input_Json__c.replace(
        '{{fireTime}}',
        jsonEscape(String.valueOf(fireTime))
      )
      .replace('{{scheduleName}}', jsonEscape(sched.Name));
    return JSON.deserializeUntyped(jsonStr);
  }

  /**
   * @description Returns the JSON-escaped body of a string WITHOUT the surrounding quotes, so
   * it can be substituted into a quoted token position ("{{scheduleName}}").
   * @param raw The raw string to escape.
   * @return The escaped body without surrounding quotes, or empty string when null.
   */
  private static String jsonEscape(String raw) {
    if (raw == null) {
      return '';
    }
    String serialized = JSON.serialize(raw); // quoted + fully escaped
    return serialized.substring(1, serialized.length() - 1);
  }

  /**
   * @description True when workflowName resolves to a class that implements WorkflowDefinition.
   * Used to reject schedules pointing at a missing/typo'd definition before they
   * reach startOrGet (which would otherwise create a phantom Pending instance).
   * @param workflowName The workflow definition name to validate.
   * @return True if the name resolves to a WorkflowDefinition, false otherwise.
   */
  public static Boolean isValidWorkflowName(String workflowName) {
    if (String.isBlank(workflowName)) {
      return false;
    }
    Type wflowType = WorkflowTypeResolver.resolve(workflowName);
    if (wflowType == null) {
      return false;
    }
    try {
      return wflowType.newInstance() instanceof WorkflowDefinition;
    } catch (Exception e) {
      return false;
    }
  }
}
