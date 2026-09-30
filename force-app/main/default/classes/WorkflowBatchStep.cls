/**
 * @description Built-in WorkflowStep that runs a Database.Batchable as one
 * durable step (issue #138). The first run launches the job one time through
 * ctx.captures().once() and suspends. The watchdog resumes the instance when
 * the job ends. The next run completes with the job outcome, so
 * getNextStep() can branch on it. The Batchable needs no Revenant code.
 *
 * Input JSON (or override bind()):
 * - batchClass (String, required): the Batchable class name.
 * - scopeSize (Integer, optional): 1 to 2000. Default 200.
 * - input (Object, optional): JSON for the Batchable fields.
 * - failOnError (Boolean, optional): true fails the step when the job does
 *   not succeed. Default false (complete with the outcome).
 *
 * Output keys: jobId, status, succeeded, totalJobItems, jobItemsProcessed,
 * numberOfErrors, firstError. The counts are batches, not records.
 *
 * Security: the input names the class to launch. Do not put untrusted user
 * input in batchClass. For user input, override bind() with a fixed class.
 */
public virtual inherited sharing class WorkflowBatchStep implements WorkflowStep {
  /** @description Capture key of the launched job Id. */
  @TestVisible
  private static final String KEY_JOB_ID = 'batch_job_id';
  /** @description Capture key of the job outcome. */
  @TestVisible
  private static final String KEY_OUTCOME = 'batch_outcome';
  private static final Integer DEFAULT_SCOPE_SIZE = 200;
  private static final Integer MAX_SCOPE_SIZE = 2000;

  /**
   * @description What to launch: the Batchable class, the scope size, the
   * input and the failure rule.
   */
  public class Binding {
    /** @description The Batchable class name. */
    public final String batchClass;
    /** @description The number of records for each execute() call. */
    public final Integer scopeSize;
    /** @description The Batchable fields, or null for the no-arg constructor. */
    public final Object input;
    /** @description True fails the step when the job does not succeed. */
    public Boolean failOnError { get; private set; }

    /**
     * @description Makes a binding.
     * @param batchClass The Batchable class name. Not blank.
     * @param scopeSize 1 to 2000. Null gives 200.
     * @param input The Batchable fields as a map or an object, or null.
     */
    public Binding(String batchClass, Integer scopeSize, Object input) {
      if (String.isBlank(batchClass)) {
        throw new WorkflowEngine.WorkflowException('batchClass is required');
      }
      Integer size = scopeSize == null ? DEFAULT_SCOPE_SIZE : scopeSize;
      if (size < 1 || size > MAX_SCOPE_SIZE) {
        throw new WorkflowEngine.WorkflowException(
          'scopeSize must be an Integer from 1 to ' + MAX_SCOPE_SIZE
        );
      }
      this.batchClass = batchClass;
      this.scopeSize = size;
      this.input = input;
      this.failOnError = false;
    }

    /**
     * @description Sets the failure rule.
     * @param failOnError True fails the step when the job does not succeed.
     * @return This binding, for fluent chaining.
     */
    public Binding withFailOnError(Boolean failOnError) {
      this.failOnError = failOnError == true;
      return this;
    }
  }

  /**
   * @description Launches the job one time, waits for it, then completes
   * with its outcome.
   * @param ctx The durable step context.
   * @return SUSPEND while the job runs, then COMPLETE (or FAIL with
   * failOnError) with the outcome.
   */
  public StepResult execute(StepContext ctx) {
    Binding binding = bind(ctx);
    // One field on the instance holds one job, so a parallel branch cannot wait.
    if (WorkflowBatchJobs.inParallelBranch(ctx.workflowInstanceId)) {
      return StepResult.fail(
        'WorkflowBatchStep cannot run in a parallel branch'
      );
    }
    LaunchProducer launcher = new LaunchProducer(
      binding,
      WorkflowTypeResolver.extractNamespace(ctx.workflowName)
    );
    Id jobId;
    try {
      jobId = Id.valueOf((String) ctx.captures().once(KEY_JOB_ID, launcher));
    } catch (AsyncException ex) {
      // A platform async limit (for example a full flex queue) is temporary.
      // once() keeps nothing when the launch throws, so a retry is safe.
      return StepResult.retry(RetryPolicy.fromConfig());
    }
    // Do not add code that can throw after the launch. An auto-retry
    // rollback must not lose the captured job Id.
    if (launcher.launched) {
      return StepResult.suspend().withAwaitedBatchJob(jobId);
    }
    Map<String, Object> ended = WorkflowBatchJobs.terminalOutcome(jobId);
    if (ended == null) {
      return StepResult.suspend().withAwaitedBatchJob(jobId);
    }
    Map<String, Object> outcome = (Map<String, Object>) ctx.captures()
      .once(KEY_OUTCOME, new PinProducer(ended));
    if (binding.failOnError && outcome.get('succeeded') != true) {
      return StepResult.fail(
        'Batch job ' +
          jobId +
          ' ended with status ' +
          outcome.get('status') +
          ': ' +
          outcome.get('firstError'),
        outcome
      );
    }
    return StepResult.complete(null, outcome);
  }

  /**
   * @description Gives the binding. The default reads the step input JSON.
   * Override it to give the binding in Apex.
   * @param ctx The durable step context.
   * @return The binding.
   */
  protected virtual Binding bind(StepContext ctx) {
    Map<String, Object> inputMap = parseInput(ctx);
    Object batchClass = inputMap.get('batchClass');
    if (batchClass != null && !(batchClass instanceof String)) {
      throw new WorkflowEngine.WorkflowException('batchClass must be a String');
    }
    Object input = inputMap.get('input');
    if (input != null && !(input instanceof Map<String, Object>)) {
      throw new WorkflowEngine.WorkflowException('input must be a JSON object');
    }
    Object failOnError = inputMap.get('failOnError');
    if (failOnError != null && !(failOnError instanceof Boolean)) {
      throw new WorkflowEngine.WorkflowException(
        'failOnError must be a Boolean'
      );
    }
    return new Binding(
        (String) batchClass,
        readScopeSize(inputMap.get('scopeSize')),
        input
      )
      .withFailOnError((Boolean) failOnError);
  }

  private static Map<String, Object> parseInput(StepContext ctx) {
    if (ctx == null || String.isBlank(ctx.inputJson)) {
      throw new WorkflowEngine.WorkflowException('Input is null');
    }
    Object parsed;
    try {
      parsed = JSON.deserializeUntyped(ctx.inputJson);
    } catch (Exception ex) {
      WorkflowEngine.WorkflowException wrapper = new WorkflowEngine.WorkflowException(
        'Input must be a valid JSON object: ' + ex.getMessage()
      );
      wrapper.initCause(ex);
      throw wrapper;
    }
    if (!(parsed instanceof Map<String, Object>)) {
      throw new WorkflowEngine.WorkflowException(
        'Input must be a valid JSON object'
      );
    }
    return (Map<String, Object>) parsed;
  }

  // JSON gives an Integer for a whole number. Other types are not valid.
  private static Integer readScopeSize(Object value) {
    if (value == null) {
      return null;
    }
    if (!(value instanceof Integer)) {
      throw new WorkflowEngine.WorkflowException(
        'scopeSize must be an Integer from 1 to ' + MAX_SCOPE_SIZE
      );
    }
    return (Integer) value;
  }

  /**
   * @description Builds the Batchable and launches it. once() runs it one
   * time for each step visit.
   */
  private class LaunchProducer implements CaptureProducer {
    private final Binding binding;
    private final String namespace;
    /** @description True after produce() launched the job in this run. */
    public Boolean launched = false;

    /**
     * @description Makes the producer.
     * @param binding What to launch.
     * @param namespace The workflow namespace, for the class lookup.
     */
    public LaunchProducer(Binding binding, String namespace) {
      this.binding = binding;
      this.namespace = namespace;
    }

    /**
     * @description Launches the job.
     * @return The AsyncApexJob Id as a String.
     */
    public Object produce() {
      Type batchType = WorkflowTypeResolver.resolve(
        binding.batchClass,
        namespace
      );
      if (batchType == null) {
        throw new WorkflowEngine.WorkflowException(
          'Batch class not found: ' + binding.batchClass
        );
      }
      Id jobId;
      try {
        Object batchable = binding.input == null
          ? batchType.newInstance()
          : JSON.deserialize(JSON.serialize(binding.input), batchType);
        jobId = WorkflowBatchJobs.launch(batchable, binding.scopeSize);
      } catch (AsyncException ex) {
        throw ex;
      } catch (Exception ex) {
        WorkflowEngine.WorkflowException wrapper = new WorkflowEngine.WorkflowException(
          'Batch launch failed for ' +
            binding.batchClass +
            ': ' +
            ex.getMessage()
        );
        wrapper.initCause(ex);
        throw wrapper;
      }
      launched = true;
      return String.valueOf(jobId);
    }
  }

  /**
   * @description Keeps the first outcome read, so a replay sees the same
   * outcome after the platform deletes the job row.
   */
  private class PinProducer implements CaptureProducer {
    private final Map<String, Object> value;

    /**
     * @description Makes the producer.
     * @param value The outcome to keep.
     */
    public PinProducer(Map<String, Object> value) {
      this.value = value;
    }

    /**
     * @description Gives the outcome.
     * @return The outcome.
     */
    public Object produce() {
      return value;
    }
  }
}
