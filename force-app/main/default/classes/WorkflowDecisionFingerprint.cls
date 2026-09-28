/**
 * @description Pure helpers for strict determinism mode (issue #102). Builds
 * the routing-decision text of a StepResult, digests text with SHA-256, and
 * encodes and parses the Decision_Record__c value. No SOQL. No DML.
 *
 * The decision text holds routing data only: the action, the next step, the
 * split and child targets, the approval key and role, the timeout route and
 * the compensation flag. It does not include payloads, step state or
 * durations. Each value is JSON, so a delimiter in a value cannot make two
 * decisions look equal. The class sorts the targets. Thus, a change in order
 * does not change the text.
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
    if (result == null || result.directive().action == null) {
      return 'NULL';
    }
    StepResult.StepDirective d = result.directive();
    String action = d.action.name();
    switch on d.action {
      when COMPLETE {
        return action +
          ' next=' +
          quote(d.nextStepName) +
          ' compensate=' +
          (compensatable == true);
      }
      when SPLIT {
        return action + ' targets=' + sortedJson(d.parallelStepNames);
      }
      when SUSPEND {
        return action + ' timeout=' + quote(d.timeout.step);
      }
      when WAIT_FOR_APPROVAL {
        return action +
          ' key=' +
          quote(d.approvalKey) +
          ' role=' +
          quote(d.approvalRole) +
          ' timeout=' +
          quote(d.timeout.step);
      }
      when START_CHILD {
        return action +
          ' child=' +
          childTarget(d.childWorkflowName, d.childCorrelationKey);
      }
      when START_CHILDREN {
        return action + ' children=' + childTargets(d.childRequests);
      }
      when else {
        return action;
      }
    }
  }

  /**
   * @description Tells if an action is a wait that the engine records.
   * @param action The action.
   * @return True for SUSPEND, WAIT_FOR_APPROVAL, START_CHILD, START_CHILDREN.
   */
  public static Boolean isWait(StepResult.ActionType action) {
    return action == StepResult.ActionType.SUSPEND ||
      action == StepResult.ActionType.WAIT_FOR_APPROVAL ||
      action == StepResult.ActionType.START_CHILD ||
      action == StepResult.ActionType.START_CHILDREN;
  }

  /**
   * @description Digests text with SHA-256.
   * @param text The text. Null is the same as empty.
   * @return The lower-case hex digest.
   */
  public static String digest(String text) {
    return EncodingUtil.convertToHex(
      Crypto.generateDigest('SHA-256', Blob.valueOf(text == null ? '' : text))
    );
  }

  /**
   * @description Builds a Decision_Record__c value. The hash covers the full
   * decision text. The summary keeps only the first MAX_SUMMARY_LENGTH chars.
   * @param inputs The inputs digest.
   * @param decision The decision text.
   * @return The JSON record.
   */
  public static String toRecordJson(String inputs, String decision) {
    return JSON.serialize(
      new Map<String, Object>{
        'v' => RECORD_VERSION,
        'inputs' => inputs,
        'decisionHash' => digest(decision),
        'decision' => decision == null
          ? null
          : decision.left(MAX_SUMMARY_LENGTH)
      }
    );
  }

  /**
   * @description Reads a Decision_Record__c value.
   * @param raw The stored value.
   * @return The record, or null when blank, not valid or of another version.
   */
  public static Record parseRecord(String raw) {
    if (String.isBlank(raw)) {
      return null;
    }
    try {
      Object parsed = JSON.deserializeUntyped(raw);
      if (!(parsed instanceof Map<String, Object>)) {
        return null;
      }
      Map<String, Object> m = (Map<String, Object>) parsed;
      Object version = m.get('v');
      if (
        !(version instanceof Integer) || (Integer) version != RECORD_VERSION
      ) {
        return null;
      }
      Record rec = new Record();
      rec.inputs = (String) m.get('inputs');
      rec.decisionHash = (String) m.get('decisionHash');
      rec.decision = (String) m.get('decision');
      return String.isBlank(rec.inputs) || String.isBlank(rec.decisionHash)
        ? null
        : rec;
    } catch (Exception ex) {
      return null;
    }
  }

  // A JSON string (or null) has no ambiguous delimiter.
  private static String quote(String value) {
    return JSON.serialize(value);
  }

  private static String childTarget(String workflowName, String key) {
    return JSON.serialize(new List<String>{ workflowName, key });
  }

  private static String childTargets(List<StepResult.ChildRequest> requests) {
    List<String> targets = new List<String>();
    if (requests != null) {
      for (StepResult.ChildRequest req : requests) {
        if (req != null) {
          targets.add(childTarget(req.workflowName, req.correlationKey));
        }
      }
    }
    targets.sort();
    return '[' + String.join(targets, ',') + ']';
  }

  private static String sortedJson(List<String> values) {
    List<String> copy = values == null
      ? new List<String>()
      : new List<String>(values);
    copy.sort();
    return JSON.serialize(copy);
  }
}
