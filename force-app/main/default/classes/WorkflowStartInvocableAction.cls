/**
 * @description Invocable entry point that lets Flow and other declarative tools
 * start (or debounce) Revenant workflow instances, translating declarative
 * requests into WorkflowEngine or WorkflowDebouncer calls.
 */
public inherited sharing class WorkflowStartInvocableAction {
  /**
   * @description Invocable input describing one workflow to start: its name,
   * correlation key, optional input/attributes JSON, and optional debounce window.
   */
  public class StartRequest {
    @InvocableVariable(label='Workflow Name' required=true)
    public String workflowName;

    @InvocableVariable(label='Correlation Key' required=true)
    public String correlationKey;

    @InvocableVariable(label='Input JSON')
    public String inputJson;

    @InvocableVariable(label='Attributes JSON')
    public String attributesJson;

    @InvocableVariable(
      label='Causation ID'
      description='Optional causation or trace identifier linking this instance to the upstream instance/event.'
    )
    public String causationId;

    @InvocableVariable(label='Debounce Seconds')
    public Integer debounceSeconds;

    @InvocableVariable(label='Max Wait Seconds')
    public Integer maxWaitSeconds;
  }

  /**
   * @description Invocable output for one start request, carrying the resulting
   * workflow instance Id and whether it was newly created or deduplicated.
   */
  public class StartResult {
    @InvocableVariable(label='Workflow Instance ID')
    public Id workflowInstanceId;

    @InvocableVariable(
      label='Is New'
      description='True if a new instance was started; false if an existing instance was returned for a deduplicated (already-seen) correlation key.'
    )
    public Boolean isNew;

    @InvocableVariable(
      label='Is Valid'
      description='True when the start input satisfied the workflow\'s declared input contract (or the workflow declares none) and the start proceeded; false when validation rejected the input, in which case Validation Error explains why and no instance was started. Branch a Flow Decision on this.'
    )
    public Boolean isValid;

    @InvocableVariable(
      label='Validation Error'
      description='When Is Valid is false, a readable, field-level enumeration of every input-contract violation; null on success.'
    )
    public String validationError;
  }

  @InvocableMethod(
    label='Start Workflow'
    category='Revenant Workflows'
    description='Initiates a Revenant durable workflow instance'
  )
  /**
   * @description Bulk invocable that starts (or debounces) a workflow instance per
   * request and returns one result per input, positionally aligned to the requests.
   * Delegates the verb-aware get-or-start dedup routing to
   * {@link WorkflowStartInvocableRouter}: contract-valid rows batch through one
   * bulk engine call first, then invalid-input rows are delegated individually so
   * an intra-batch (or pre-existing) same-key sibling is delivered rather than the
   * row wrongly rejected; debounce rows arm a future sweep-time start.
   * @param requests The list of start requests, one per Flow invocation row.
   * @return A list of results aligned by index to the input requests.
   */
  public static List<StartResult> startWorkflow(List<StartRequest> requests) {
    if (requests == null || requests.isEmpty()) {
      return new List<StartResult>();
    }
    return WorkflowStartInvocableRouter.route(requests);
  }
}
