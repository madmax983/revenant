/**
 * @description Computes and compares the shape fingerprint of a workflow
 * definition (issue #89). The shape is the ordered `getSteps()` list. The
 * fingerprint is `v1:` plus the SHA-256 hex digest of the lower-case, trimmed
 * step names, one per line. All methods are in memory: no SOQL, no DML.
 * Compute errors fail open: the result is null, which means "unknown".
 */
public inherited sharing class WorkflowDefinitionFingerprint {
  /**
   * @description Algorithm version prefix. A stored fingerprint with another
   * prefix is "unknown", so a future algorithm change never halts instances.
   */
  public static final String VERSION_PREFIX = 'v1:';

  // Max length of Workflow_Instance__c.Definition_Shape__c.
  private static final Integer MAX_SHAPE_LENGTH = 32768;

  /**
   * @description Result of a stored-versus-live compare.
   * MATCH: shapes are equal. UNKNOWN: no usable stored or live value.
   * ADVISORY: shapes differ on a VersionedWorkflow (log only).
   * HALT: shapes differ on a plain definition (park).
   */
  public enum Verdict {
    MATCH,
    UNKNOWN,
    ADVISORY,
    HALT
  }

  /**
   * @description Computes the fingerprint of a step list. A null list is the
   * same as an empty list. A null name is the same as a blank name.
   * @param steps The ordered step names.
   * @return The versioned fingerprint.
   */
  public static String compute(List<String> steps) {
    List<String> normalized = new List<String>();
    if (steps != null) {
      for (String step : steps) {
        normalized.add(step == null ? '' : step.trim().toLowerCase());
      }
    }
    Blob digest = Crypto.generateDigest(
      'SHA-256',
      Blob.valueOf(String.join(normalized, '\n'))
    );
    return VERSION_PREFIX + EncodingUtil.convertToHex(digest);
  }

  /**
   * @description Serializes a step list for Definition_Shape__c.
   * @param steps The ordered step names.
   * @return The JSON list, or null when it does not fit the field.
   */
  public static String shapeJson(List<String> steps) {
    String json = JSON.serialize(steps == null ? new List<String>() : steps);
    return json.length() > MAX_SHAPE_LENGTH ? null : json;
  }

  /**
   * @description Parses a Definition_Shape__c value.
   * @param shape The stored JSON list.
   * @return The step names, or null when the value is blank or not valid.
   */
  public static List<String> parseShape(String shape) {
    if (String.isBlank(shape)) {
      return null;
    }
    try {
      return (List<String>) JSON.deserialize(shape, List<String>.class);
    } catch (Exception ex) {
      return null;
    }
  }

  /**
   * @description Writes the fingerprint and shape of a definition on an
   * unsaved instance. Fails open: on any error the fields stay blank.
   * @param instance The instance to stamp.
   * @param defObj The definition object (any type is accepted).
   */
  public static void stamp(Workflow_Instance__c instance, Object defObj) {
    if (instance == null || !(defObj instanceof WorkflowDefinition)) {
      return;
    }
    try {
      List<String> steps = ((WorkflowDefinition) defObj).getSteps();
      instance.Definition_Fingerprint__c = compute(steps);
      instance.Definition_Shape__c = shapeJson(steps);
    } catch (Exception ex) {
      System.debug(
        LoggingLevel.WARN,
        'Definition fingerprint not stamped: ' + ex.getMessage()
      );
    }
  }

  /**
   * @description Compares a stored fingerprint to a live fingerprint.
   * @param stored The fingerprint written at start.
   * @param live The fingerprint of the deployed definition.
   * @param isVersioned True when the definition is a VersionedWorkflow.
   * @return The verdict. See the decision table in the issue #89 plan.
   */
  public static Verdict compare(
    String stored,
    String live,
    Boolean isVersioned
  ) {
    if (String.isBlank(stored) || String.isBlank(live)) {
      return Verdict.UNKNOWN;
    }
    if (stored.substringBefore(':') != live.substringBefore(':')) {
      return Verdict.UNKNOWN;
    }
    if (stored.equals(live)) {
      return Verdict.MATCH;
    }
    return isVersioned == true ? Verdict.ADVISORY : Verdict.HALT;
  }

  /**
   * @description Returns the live fingerprint of a workflow by name. Fails
   * open.
   * @param workflowName The definition class name.
   * @return The fingerprint, or null when the class does not resolve or
   * getSteps() throws.
   */
  public static String liveFingerprint(String workflowName) {
    List<String> steps = liveSteps(resolve(workflowName));
    return steps == null ? null : compute(steps);
  }

  /**
   * @description Returns the live step list of a definition. Fails open.
   * @param def The definition, or null.
   * @return The step names, or null when def is null or getSteps() throws.
   */
  public static List<String> liveSteps(WorkflowDefinition def) {
    if (def == null) {
      return null;
    }
    try {
      List<String> steps = def.getSteps();
      return steps == null ? new List<String>() : steps;
    } catch (Exception ex) {
      return null;
    }
  }

  /**
   * @description Resolves and creates a definition by name. Fails open.
   * @param workflowName The definition class name.
   * @return The definition, or null when it does not resolve.
   */
  public static WorkflowDefinition resolve(String workflowName) {
    if (String.isBlank(workflowName)) {
      return null;
    }
    try {
      Type wfType = WorkflowTypeResolver.resolve(
        workflowName,
        WorkflowTypeResolver.extractNamespace(workflowName)
      );
      if (wfType == null) {
        return null;
      }
      Object defObj = wfType.newInstance();
      return defObj instanceof WorkflowDefinition
        ? (WorkflowDefinition) defObj
        : null;
    } catch (Exception ex) {
      return null;
    }
  }
}
