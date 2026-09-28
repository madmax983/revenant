/**
 * @description Pure helpers for strict determinism mode (issue #102). Builds
 * the routing-decision text of a StepResult, digests text with SHA-256, and
 * reads and writes Decision_Record__c. No SOQL. No DML.
 */
public inherited sharing class WorkflowDecisionFingerprint {
  /** @description Version of the Decision_Record__c format. */
  public static final Integer RECORD_VERSION = 1;
  /** @description Max length of the decision summary in a record. */
  public static final Integer MAX_SUMMARY_LENGTH = 255;

  /**
   * @description A parsed Decision_Record__c value.
   */
  public class Record {
    /** @description Digest of the step inputs when the decision was made. */
    public String inputs;
    /** @description Digest of the full decision text. */
    public String decisionHash;
    /** @description Short decision text for operators. */
    public String decision;
  }

  /**
   * @description Builds the routing-decision text of a result.
   * @param result The step result.
   * @param compensatable True when the step is a CompensatableStep.
   * @return The decision text.
   */
  public static String describe(StepResult result, Boolean compensatable) {
    return null;
  }

  /**
   * @description Tells if an action is a wait that the engine records.
   * @param action The action.
   * @return True for SUSPEND, WAIT_FOR_APPROVAL, START_CHILD, START_CHILDREN.
   */
  public static Boolean isWait(StepResult.ActionType action) {
    return false;
  }

  /**
   * @description Digests text with SHA-256.
   * @param text The text. Null is the same as empty.
   * @return The lower-case hex digest.
   */
  public static String digest(String text) {
    return null;
  }

  /**
   * @description Builds a Decision_Record__c value.
   * @param inputs The inputs digest.
   * @param decision The decision text.
   * @return The JSON record.
   */
  public static String toRecordJson(String inputs, String decision) {
    return null;
  }

  /**
   * @description Reads a Decision_Record__c value.
   * @param raw The stored value.
   * @return The record, or null when blank, not valid or of another version.
   */
  public static Record parseRecord(String raw) {
    return null;
  }
}
