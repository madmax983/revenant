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
public inherited sharing class WorkflowArchiveRecord {
  /** @description Stored in place of an offloaded payload that was not copied. */
  public static final String DROPPED_MARKER = '{"$archiveDropped":"offloaded payload not archived"}';

  /** @description Id of the purged `Workflow_Instance__c`. */
  public Id instanceId;
  /** @description Workflow definition name. */
  public String workflowName;
  /** @description Correlation key of the instance. */
  public String correlationKey;
  /** @description Terminal instance status. */
  public String status;
  /** @description Instance error message, or null. */
  public String errorMessage;
  /** @description Failure category, or null. */
  public String failureCategory;
  /** @description Parent instance Id, or null. */
  public Id parentInstanceId;
  /** @description Time the instance was created. */
  public Datetime createdAt;
  /** @description Time the instance became terminal, or null. */
  public Datetime terminalAt;
  /** @description Time the sweep archived the instance. */
  public Datetime archivedAt;
  /** @description Stored form of the workflow input, or null. */
  public String input;
  /** @description Stored form of the workflow output, or null. */
  public String output;
  /** @description Number of offloaded payloads replaced by the marker. */
  public Integer droppedPayloadCount = 0;
  /** @description Number of steps the sweep archived. */
  public Integer stepCount = 0;
  /** @description Steps in execution order. */
  public List<Step> steps = new List<Step>();

  /**
   * @description Returns true when the reader got fewer steps than the sweep
   * archived.
   * @return true when `steps` is not complete
   */
  public Boolean isTruncated() {
    return steps.size() < (stepCount == null ? 0 : stepCount);
  }

  /**
   * @description One archived step execution.
   */
  public class Step {
    /** @description Position in the timeline. The first step is 1. */
    public Integer sequence;
    /** @description Id of the purged `Workflow_Step_Execution__c` row. */
    public Id executionId;
    /** @description Step name. */
    public String stepName;
    /** @description Step status. */
    public String status;
    /** @description Retry attempt count. 0 on the first attempt. */
    public Integer attempt;
    /** @description Time the step row was created. */
    public Datetime startedAt;
    /** @description Time the step ended, or null when it did not end. */
    public Datetime endedAt;
    /** @description Stored form of the step error details, or null. */
    public String errorDetails;

    /**
     * @description Returns the wall-clock time of the step.
     * @return milliseconds from `startedAt` to `endedAt`, or null
     */
    public Long totalDurationMs() {
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
    public Boolean isCompensation() {
      return stepName != null && stepName.endsWith('_Compensate');
    }
  }
}
