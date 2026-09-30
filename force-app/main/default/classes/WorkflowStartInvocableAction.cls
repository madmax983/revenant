/**
 * @description Invocable entry point that lets Flow and other declarative tools
 * start (or debounce) Revenant workflow instances, translating declarative
 * requests into WorkflowEngine or WorkflowDebouncer calls.
 */
global inherited sharing class WorkflowStartInvocableAction {
  /**
   * @description Blocks construction outside this class. Without an explicit
   * constructor, a global class gets a default constructor that subscribers
   * can call (issue #122).
   */
  private WorkflowStartInvocableAction() {
    // No state to set.
  }

  /**
   * @description Invocable input describing one workflow to start: its name,
   * correlation key, optional input/attributes JSON, and optional debounce window.
   */
  global class StartRequest {
    @InvocableVariable(label='Workflow Name' required=true)
    global String workflowName;

    @InvocableVariable(label='Correlation Key' required=true)
    global String correlationKey;

    @InvocableVariable(label='Input JSON')
    global String inputJson;

    @InvocableVariable(label='Attributes JSON')
    global String attributesJson;

    @InvocableVariable(
      label='Causation ID'
      description='Optional causation or trace identifier linking this instance to the upstream instance/event.'
    )
    global String causationId;

    @InvocableVariable(
      label='Priority'
      description='Optional admission priority, 0 to 9. The gate admits a higher value sooner under a concurrency ceiling. Blank uses the configured priority. Debounced starts ignore this value.'
    )
    global Integer priority;

    @InvocableVariable(
      label='Debounce Seconds'
      description='Optional. The action waits until no trigger occurs for this many seconds. Then it starts the workflow one time with the last input. Blank starts the workflow immediately. 0 starts it at the next watchdog sweep.'
    )
    global Integer debounceSeconds;

    @InvocableVariable(
      label='Max Wait Seconds'
      description='Optional. Use with Debounce Seconds. The workflow starts not later than this many seconds after the first trigger. Blank or 0 gives no cap.'
    )
    global Integer maxWaitSeconds;
  }

  /**
   * @description Invocable output for one start request, carrying the resulting
   * workflow instance Id and whether it was newly created or deduplicated.
   */
  global class StartResult {
    /**
     * @description Keeps construction in the package namespace. Without an
     * explicit constructor, a global class gets a global default
     * constructor (issue #122).
     */
    public StartResult() {
      // No state to set.
    }

    @InvocableVariable(label='Workflow Instance ID')
    global Id workflowInstanceId;

    @InvocableVariable(
      label='Is New'
      description='True if a new instance was started; false if an existing instance was returned for a deduplicated (already-seen) correlation key.'
    )
    global Boolean isNew;

    @InvocableVariable(
      label='Is Valid'
      description='True when the start input satisfied the workflow\'s declared input contract (or the workflow declares none) and the start proceeded; false when validation rejected the input, in which case Validation Error explains why and no instance was started. Branch a Flow Decision on this.'
    )
    global Boolean isValid;

    @InvocableVariable(
      label='Validation Error'
      description='When Is Valid is false, a readable, field-level enumeration of every input-contract violation; null on success.'
    )
    global String validationError;
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
  global static List<StartResult> startWorkflow(List<StartRequest> requests) {
    if (requests == null || requests.isEmpty()) {
      return new List<StartResult>();
    }
    return WorkflowStartInvocableRouter.route(requests);
  }
}
