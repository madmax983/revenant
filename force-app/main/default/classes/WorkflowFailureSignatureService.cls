/**
 * @description Groups failed step executions by step name and normalized error signature,
 * rendering the per-step breakdown rows for the dashboard. Extracted from
 * WorkflowFailureBreakdownService to keep each class under the complexity thresholds; the
 * signature normalization (UUID/date/id/number masking) lives here.
 */
public inherited sharing class WorkflowFailureSignatureService {
  /**
   * @description Groups the given failed step executions by step name (and, within a step,
   * by normalized error signature) and renders the sorted per-step breakdown rows.
   * @param steps The failed step executions to group.
   * @return One map per step, worst-first, each carrying its error-signature groups.
   */
  public static List<Map<String, Object>> groupToMaps(
    List<Workflow_Step_Execution__c> steps
  ) {
    List<StepFailureGroup> sortedSteps = groupFailuresByStep(steps);
    List<Map<String, Object>> stepList = new List<Map<String, Object>>();
    for (StepFailureGroup sg : sortedSteps) {
      stepList.add(sg.toMap());
    }
    return stepList;
  }

  private static List<StepFailureGroup> groupFailuresByStep(
    List<Workflow_Step_Execution__c> steps
  ) {
    Map<String, StepFailureGroup> stepGroups = new Map<String, StepFailureGroup>();
    for (Workflow_Step_Execution__c se : steps) {
      String stepName = String.isBlank(se.Step_Name__c)
        ? 'Unknown Step'
        : se.Step_Name__c;
      StepFailureGroup stepGroup = stepGroups.get(stepName);
      if (stepGroup == null) {
        stepGroup = new StepFailureGroup(stepName);
        stepGroups.put(stepName, stepGroup);
      }
      stepGroup.addFailure(se);
    }
    List<StepFailureGroup> sortedSteps = stepGroups.values();
    sortedSteps.sort();
    return sortedSteps;
  }

  @TestVisible
  private static String getNormalizedSignature(String errorDetails) {
    if (String.isBlank(errorDetails)) {
      return 'Unknown Error';
    }
    String normalized = errorDetails.split('\n')[0];
    if (String.isBlank(normalized)) {
      normalized = 'Unknown Error';
    }

    // Normalize UUIDs
    normalized = normalized.replaceAll(
      '\\b[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}\\b',
      '[UUID]'
    );

    // Normalize Datetimes
    normalized = normalized.replaceAll(
      '\\b\\d{4}-\\d{2}-\\d{2}[T ]\\d{2}:\\d{2}:\\d{2}(?:\\.\\d+)?(?:Z|[+-]\\d{2}:?\\d{2})?\\b',
      '[DATETIME]'
    );

    // Normalize Dates
    normalized = normalized.replaceAll('\\b\\d{4}-\\d{2}-\\d{2}\\b', '[DATE]');

    // Normalize Salesforce IDs containing at least one digit
    normalized = normalized.replaceAll(
      '\\b(?=[a-zA-Z0-9]*[0-9])[a-zA-Z0-9]{15,18}\\b',
      '[ID]'
    );

    // Normalize standalone numbers
    normalized = normalized.replaceAll('\\b\\d+\\b', '[NUM]');

    normalized = normalized.trim();
    if (normalized.length() > 255) {
      normalized = normalized.substring(0, 252) + '...';
    }

    return normalized;
  }

  private class StepFailureGroup implements Comparable {
    String stepName;
    Integer failureCount = 0;
    Map<String, SignatureGroup> signatures = new Map<String, SignatureGroup>();

    StepFailureGroup(String stepName) {
      this.stepName = stepName;
    }

    void addFailure(Workflow_Step_Execution__c se) {
      this.failureCount++;
      String sig = getNormalizedSignature(se.Error_Details__c);
      SignatureGroup sigGroup = signatures.get(sig);
      if (sigGroup == null) {
        sigGroup = new SignatureGroup(sig);
        signatures.put(sig, sigGroup);
      }
      sigGroup.addOccurrence(se);
    }

    Map<String, Object> toMap() {
      List<SignatureGroup> sortedSigs = signatures.values();
      sortedSigs.sort();

      List<Map<String, Object>> sigList = new List<Map<String, Object>>();
      for (SignatureGroup sg : sortedSigs) {
        sigList.add(sg.toMap());
      }

      return new Map<String, Object>{
        'stepName' => stepName,
        'failureCount' => failureCount,
        'errorSignatures' => sigList
      };
    }

    /**
     * @description Orders step groups worst-first: higher failure count first, ties broken
     * by step name.
     * @param other The other StepFailureGroup to compare against.
     * @return A negative, zero, or positive value per the Comparable contract.
     */
    public Integer compareTo(Object other) {
      StepFailureGroup that = (StepFailureGroup) other;
      if (this.failureCount != that.failureCount) {
        return that.failureCount - this.failureCount; // higher failures first
      }
      return this.stepName.compareTo(that.stepName);
    }
  }

  private class SignatureGroup implements Comparable {
    String signature;
    Integer count = 0;
    List<Map<String, String>> examples = new List<Map<String, String>>();
    Set<Id> exampleInstanceIds = new Set<Id>();

    SignatureGroup(String signature) {
      this.signature = signature;
    }

    void addOccurrence(Workflow_Step_Execution__c se) {
      this.count++;
      if (
        examples.size() < 5 &&
        se.Workflow_Instance__c != null &&
        !exampleInstanceIds.contains(se.Workflow_Instance__c)
      ) {
        exampleInstanceIds.add(se.Workflow_Instance__c);
        examples.add(
          new Map<String, String>{
            'id' => se.Workflow_Instance__c,
            'name' => se.Workflow_Instance__r.Name
          }
        );
      }
    }

    Map<String, Object> toMap() {
      return new Map<String, Object>{
        'signature' => signature,
        'count' => count,
        'examples' => examples
      };
    }

    /**
     * @description Orders error-signature groups worst-first: higher occurrence count
     * first, ties broken by the signature text.
     * @param other The other SignatureGroup to compare against.
     * @return A negative, zero, or positive value per the Comparable contract.
     */
    public Integer compareTo(Object other) {
      SignatureGroup that = (SignatureGroup) other;
      if (this.count != that.count) {
        return that.count - this.count; // higher counts first
      }
      return this.signature.compareTo(that.signature);
    }
  }
}
