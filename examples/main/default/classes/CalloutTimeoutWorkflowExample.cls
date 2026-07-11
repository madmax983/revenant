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
      // Check if we already have the callout response in our state (resuming after future method)
      if (String.isNotBlank(ctx.stepStateJson)) {
        try {
          Map<String, Object> state = (Map<String, Object>) JSON.deserializeUntyped(
            ctx.stepStateJson
          );
          if (state.containsKey('status')) {
            Integer status = (Integer) state.get('status');
            String body = (String) state.get('body');
            if (status == 200) {
              return StepResult.complete(
                null,
                new Map<String, Object>{ 'status' => status, 'body' => body }
              );
            } else {
              // Read initial interval from input if available
              Integer retryDelay = 2;
              if (String.isNotBlank(ctx.workflowInputJson)) {
                try {
                  Map<String, Object> input = (Map<String, Object>) JSON.deserializeUntyped(
                    ctx.workflowInputJson
                  );
                  if (input.containsKey('retryDelay')) {
                    retryDelay = (Integer) input.get('retryDelay');
                  }
                } catch (Exception ex) {
                  System.debug(
                    LoggingLevel.WARN,
                    'Failed to deserialize retryDelay from workflowInputJson: ' +
                    ex.getMessage()
                  );
                }
              }
              // If it failed, we retry using retry policy
              return StepResult.retry(
                new RetryPolicy(retryDelay, (Double) 1.0, 3)
              );
            }
          }
        } catch (Exception ex) {
          System.debug(
            LoggingLevel.WARN,
            'Failed to deserialize stepStateJson: ' + ex.getMessage()
          );
        }
      }

      // Otherwise, get the endpoint
      String endpoint = 'https://httpbin.org/status/500';
      if (String.isNotBlank(ctx.workflowInputJson)) {
        try {
          Map<String, Object> input = (Map<String, Object>) JSON.deserializeUntyped(
            ctx.workflowInputJson
          );
          if (input.containsKey('endpoint')) {
            endpoint = (String) input.get('endpoint');
          }
        } catch (Exception ex) {
          System.debug(
            LoggingLevel.WARN,
            'Failed to deserialize endpoint from workflowInputJson: ' +
            ex.getMessage()
          );
        }
      }

      if (Test.isRunningTest() && !forceAsyncInTest) {
        // In tests, avoid future delays by simulating success/failure directly
        if (endpoint.contains('status/200')) {
          return StepResult.complete(
            null,
            new Map<String, Object>{
              'status' => 200,
              'body' => '{"success": true}'
            }
          );
        } else {
          return StepResult.retry(new RetryPolicy(2, (Double) 2.0, 3));
        }
      }

      // Launch the callout asynchronously to bypass DML callout restrictions
      executeAsyncCallout(ctx.workflowInstanceId, endpoint);

      // Suspend the execution state. It will resume once the future method finishes.
      return StepResult.suspend();
    }
  }

  /**
   * @description Future entry point that performs the callout off the transaction
   * that suspended the step, bypassing the DML-before-callout restriction.
   * @param instanceId The suspended workflow instance to resume with the result.
   * @param endpoint The HTTP endpoint to call.
   */
  @future(callout=true)
  public static void executeAsyncCallout(Id instanceId, String endpoint) {
    doCalloutAndResume(instanceId, endpoint);
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
    } catch (Exception ex) {
      System.debug(
        'Failed to resume workflow instance ' +
          instanceId +
          ': ' +
          ex.getMessage()
      );
    }
  }
}
