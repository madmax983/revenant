/**
 * @description Reference example for step timeouts over an HTTP callout: the step
 * launches the callout asynchronously via a future method, suspends, and resumes
 * when the response is delivered back, retrying on non-200 responses.
 */
public inherited sharing class CalloutTimeoutWorkflowExample {
  @TestVisible
  private static Boolean forceAsyncInTest = false;

  /**
   * @description Single-step workflow definition wrapping the timed HTTP callout.
   */
  public class CalloutWorkflow implements WorkflowDefinition {
    /**
     * @description Returns the sole step composing this workflow.
     * @return A one-element list naming the HTTP callout step.
     */
    public List<String> getSteps() {
      return new List<String>{
        'CalloutTimeoutWorkflowExample.MakeHttpCalloutStep'
      };
    }

    /**
     * @description Returns the step the workflow begins with.
     * @return The HTTP callout step name.
     */
    public String getInitialStep() {
      return 'CalloutTimeoutWorkflowExample.MakeHttpCalloutStep';
    }

    /**
     * @description Terminal single-step workflow: there is no successor step.
     * @param currentStepName The name of the step that just completed.
     * @param result The result of the completed step.
     * @return Always null, ending the workflow after the callout step.
     */
    public String getNextStep(String currentStepName, StepResult result) {
      return null; // Terminal step
    }
  }

  /**
   * @description Timeout-configurable step that performs the HTTP callout out of
   * band and resumes with the recorded response.
   */
  public class MakeHttpCalloutStep implements WorkflowStep, TimeoutConfigurable {
    /**
     * @description Declares the step timeout, sized to cover the async future call.
     * @return The timeout in seconds before the engine treats the step as timed out.
     */
    public Integer getTimeoutSeconds() {
      return 60; // Larger timeout for future method call
    }

    /**
     * @description On first run launches the callout asynchronously and suspends;
     * on resume reads the recorded response, completing on 200 or retrying otherwise.
     * @param ctx The durable step context carrying the resume state and workflow input.
     * @return SUSPEND while awaiting the callout, COMPLETE on success, or RETRY on failure.
     */
    public StepResult execute(StepContext ctx) {
      // If we are resuming after the async callout, our state holds the response.
      StepResult resumeResult = tryResumeFromState(ctx);
      if (resumeResult != null) {
        return resumeResult;
      }

      // Otherwise, get the endpoint and kick off the callout.
      String endpoint = resolveEndpoint(ctx);

      if (Test.isRunningTest() && !forceAsyncInTest) {
        // In tests, avoid async delays by simulating success/failure directly
        if (endpoint.contains('status/200')) {
          return StepResult.complete(
            null,
            new Map<String, Object>{
              'status' => 200,
              'body' => '{"success": true}'
            }
          );
        }
        return StepResult.retry(new RetryPolicy(2, (Double) 2.0, 3));
      }

      // Only kick off a NEW async callout on the first (non-resumed) entry: a
      // blank step state means the queueable has not run yet. If step state is
      // already present we are mid-resume inside the async context, so we must
      // NOT enqueue again -- chaining another AsyncCalloutJob here would recurse
      // until Apex hits "Maximum stack depth has been reached".
      if (String.isBlank(ctx.stepStateJson)) {
        // Launch the callout asynchronously to bypass DML callout restrictions.
        System.enqueueJob(
          new AsyncCalloutJob(ctx.workflowInstanceId, endpoint)
        );
        // Suspend the execution state; it resumes once the queueable finishes.
        return StepResult.suspend();
      }

      // Resumed with a payload tryResumeFromState did not recognize as a clean
      // response. Complete the handshake synchronously via the retry policy
      // instead of re-enqueuing inside the already-running async context.
      return StepResult.retry(
        new RetryPolicy(resolveRetryDelay(ctx), (Double) 1.0, 3)
      );
    }

    // Inspects the durable step state for a completed callout response. Returns a
    // terminal StepResult when resuming, or null to fall through to a fresh callout.
    private StepResult tryResumeFromState(StepContext ctx) {
      if (String.isBlank(ctx.stepStateJson)) {
        return null;
      }
      try {
        Map<String, Object> state = (Map<String, Object>) JSON.deserializeUntyped(
          ctx.stepStateJson
        );
        if (!state.containsKey('status')) {
          return null;
        }
        Integer status = (Integer) state.get('status');
        String body = (String) state.get('body');
        if (status == 200) {
          return StepResult.complete(
            null,
            new Map<String, Object>{ 'status' => status, 'body' => body }
          );
        }
        // If it failed, we retry using retry policy
        Integer retryDelay = resolveRetryDelay(ctx);
        return StepResult.retry(new RetryPolicy(retryDelay, (Double) 1.0, 3));
      } catch (Exception ignored) {
        return null;
      }
    }

    // Reads the initial retry interval from the workflow input, defaulting to 2.
    private Integer resolveRetryDelay(StepContext ctx) {
      Integer retryDelay = 2;
      if (String.isBlank(ctx.workflowInputJson)) {
        return retryDelay;
      }
      try {
        Map<String, Object> input = (Map<String, Object>) JSON.deserializeUntyped(
          ctx.workflowInputJson
        );
        if (input.containsKey('retryDelay')) {
          retryDelay = (Integer) input.get('retryDelay');
        }
      } catch (Exception ignored) {
        // Leave the default retry delay in place on malformed input.
      }
      return retryDelay;
    }

    // Reads the callout endpoint from the workflow input, defaulting to a 500 stub.
    private String resolveEndpoint(StepContext ctx) {
      String endpoint = 'https://httpbin.org/status/500';
      if (String.isBlank(ctx.workflowInputJson)) {
        return endpoint;
      }
      try {
        Map<String, Object> input = (Map<String, Object>) JSON.deserializeUntyped(
          ctx.workflowInputJson
        );
        if (input.containsKey('endpoint')) {
          endpoint = (String) input.get('endpoint');
        }
      } catch (Exception ignored) {
        // Leave the default endpoint in place on malformed input.
      }
      return endpoint;
    }
  }

  /**
   * Performs the HTTP callout off-transaction so the step can suspend and resume.
   * Replaces a former `@future` method with a Queueable, which keeps the async
   * teaching intent while allowing typed inputs and chaining.
   */
  public class AsyncCalloutJob implements Queueable, Database.AllowsCallouts {
    private final Id instanceId;
    private final String endpoint;

    /**
     * @description Captures the suspended instance and endpoint for the async callout.
     * @param instanceId The suspended workflow instance to resume with the result.
     * @param endpoint The HTTP endpoint to call.
     */
    public AsyncCalloutJob(Id instanceId, String endpoint) {
      this.instanceId = instanceId;
      this.endpoint = endpoint;
    }

    /**
     * @description Attaches the resume finalizer, then performs the callout and
     * resumes the suspended instance off the original transaction.
     * @param context The Queueable context supplied by the platform.
     */
    public void execute(QueueableContext context) {
      // Attach a Finalizer so a catastrophic failure of this job (an uncaught
      // exception whose rollback would discard the resume written below) still
      // wakes the suspended instance instead of stranding it forever.
      System.attachFinalizer(new ResumeFinalizer(instanceId));
      doCalloutAndResume(instanceId, endpoint);
    }
  }

  /**
   * Safety net for AsyncCalloutJob: if the job dies with an unhandled exception,
   * its transaction rolls back and the resume written inside doCalloutAndResume
   * is lost. The Finalizer runs in a fresh transaction and resumes the instance
   * with an error payload so the workflow can apply its retry policy.
   */
  public class ResumeFinalizer implements Finalizer {
    private final Id instanceId;

    /**
     * @description Captures the suspended instance to recover if the job fails.
     * @param instanceId The suspended workflow instance to resume on failure.
     */
    public ResumeFinalizer(Id instanceId) {
      this.instanceId = instanceId;
    }

    /**
     * @description On an unhandled job exception, resumes the suspended instance
     * with an error payload so the workflow can apply its retry policy.
     * @param context The finalizer context exposing the parent job result and exception.
     */
    public void execute(FinalizerContext context) {
      if (context.getResult() != ParentJobResult.UNHANDLED_EXCEPTION) {
        // The job's own resume already ran; nothing to recover.
        return;
      }
      Map<String, Object> state = new Map<String, Object>{
        'status' => 500,
        'body' => 'Async callout job failed: ' +
        context.getException().getMessage()
      };
      try {
        WorkflowEngine.resumeInstance(instanceId, JSON.serialize(state));
      } catch (Exception ignored) {
        // Nothing more can be done from the Finalizer.
      }
    }
  }

  /**
   * @description Executes the GET callout, captures status and body, and resumes
   * the suspended instance with that result as the resume payload.
   * @param instanceId The suspended workflow instance to resume.
   * @param endpoint The HTTP endpoint to call.
   */
  public static void doCalloutAndResume(Id instanceId, String endpoint) {
    Http h = new Http();
    HttpRequest req = new HttpRequest();
    req.setEndpoint(endpoint);
    req.setMethod('GET');

    Integer statusCode = 500;
    String responseBody = '';

    try {
      HttpResponse res = h.send(req);
      statusCode = res.getStatusCode();
      responseBody = res.getBody();
    } catch (Exception ex) {
      responseBody =
        'Exception: ' +
        ex.getMessage() +
        '\n' +
        ex.getStackTraceString();
    }

    // Store status and body in the resume payload
    Map<String, Object> state = new Map<String, Object>{
      'status' => statusCode,
      'body' => responseBody
    };

    // Resume the suspended instance with the callout result
    try {
      WorkflowEngine.resumeInstance(instanceId, JSON.serialize(state));
    } catch (Exception ignored) {
    }
  }
}
