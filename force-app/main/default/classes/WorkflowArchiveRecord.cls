/**
 * @description Archived history of one terminal workflow instance: the
 * instance outcome and its ordered step timeline. Sinks store it. Readers get
 * it from {@link WorkflowArchive}.
 *
 * Each {@link Step} holds the same facts as
 * {@link WorkflowEngine.StepHistoryEntry}.
 *
 * Payload policy: `input`, `output` and `Step.errorDetails` hold the stored
 * form (codec ciphertext stays ciphertext). An offloaded payload is not
 * copied. It becomes {@link #DROPPED_MARKER} and adds 1 to
 * `droppedPayloadCount`.
 */
global inherited sharing class WorkflowArchiveRecord {
  /** @description Stored in place of an offloaded payload that was not copied. */
  global static final String DROPPED_MARKER = '{"$archiveDropped":"offloaded payload not archived"}';

  /** @description Id of the purged `Workflow_Instance__c`. */
  global Id instanceId;
  /** @description Workflow definition name. */
  global String workflowName;
  /** @description Correlation key of the instance. */
  global String correlationKey;
  /** @description Terminal instance status. */
  global String status;
  /** @description Instance error message, or null. */
  global String errorMessage;
  /** @description Failure category, or null. */
  global String failureCategory;
  /** @description Parent instance Id, or null. */
  global Id parentInstanceId;
  /** @description Time the instance was created. */
  global Datetime createdAt;
  /** @description Time the instance became terminal, or null. */
  global Datetime terminalAt;
  /** @description Time the sweep archived the instance. */
  global Datetime archivedAt;
  /** @description Stored form of the workflow input, or null. */
  global String input;
  /** @description Stored form of the workflow output, or null. */
  global String output;
  /** @description Number of offloaded payloads replaced by the marker. */
  global Integer droppedPayloadCount = 0;
  /** @description Number of steps the sweep archived. */
  global Integer stepCount = 0;
  /** @description Steps in execution order. */
  global List<Step> steps = new List<Step>();

  /**
   * @description Returns true when the reader got fewer steps than the sweep
   * archived.
   * @return true when `steps` is not complete
   */
  global Boolean isTruncated() {
    return steps.size() < (stepCount == null ? 0 : stepCount);
  }

  /**
   * @description One archived step execution.
   */
  global class Step {
    /** @description Position in the timeline. The first step is 1. */
    global Integer sequence;
    /** @description Id of the purged `Workflow_Step_Execution__c` row. */
    global Id executionId;
    /** @description Step name. */
    global String stepName;
    /** @description Step status. */
    global String status;
    /** @description Retry attempt count. 0 on the first attempt. */
    global Integer attempt;
    /** @description Time the step row was created. */
    global Datetime startedAt;
    /** @description Time the step ended, or null when it did not end. */
    global Datetime endedAt;
    /** @description Stored form of the step error details, or null. */
    global String errorDetails;

    /**
     * @description Returns the wall-clock time of the step.
     * @return milliseconds from `startedAt` to `endedAt`, or null
     */
    global Long totalDurationMs() {
      return (startedAt == null ||
        endedAt == null)
        ? null
        : endedAt.getTime() - startedAt.getTime();
    }

    /**
     * @description Returns true for a compensation step. Same rule as
     * {@link WorkflowEngine.StepHistoryEntry#isCompensation}.
     * @return true when the step name ends in `_Compensate`
     */
    global Boolean isCompensation() {
      return stepName != null && stepName.endsWith('_Compensate');
    }
  }
}
